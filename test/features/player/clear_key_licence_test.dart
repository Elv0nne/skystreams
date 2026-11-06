import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/domain/clear_key.dart';

void main() {
  // One channel's real values throughout: hex is what the media declares, the
  // base64url forms are what a W3C licence server answers with.
  const kidHex = '6752015acf084572a08dfe21796f8b45';
  const keyHex = 'ff823ddbe5625c35d3e93f0ed4520115';
  const kidB64 = 'Z1IBWs8IRXKgjf4heW-LRQ';
  const keyB64 = '_4I92-ViXDXT6T8O1FIBFQ';
  const otherKidB64 = 'EREREREREREREREREREREQ';
  const licence = 'https://drm.example/clearkey';

  StreamResult s({
    String? kid,
    String? key,
    String? licenseUrl = licence,
    Map<String, String>? headers,
  }) => StreamResult(
    url: 'https://cdn.example/a.mpd',
    source: 'live',
    drmKid: kid,
    drmKey: key,
    licenseUrl: licenseUrl,
    headers: headers,
  );

  String hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// A licence server that always answers [body], recording what it was asked.
  ({http.Client client, List<http.Request> seen}) server(
    String body, {
    int status = 200,
  }) {
    final seen = <http.Request>[];
    final client = MockClient((request) async {
      seen.add(request);
      return http.Response(body, status);
    });
    return (client: client, seen: seen);
  }

  group('fetchClearKey', () {
    test('reads a W3C JWK Set', () async {
      final srv = server(
        jsonEncode({
          'keys': [
            {'kty': 'oct', 'kid': kidB64, 'k': keyB64},
          ],
          'type': 'temporary',
        }),
      );

      final ck = await fetchClearKey(
        s(kid: kidHex),
        client: srv.client,
      );

      expect(hex(ck!.keyId), kidHex);
      expect(hex(ck.key), keyHex);
    });

    // The spec's request: a POST of the base64url KIDs we want, unpadded.
    test('asks for the declared KID the way the spec says', () async {
      final srv = server(
        jsonEncode({
          'keys': [
            {'kty': 'oct', 'kid': kidB64, 'k': keyB64},
          ],
        }),
      );

      await fetchClearKey(s(kid: kidHex), client: srv.client);

      expect(srv.seen, hasLength(1));
      final request = srv.seen.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), licence);
      expect(jsonDecode(request.body), {
        'kids': [kidB64],
        'type': 'temporary',
      });
    });

    // A CDN that ties the signed manifest URL to its requester will 403 a
    // licence fetch that shows up as somebody else.
    test('sends the stream identity with the request', () async {
      final srv = server(
        jsonEncode({
          'keys': [
            {'kid': kidB64, 'k': keyB64},
          ],
        }),
      );

      await fetchClearKey(
        s(kid: kidHex, headers: const {'Referer': 'https://portal.example/'}),
        client: srv.client,
      );

      final sent = srv.seen.single.headers;
      expect(sent['Referer'], 'https://portal.example/');
      expect(sent['user-agent'], isNotEmpty);
    });

    test('accepts base64url with padding as well as without', () async {
      for (final k in ['$keyB64==', keyB64]) {
        final srv = server(
          jsonEncode({
            'keys': [
              {'kid': '$kidB64==', 'k': k},
            ],
          }),
        );
        final ck = await fetchClearKey(s(kid: kidHex), client: srv.client);
        expect(hex(ck!.key), keyHex, reason: 'k=$k');
        expect(hex(ck.keyId), kidHex);
      }
    });

    // Plenty of IPTV servers ignore the JWK spelling and answer in hex.
    test('reads a hex keys array', () async {
      final srv = server(
        jsonEncode({
          'keys': [
            {'kid': kidHex, 'key': keyHex},
          ],
        }),
      );

      final ck = await fetchClearKey(s(kid: kidHex), client: srv.client);
      expect(hex(ck!.key), keyHex);
    });

    test('reads a flat object with no keys array', () async {
      final srv = server(jsonEncode({'kid': kidHex, 'key': keyHex}));
      final ck = await fetchClearKey(s(kid: kidHex), client: srv.client);
      expect(hex(ck!.keyId), kidHex);
      expect(hex(ck.key), keyHex);
    });

    test('reads a bare kid:key body that is not JSON at all', () async {
      final srv = server('$kidHex:$keyHex\n');
      final ck = await fetchClearKey(s(kid: kidHex), client: srv.client);
      expect(hex(ck!.key), keyHex);
    });

    // Nothing but the key, which is only usable because the media declares
    // which KID it belongs to.
    test('reads a bare key when the media declares the KID', () async {
      final srv = server(keyHex);
      final ck = await fetchClearKey(s(kid: kidHex), client: srv.client);
      expect(hex(ck!.keyId), kidHex);
      expect(hex(ck.key), keyHex);
    });

    test('is null for a bare key with no KID to pair it with', () async {
      final srv = server(keyHex);
      final ck = await fetchClearKey(s(), client: srv.client);
      expect(ck, isNull);
    });

    // The whole point of the declared KID: a key for other media decrypts to
    // noise rather than failing, so a mismatch has to be refused here.
    test('refuses a key whose KID is not the one the media declares', () async {
      final srv = server(
        jsonEncode({
          'keys': [
            {'kid': otherKidB64, 'k': keyB64},
          ],
        }),
      );

      expect(await fetchClearKey(s(kid: kidHex), client: srv.client), isNull);
    });

    test('picks the matching entry out of a multi-key response', () async {
      final srv = server(
        jsonEncode({
          'keys': [
            {'kid': otherKidB64, 'k': 'EREREREREREREREREREREQ'},
            {'kid': kidB64, 'k': keyB64},
          ],
        }),
      );

      final ck = await fetchClearKey(s(kid: kidHex), client: srv.client);
      expect(hex(ck!.key), keyHex);
    });

    test('is null when the body is not parseable', () async {
      final srv = server('<html>403 Forbidden</html>');
      expect(await fetchClearKey(s(kid: kidHex), client: srv.client), isNull);
    });

    test('is null when the keys array holds nothing usable', () async {
      final srv = server(jsonEncode({'keys': <Object>[]}));
      expect(await fetchClearKey(s(kid: kidHex), client: srv.client), isNull);
    });

    test('is null on an HTTP error', () async {
      final srv = server(
        jsonEncode({
          'keys': [
            {'kid': kidB64, 'k': keyB64},
          ],
        }),
        status: 403,
      );
      expect(await fetchClearKey(s(kid: kidHex), client: srv.client), isNull);
    });

    test('is null when the request throws', () async {
      final client = MockClient((_) => throw const SocketishException());
      expect(await fetchClearKey(s(kid: kidHex), client: client), isNull);
    });

    // A static JSON file behind a CDN is a common "licence server", and it
    // answers 405 to the POST the spec asks for.
    test('falls back to GET when the POST is rejected', () async {
      final seen = <String>[];
      final client = MockClient((request) async {
        seen.add(request.method);
        if (request.method == 'POST') return http.Response('', 405);
        return http.Response(
          jsonEncode({
            'keys': [
              {'kid': kidB64, 'k': keyB64},
            ],
          }),
          200,
        );
      });

      final ck = await fetchClearKey(s(kid: kidHex), client: client);
      expect(hex(ck!.key), keyHex);
      expect(seen, ['POST', 'GET']);
    });

    // Without a KID there is nothing to POST, so the spec request is skipped.
    test('GETs straight away when the media declares no KID', () async {
      final srv = server(
        jsonEncode({
          'keys': [
            {'kid': kidB64, 'k': keyB64},
          ],
        }),
      );

      final ck = await fetchClearKey(s(), client: srv.client);
      expect(hex(ck!.keyId), kidHex);
      expect(srv.seen.single.method, 'GET');
    });

    // A licence server that never answers must cost the configured wait and
    // nothing more - playback cannot sit behind it.
    test('gives up when the server hangs', () async {
      final client = MockClient((_) => Completer<http.Response>().future);

      final watch = Stopwatch()..start();
      final ck = await fetchClearKey(
        s(kid: kidHex),
        client: client,
        timeout: const Duration(milliseconds: 40),
      );
      watch.stop();

      expect(ck, isNull);
      // The GET retry must share the budget rather than double it.
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 400)));
    });

    test('never opens a connection for Widevine or PlayReady', () async {
      final client = MockClient(
        (_) async => fail('a CDM licence server must not be contacted'),
      );

      expect(
        await fetchClearKey(
          s(kid: kidHex, licenseUrl: 'https://x.irdeto.com/widevine/license'),
          client: client,
        ),
        isNull,
      );
      expect(
        await fetchClearKey(
          s(kid: kidHex, licenseUrl: 'https://x/playready/rightsmanager.asmx'),
          client: client,
        ),
        isNull,
      );
      expect(await fetchClearKey(s(licenseUrl: null), client: client), isNull);
      expect(
        await fetchClearKey(s(licenseUrl: 'not a url'), client: client),
        isNull,
      );
    });

    // The inline key is the common case and must not cost a round trip.
    test('returns the playlist key without asking anyone', () async {
      final client = MockClient(
        (_) async => fail('an inline ClearKey needs no licence request'),
      );

      final ck = await fetchClearKey(
        s(kid: kidHex, key: keyHex),
        client: client,
      );
      expect(hex(ck!.key), keyHex);
    });
  });
}

/// Stands in for a dead host without dragging `dart:io` into the test.
class SocketishException implements Exception {
  const SocketishException();
}
