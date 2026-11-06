/// Turning what a plugin hands us into a usable ClearKey.
///
/// Plugins carry the key in whatever shape their upstream playlist used, and
/// the shapes genuinely differ: Kodi-style `inputstream.adaptive` props use
/// `kid:key` hex pairs, while W3C JWK sources emit base64url. Getting this
/// wrong does not throw — a wrong key decrypts to noise — so parsing is strict
/// and returns null rather than guessing.
///
/// The key does not have to be in the playlist. The W3C ClearKey licence
/// exchange is a plain JSON request/response with no CDM behind it, so
/// [fetchClearKey] can complete it where [clearKeyFor] comes up empty.
///
/// ClearKey only. There is no CDM in this app, so Widevine and PlayReady are
/// out of reach regardless of what a manifest advertises.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../l10n/generated/app_localizations.dart';
import 'stream_resolver.dart';

/// A 16-byte content key and the key ID it decrypts.
class ClearKey {
  const ClearKey({required this.keyId, required this.key});

  /// The KID the media declares in `tenc` / the manifest's `default_KID`.
  final Uint8List keyId;

  /// The 16-byte AES key.
  final Uint8List key;
}

/// Why a stream's DRM cannot be opened, for telling the user something useful.
enum DrmObstacle {
  /// A licence server using a CDM this app does not have. Never openable.
  widevine,
  playready,

  /// ClearKey, but the key must come from a licence server rather than the
  /// playlist. The one obstacle worth attempting - see [fetchClearKey]; this
  /// is what remains when that attempt comes back empty.
  licenceServer,

  /// Encrypted, but nothing identifies how.
  unknown,
}

/// Classifies DRM that [clearKeyFor] could not satisfy.
///
/// Returns null when the stream is not encrypted, or when it is ClearKey with
/// a usable key. Naming the scheme matters: Widevine is permanently out of
/// reach without a CDM, while a missing ClearKey is a plugin problem, and a
/// user told only "DRM" cannot tell those apart.
DrmObstacle? drmObstacleFor(StreamResult stream) {
  if (clearKeyFor(stream) != null) return null;
  final licence = stream.licenseUrl;
  if (licence == null && stream.drmKey == null && stream.drmKid == null) {
    return null; // not encrypted at all
  }
  final lower = licence?.toLowerCase() ?? '';
  if (lower.contains('widevine')) return DrmObstacle.widevine;
  if (lower.contains('playready')) return DrmObstacle.playready;
  if (licence != null && licence.isNotEmpty) return DrmObstacle.licenceServer;
  return DrmObstacle.unknown;
}

/// A short, honest explanation of [obstacle].
String describeDrmObstacle(AppLocalizations l10n, DrmObstacle obstacle) =>
    switch (obstacle) {
      DrmObstacle.widevine => l10n.playerDrmWidevine,
      DrmObstacle.playready => l10n.playerDrmPlayReady,
      DrmObstacle.licenceServer => l10n.playerDrmLicenceServer,
      DrmObstacle.unknown => l10n.playerDrmUnknown,
    };

/// Extracts a usable ClearKey from [stream], or null when there is not one.
///
/// Synchronous, so it stays usable on the path that builds the engine's media
/// options. Returns null for licence-server DRM, which costs a round trip -
/// [fetchClearKey] is the one that goes and asks.
ClearKey? clearKeyFor(StreamResult stream) {
  final rawKey = stream.drmKey;
  final rawKid = stream.drmKid;
  if (rawKey == null || rawKey.isEmpty) return null;

  // Some plugins pack both halves into drmKey as "kid:key".
  var keyText = rawKey.trim();
  var kidText = rawKid?.trim();
  if (keyText.contains(':')) {
    final parts = keyText.split(':');
    if (parts.length == 2) {
      kidText ??= parts[0].trim();
      keyText = parts[1].trim();
    }
  }
  if (kidText == null || kidText.isEmpty) return null;

  final key = _decode16(keyText);
  final keyId = _decode16(kidText);
  if (key == null || keyId == null) return null;
  return ClearKey(keyId: keyId, key: key);
}

/// Decodes a 16-byte value written as hex or base64url.
///
/// Hex is tried first, with hyphens removed so a UUID-form KID works. That
/// stripping must NOT happen before the base64url attempt: `-` is a legal
/// base64url character, and removing it silently corrupts the value into a
/// key that decrypts to noise instead of failing.
Uint8List? _decode16(String value) {
  final trimmed = value.trim();

  final hex = trimmed.replaceAll('-', '');
  if (hex.length == 32) {
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }

  // base64url, with or without padding, on the ORIGINAL text.
  try {
    final padded = trimmed.padRight((trimmed.length + 3) & ~3, '=');
    final bytes = base64Url.decode(padded);
    return bytes.length == 16 ? Uint8List.fromList(bytes) : null;
  } catch (_) {
    return null;
  }
}

/// Fetches a ClearKey from the stream's licence server.
///
/// The W3C ClearKey exchange is deliberately trivial - POST the KIDs you want,
/// get a JWK Set back - which makes it the one licence flow a player with no
/// CDM can finish. Streams whose key lives on a server were previously refused
/// outright, so this is the difference between playing and not.
///
/// Never throws and never hangs: every failure is a null, because the caller's
/// fallback is [describeDrmObstacle] and a stream that was already unplayable
/// must not be able to take playback down with it.
///
/// [client] is injected for tests; when omitted a client is created and closed
/// here.
Future<ClearKey?> fetchClearKey(
  StreamResult stream, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 6),
}) async {
  final inline = clearKeyFor(stream);
  if (inline != null) return inline;

  // Widevine and PlayReady servers want a CDM challenge we cannot build, so
  // asking them is a wasted round trip in front of the same refusal.
  if (drmObstacleFor(stream) != DrmObstacle.licenceServer) return null;

  final uri = Uri.tryParse(stream.licenseUrl!.trim());
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }

  final declaredKid = stream.drmKid == null ? null : _decode16(stream.drmKid!);

  // One identity across probe, licence and engine: a CDN that ties a signed
  // URL to its requester will 403 the odd one out.
  final headers = playbackHeaders(stream);

  final owned = client == null;
  final agent = client ?? http.Client();
  final deadline = DateTime.now().add(timeout);
  Duration remaining() {
    final left = deadline.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  try {
    http.Response? response;
    if (declaredKid != null) {
      response = await _send(
        () => agent.post(
          uri,
          headers: {...headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'kids': [_base64Url(declaredKid)],
            'type': 'temporary',
          }),
        ),
        remaining(),
      );
    }

    // The POST is what the spec says, but a good number of IPTV "licence
    // servers" are a static JSON file behind a CDN that answers 405 to it.
    response ??= await _send(
      () => agent.get(uri, headers: headers),
      remaining(),
    );
    if (response == null) return null;

    return _clearKeyFromLicence(response.body, declaredKid);
  } finally {
    if (owned) agent.close();
  }
}

/// Runs one licence request under [budget], flattening every failure - socket,
/// timeout, non-2xx - into a null so the caller only has one case to handle.
Future<http.Response?> _send(
  Future<http.Response> Function() request,
  Duration budget,
) async {
  try {
    final response = await request().timeout(budget);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    return response;
  } catch (_) {
    return null;
  }
}

/// Reads a licence response into a key.
///
/// The spec's answer is a JWK Set of base64url `k`/`kid` pairs, but real
/// servers also send hex under `key`, a single flat object, or just the pair
/// as text. Each of those is unambiguous, and [_decode16] rejects anything
/// that is not sixteen bytes, so accepting them costs no correctness.
ClearKey? _clearKeyFromLicence(String body, Uint8List? declaredKid) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    decoded = null; // Not JSON; the text shapes below still might work.
  }

  if (decoded is Map) {
    final entries = decoded['keys'];
    if (entries is List) {
      // A manifest that encrypts audio and video separately gets several
      // entries back, and only the declared KID's key decrypts this media.
      for (final entry in entries) {
        if (entry is! Map) continue;
        final pair = _pair(
          entry['kid'],
          entry['k'] ?? entry['key'],
          declaredKid,
        );
        if (pair != null) return pair;
      }
      return null;
    }
    return _pair(decoded['kid'], decoded['k'] ?? decoded['key'], declaredKid);
  }

  return _pairFromText(decoded is String ? decoded : trimmed, declaredKid);
}

/// Pairs one licence entry's key with the KID it belongs to.
///
/// A key used against the wrong KID decrypts to noise instead of failing, so a
/// server that names a KID we did not ask for is refused rather than tried.
ClearKey? _pair(Object? rawKid, Object? rawKey, Uint8List? declaredKid) {
  if (rawKey is! String) return null;
  final key = _decode16(rawKey);
  if (key == null) return null;

  final kid = rawKid is String ? _decode16(rawKid) : null;
  if (declaredKid != null) {
    if (kid != null && !_sameBytes(kid, declaredKid)) return null;
    return ClearKey(keyId: declaredKid, key: key);
  }
  if (kid == null) return null; // nothing anywhere says what this key opens
  return ClearKey(keyId: kid, key: key);
}

/// A response that is not JSON: either `kid:key`, or - when the media already
/// declares its KID - the bare key on its own.
ClearKey? _pairFromText(String text, Uint8List? declaredKid) {
  final trimmed = text.trim();
  final parts = trimmed.split(':');
  if (parts.length == 2) {
    return _pair(parts[0].trim(), parts[1].trim(), declaredKid);
  }
  if (declaredKid == null) return null;
  final key = _decode16(trimmed);
  return key == null ? null : ClearKey(keyId: declaredKid, key: key);
}

/// base64url with the padding stripped, which is how the W3C request carries
/// its KIDs.
String _base64Url(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
