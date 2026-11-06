import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import '../../features/settings/presentation/player_settings_provider.dart';
import '../domain/entity/multimedia_item.dart';

/// Internal quality tier, derived by parsing a source's label string.
/// Order matters — higher index = higher quality.
enum _QualityTier {
  unknown, // no detectable quality info
  q360,
  q480,
  q720,
  q1080,
  q1440,
  q4k,
}

extension on _QualityTier {
  int get rank => index; // unknown=0, q360=1 … q1440=5, q4k=6
}

extension on QualityPreference {
  /// Maps a preference to the equivalent tier rank (-1 = no preference).
  int get rank {
    switch (this) {
      case QualityPreference.any:
        return -1;
      case QualityPreference.q360:
        return _QualityTier.q360.rank;
      case QualityPreference.q480:
        return _QualityTier.q480.rank;
      case QualityPreference.q720:
        return _QualityTier.q720.rank;
      case QualityPreference.q1080:
        return _QualityTier.q1080.rank;
      case QualityPreference.q4k:
        return _QualityTier.q4k.rank;
    }
  }

  String getLabel(AppLocalizations l10n) {
    switch (this) {
      case QualityPreference.any:
        return l10n.anyNoPreference;
      case QualityPreference.q360:
        return '360p';
      case QualityPreference.q480:
        return '480p (SD)';
      case QualityPreference.q720:
        return '720p (HD)';
      case QualityPreference.q1080:
        return '1080p (FHD)';
      case QualityPreference.q4k:
        return '4K (UHD)';
    }
  }
}

String qualityPreferenceLabel(QualityPreference q, AppLocalizations l10n) =>
    q.getLabel(l10n);

/// A file size anywhere in the label, in the shapes indexers write it:
/// `2.1 GB`, `2,1GiB`, `700 mb`.
final RegExp _sizeNoise = RegExp(
  r'\d+(?:[.,]\d+)?\s*[KMGT]i?B\b',
  caseSensitive: false,
);

/// Seeder, peer and leecher counts, which carry numbers that read like
/// resolutions — `1360 seeds` is not 360p.
final RegExp _peerNoise = RegExp(
  r'(?:\u{1F464}|\u{1F465}|\u{1F331})\s*\d+'
  r'|\d+\s*(?:seed(?:er)?s?|leech(?:er)?s?|peers?)\b'
  r'|\b(?:seed(?:er)?s?|leech(?:er)?s?|peers?)\s*[:=]?\s*\d+'
  r'|\bS\s*[:=]\s*\d+',
  caseSensitive: false,
  unicode: true,
);

/// `1920x1080`, `3840 × 2160`. The height is what names the tier.
final RegExp _dimensions = RegExp(
  r'\b\d{3,5}\s*[x×]\s*(\d{3,5})\b',
  caseSensitive: false,
);

/// `1080p`, `576i`, `720 p`.
final RegExp _scanlines = RegExp(r'\b(\d{3,4})\s*[pi]\b', caseSensitive: false);

/// A bare height, allow-listed rather than "any three-digit number": what is
/// left of a label after the size and the seeders still holds years, bitrates
/// and episode numbers.
final RegExp _bareHeight = RegExp(r'\b(2160|1440|1080|720|576|480|360|240)\b');

final RegExp _uhdWords = RegExp(
  r'\b(?:4k|uhd|ultra[\s-]?hd|4096)\b',
  caseSensitive: false,
);
final RegExp _qhdWords = RegExp(r'\b(?:2k|qhd)\b', caseSensitive: false);
final RegExp _fhdWords = RegExp(
  r'\b(?:fhd|full[\s-]?hd)\b',
  caseSensitive: false,
);

/// IPTV portals grade their channels `Low HD` / `Mid HD` / `HD+`, and the low
/// one is an SD stream however it is spelled.
final RegExp _lowHdWords = RegExp(r'\blow[\s-]?hd\b', caseSensitive: false);
final RegExp _hdWords = RegExp(r'\bhd\b', caseSensitive: false);
final RegExp _sdWords = RegExp(r'\bsd\b', caseSensitive: false);
final RegExp _lowWords = RegExp(r'\blow(?:est)?\b', caseSensitive: false);

/// Detects the quality tier from a source label string.
///
/// The label is not a resolution: plugins compose it as
/// `quality · size · language · N seeds`, so the size and the peer counts are
/// dropped first and what is left is matched on whole tokens. Both halves
/// matter — an unanchored search reads `1360 seeds` as 360p, `Streamflow` as
/// "low" and `HDRezka` as HD.
///
/// A number beats a word, so `HD 1080p` is 1080p rather than 720p.
_QualityTier _detectTier(String sourceLabel) {
  final s = sourceLabel
      .replaceAll(_sizeNoise, ' ')
      .replaceAll(_peerNoise, ' ');

  final height = _labelledHeight(s);
  if (height != null) return _tierForHeight(height);

  if (_uhdWords.hasMatch(s)) return _QualityTier.q4k;
  if (_qhdWords.hasMatch(s)) return _QualityTier.q1440;
  if (_fhdWords.hasMatch(s)) return _QualityTier.q1080;
  if (_lowHdWords.hasMatch(s)) return _QualityTier.q480;
  if (_hdWords.hasMatch(s)) return _QualityTier.q720;
  if (_sdWords.hasMatch(s)) return _QualityTier.q480;
  if (_lowWords.hasMatch(s)) return _QualityTier.q360;
  return _QualityTier.unknown;
}

/// Whether [label] states a quality the sorter ranks by: a height, or a word
/// such as HD or 4K.
bool labelStatesQuality(String label) =>
    _detectTier(label) != _QualityTier.unknown;

/// The height [label] states outright, in the three ways it can state it.
int? _labelledHeight(String label) {
  for (final pattern in [_dimensions, _scanlines, _bareHeight]) {
    final match = pattern.firstMatch(label);
    if (match != null) return int.tryParse(match.group(1)!);
  }
  return null;
}

/// Buckets an odd height into the nearest tier — `576i` is SD, `900p` is
/// closer to 1080 than to 720.
_QualityTier _tierForHeight(int height) {
  if (height >= 1800) return _QualityTier.q4k;
  if (height >= 1260) return _QualityTier.q1440;
  if (height >= 900) return _QualityTier.q1080;
  if (height >= 600) return _QualityTier.q720;
  if (height >= 420) return _QualityTier.q480;
  return _QualityTier.q360;
}

/// What the sorter knows of [stream]'s quality: its own `quality` first,
/// then its label. An adaptive stream with neither is unknown with
/// `adaptive` set: it plays at whatever the viewer prefers, so it ranks
/// there.
({_QualityTier tier, bool adaptive}) _qualityOf(StreamResult stream) {
  final quality = stream.quality;
  if (quality != null && quality > 0) {
    return (tier: _tierForHeight(quality), adaptive: false);
  }
  final tier = quality == 0 ? _QualityTier.unknown : _detectTier(stream.source);
  return (
    tier: tier,
    adaptive: tier == _QualityTier.unknown && _isAdaptive(stream),
  );
}

/// Whether [stream] adapts its quality: an HLS link - its address names a
/// playlist, the link probe's own test, which a `MAGIC_PROXY` address (the
/// real one rides in its query) and a `magic_m3u8:` one (served as
/// `/<id>.m3u8`) pass too - or one that says `quality: "Auto"`.
bool _isAdaptive(StreamResult stream) =>
    stream.quality == 0 || stream.url.toLowerCase().contains('.m3u8');

/// Returns a sort key for [tier] given [prefRank].
/// - Preferred tier  → 0
/// - Lower tiers     → 1, 2, … (closer lower = smaller key)
/// - Higher tiers    → rank (always > any lower-tier key)
/// - Unknown/auto    → 100 (always last)
int _sortKey(_QualityTier tier, int prefRank) {
  if (tier == _QualityTier.unknown) return 100;
  final r = tier.rank;
  if (r == prefRank) return 0;
  if (r < prefRank) return prefRank - r; // 1 … prefRank
  return r; // r > prefRank; always > any lower-tier key
}

/// Whether the link the device is on is one the viewer pays for by the byte.
///
/// Transport is the only signal connectivity_plus exposes, so this approximates
/// metered rather than reading the OS's own answer: cellular is metered, and
/// Wi-Fi, Ethernet, a VPN tunnel and no link at all are not. Asking for Wi-Fi
/// instead would put every Ethernet-connected television and desktop on the
/// mobile-data preference.
///
/// Android reports every transport the active network uses, so a VPN riding on
/// cellular still reads as metered there; Apple's path monitor reports the
/// tunnel alone, so it does not.
///
/// Falls back to metered on any error, the answer that cannot spend data the
/// viewer did not agree to.
Future<bool> isOnMeteredNetwork() async {
  try {
    final results = await Connectivity().checkConnectivity();
    return results.contains(ConnectivityResult.mobile);
  } catch (_) {
    return true;
  }
}

/// The height [preference] stands for, or null for [QualityPreference.any],
/// which asks for none.
int? qualityPreferenceHeight(QualityPreference preference) =>
    switch (preference) {
      QualityPreference.any => null,
      QualityPreference.q360 => 360,
      QualityPreference.q480 => 480,
      QualityPreference.q720 => 720,
      QualityPreference.q1080 => 1080,
      QualityPreference.q4k => 2160,
    };

/// The quality preference in force now: mobile data's on a metered link,
/// Wi-Fi & Wired's otherwise - see [isOnMeteredNetwork].
Future<QualityPreference> qualityPreferenceInForce(
  PlayerSettings settings,
) async =>
    await isOnMeteredNetwork() ? settings.mobileQuality : settings.wifiQuality;

/// Sorts [streams] by quality preference without changing the original list.
///
/// If [preference] is [QualityPreference.any] the list is returned unchanged.
/// Within the same quality tier the original relative order is preserved
/// (stable sort).
///
/// Sort order for a given preference P (example: 1080p):
///   1080p → adaptive (HLS) → 720p → 480p → 360p → 2K → 4K → unknown
List<StreamResult> sortStreamsByQuality(
  List<StreamResult> streams,
  QualityPreference preference,
) {
  if (preference == QualityPreference.any || streams.length <= 1) {
    return streams;
  }

  final prefRank = preference.rank;
  final indexed = streams.asMap().entries.map((e) {
    final quality = _qualityOf(e.value);
    return (
      index: e.key,
      stream: e.value,
      // An adaptive stream plays at the preference, so it ranks with the
      // links labelled with it, after them.
      key: quality.adaptive ? 0 : _sortKey(quality.tier, prefRank),
      behind: quality.adaptive ? 1 : 0,
    );
  }).toList();

  indexed.sort((a, b) {
    if (a.key != b.key) return a.key.compareTo(b.key);
    if (a.behind != b.behind) return a.behind.compareTo(b.behind);
    return a.index.compareTo(b.index); // stable: preserve original order
  });

  return indexed.map((e) => e.stream).toList();
}

/// Filters [streams] to only those satisfying [mode] relative to [preference].
///
/// - [QualityFilterMode.atOrAbove]: keeps streams at or above the preferred tier.
/// - [QualityFilterMode.atOrBelow]: keeps streams at or below the preferred tier.
/// - [QualityFilterMode.any]: returns [streams] unchanged.
///
/// If the filter would produce an empty list the original [streams] list is
/// returned unchanged and [didFallback] (if provided) is set to `true`. This
/// prevents showing an empty Sources tab when the plugin returns no source that
/// matches the preference.
List<StreamResult> filterStreamsByQuality(
  List<StreamResult> streams,
  QualityPreference preference,
  QualityFilterMode mode, {
  void Function(bool)? onFallback,
}) {
  if (mode == QualityFilterMode.any ||
      preference == QualityPreference.any ||
      streams.isEmpty) {
    onFallback?.call(false);
    return streams;
  }

  final prefRank = preference.rank;

  final filtered = streams.where((s) {
    final quality = _qualityOf(s);
    // An adaptive stream plays at the preference; unknown is always kept.
    if (quality.adaptive || quality.tier == _QualityTier.unknown) return true;
    final r = quality.tier.rank;
    if (mode == QualityFilterMode.atOrAbove) return r >= prefRank;
    if (mode == QualityFilterMode.atOrBelow) return r <= prefRank;
    return true;
  }).toList();

  if (filtered.isEmpty) {
    onFallback?.call(true);
    return streams; // fallback: show all rather than empty list
  }

  onFallback?.call(false);
  return filtered;
}

/// Returns a short human-readable quality label for [stream] suitable for
/// display as a badge in the Sources tab (e.g. "1080p", "720p", "Auto").
String qualityBadgeLabel(StreamResult stream) {
  switch (_qualityOf(stream).tier) {
    case _QualityTier.q4k:
      return '4K';
    case _QualityTier.q1440:
      return '2K';
    case _QualityTier.q1080:
      return '1080p';
    case _QualityTier.q720:
      return '720p';
    case _QualityTier.q480:
      return '480p';
    case _QualityTier.q360:
      return '360p';
    case _QualityTier.unknown:
      return 'Auto';
  }
}
