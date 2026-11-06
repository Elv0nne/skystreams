import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/domain/source_check.dart';
import 'package:skystream/features/player/domain/stream_resolver.dart';

StreamResult _film([String name = 'film.mp4']) => StreamResult(
  url: 'https://cdn.test/$name',
  source: 'Test',
  headers: const {'Referer': 'https://site.test/'},
);

/// Runs [checkSource] for [stream] against [handler], counting the requests by
/// method.
Future<(CheckResult, Map<String, int>, List<http.BaseRequest>)> _check(
  Future<http.StreamedResponse> Function(http.BaseRequest request) handler, {
  StreamResult? stream,
  bool headAfterError = false,
  Duration timeout = kCheckTimeout,
}) async {
  final counts = <String, int>{};
  final seen = <http.BaseRequest>[];
  final result = await http.runWithClient(
    () => checkSource(
      stream ?? _film(),
      headAfterError: headAfterError,
      timeout: timeout,
    ),
    () => MockClient.streaming((request, _) {
      counts[request.method] = (counts[request.method] ?? 0) + 1;
      seen.add(request);
      return handler(request);
    }),
  );
  return (result, counts, seen);
}

Future<http.StreamedResponse> _answer(
  int status, {
  Map<String, String> headers = const {},
  List<int> body = const [],
}) async => http.StreamedResponse(
  Stream<List<int>>.value(body),
  status,
  headers: headers,
);

void main() {
  group('a status, classed', () {
    test('below 400, and 416, answer', () {
      for (final status in [200, 204, 206, 302, 304, 416]) {
        expect(
          checkClassOfStatus(status),
          CheckClass.answers,
          reason: '$status',
        );
      }
    });

    test('401, 403, 404, 410 and any other 4xx are gone', () {
      for (final status in [400, 401, 403, 404, 405, 410, 451]) {
        expect(checkClassOfStatus(status), CheckClass.gone, reason: '$status');
      }
    });

    test('408, 429 and 5xx are busy', () {
      for (final status in [408, 429, 500, 502, 503, 504, 599]) {
        expect(checkClassOfStatus(status), CheckClass.busy, reason: '$status');
      }
    });
  });

  group('a network error, by kind', () {
    test('a failed host lookup is dns', () {
      expect(
        networkFaultOf(const SocketException("Failed host lookup: 'cdn.test'")),
        NetworkFault.dns,
      );
    });

    test(
      'a refused connection is refused, whichever platform errno it has',
      () {
        for (final code in [61, 111, 10061]) {
          expect(
            networkFaultOf(
              SocketException(
                'Connection refused',
                osError: OSError('Connection refused', code),
              ),
            ),
            NetworkFault.refused,
            reason: '$code',
          );
        }
      },
    );

    test('a reset, and a connection closed before the headers, are reset', () {
      for (final code in [54, 104, 10054]) {
        expect(
          networkFaultOf(
            SocketException('Connection reset', osError: OSError('', code)),
          ),
          NetworkFault.reset,
          reason: '$code',
        );
      }
      expect(
        networkFaultOf(
          http.ClientException(
            'Connection closed before full header was received',
          ),
        ),
        NetworkFault.reset,
      );
    });

    test('an unreachable network or host is unreachable', () {
      for (final code in [51, 65, 101, 113, 10051, 10065]) {
        expect(
          networkFaultOf(SocketException('', osError: OSError('', code))),
          NetworkFault.unreachable,
          reason: '$code',
        );
      }
    });

    test('a timeout is timeout', () {
      expect(networkFaultOf(TimeoutException('3 s')), NetworkFault.timeout);
      for (final code in [60, 110, 10060]) {
        expect(
          networkFaultOf(SocketException('', osError: OSError('', code))),
          NetworkFault.timeout,
          reason: '$code',
        );
      }
    });

    test('a TLS failure is tls', () {
      expect(networkFaultOf(const HandshakeException('bad')), NetworkFault.tls);
      expect(networkFaultOf(const TlsException('bad')), NetworkFault.tls);
    });

    test('anything else is other', () {
      expect(networkFaultOf(StateError('?')), NetworkFault.other);
      expect(networkFaultOf(const SocketException('?')), NetworkFault.other);
    });
  });

  group('Retry-After', () {
    final now = DateTime.utc(2026, 10, 15, 12);

    test('is read in seconds', () {
      expect(retryAfterOf('4', now: now), const Duration(seconds: 4));
      expect(retryAfterOf(' 120 ', now: now), const Duration(minutes: 2));
    });

    test('is read as an HTTP date against now', () {
      expect(
        retryAfterOf('Thu, 15 Oct 2026 12:00:09 GMT', now: now),
        const Duration(seconds: 9),
      );
    });

    test(
      'a date in the past, zero, or a value that cannot be read is none',
      () {
        expect(retryAfterOf('Thu, 15 Oct 2026 11:59:00 GMT', now: now), isNull);
        expect(retryAfterOf('0', now: now), isNull);
        expect(retryAfterOf('soon', now: now), isNull);
        expect(retryAfterOf('', now: now), isNull);
        expect(retryAfterOf(null, now: now), isNull);
      },
    );
  });

  group('the check', () {
    test('sends the source headers and a 1 KB range', () async {
      final (result, counts, seen) = await _check((_) => _answer(206));

      expect(result.kind, CheckClass.answers);
      expect(result.status, 206);
      expect(counts, {'GET': 1});
      expect(seen.single.headers['Range'], 'bytes=0-1023');
      expect(seen.single.headers['Referer'], 'https://site.test/');
      expect(seen.single.headers['User-Agent'], isNotEmpty);
    });

    test('a 200 or a redirect answers', () async {
      for (final status in [200, 302]) {
        final (result, _, _) = await _check((_) => _answer(status));
        expect(result.kind, CheckClass.answers, reason: '$status');
      }
    });

    test('a 416 answers: an empty file', () async {
      final (result, _, _) = await _check((_) => _answer(416));

      expect(result.kind, CheckClass.answers);
      expect(result.outcome, ProbeOutcome.healthy);
    });

    test('401, 403, 404 and 410 are gone, with no HEAD', () async {
      for (final status in [401, 403, 404, 410]) {
        final (result, counts, _) = await _check((_) => _answer(status));
        expect(result.kind, CheckClass.gone, reason: '$status');
        expect(result.status, status);
        expect(result.outcome, ProbeOutcome.unhealthy);
        expect(counts, {'GET': 1}, reason: '$status');
      }
    });

    test('another 4xx is gone unless the HEAD answers', () async {
      final (refused, _, _) = await _check(
        (request) => _answer(request.method == 'HEAD' ? 405 : 400),
      );
      expect(refused.kind, CheckClass.gone);

      final (passed, counts, _) = await _check(
        (request) => _answer(request.method == 'HEAD' ? 200 : 400),
      );
      expect(passed.kind, CheckClass.answers);
      expect(passed.outcome, ProbeOutcome.healthy);
      expect(counts, {'GET': 1, 'HEAD': 1});
    });

    test('408, 429 and 5xx are busy, with their Retry-After', () async {
      await withClock(Clock.fixed(DateTime.utc(2026, 10, 15)), () async {
        for (final status in [408, 429, 500, 503]) {
          final (result, counts, _) = await _check(
            (_) => _answer(status, headers: const {'retry-after': '4'}),
          );
          expect(result.kind, CheckClass.busy, reason: '$status');
          expect(result.retryAfter, const Duration(seconds: 4));
          expect(counts, {'GET': 1}, reason: '$status');
        }
      });
    });

    test('a network error returns at once, with no HEAD', () async {
      final (result, counts, _) = await _check(
        (_) => throw const SocketException(
          'Connection refused',
          osError: OSError('Connection refused', 61),
        ),
      );

      expect(result.kind, CheckClass.network);
      expect(result.fault, NetworkFault.refused);
      expect(result.outcome, ProbeOutcome.unhealthy);
      expect(counts, {'GET': 1});
    });

    test('no headers within the timeout is network, timeout', () async {
      final (result, _, _) = await _check(
        (_) => Completer<http.StreamedResponse>().future,
        timeout: const Duration(milliseconds: 10),
      );

      expect(result.kind, CheckClass.network);
      expect(result.fault, NetworkFault.timeout);
    });

    test('the race keeps its HEAD after a network error', () async {
      final (result, counts, _) = await _check((request) {
        if (request.method == 'GET') {
          throw http.ClientException('refused', request.url);
        }
        return _answer(200);
      }, headAfterError: true);

      expect(result.outcome, ProbeOutcome.healthy);
      expect(counts, {'GET': 1, 'HEAD': 1});
    });

    test('a page is notVideo, a playlist is healthy, a server that ignores '
        'ranges is unseekable, as the race reads them', () async {
      final (page, _, _) = await _check(
        (_) => _answer(
          200,
          headers: const {'content-type': 'text/html'},
          body: '<!doctype html><html><body>Link Generator</body></html>'
              .codeUnits,
        ),
      );
      expect(page.kind, CheckClass.answers);
      expect(page.outcome, ProbeOutcome.notVideo);

      final (playlist, _, _) = await _check(
        (_) => _answer(
          200,
          headers: const {'content-type': 'application/vnd.apple.mpegurl'},
          body: '#EXTM3U\n'.codeUnits,
        ),
        stream: _film('index.m3u8'),
      );
      expect(playlist.outcome, ProbeOutcome.healthy);

      final (whole, _, _) = await _check(
        (_) => _answer(200, headers: const {'content-type': 'video/mp4'}),
      );
      expect(whole.outcome, ProbeOutcome.unseekable);
    });

    test('a torrent or a local file passes with no request', () async {
      for (final url in ['magnet:?xt=urn:btih:abc', '/data/film.mkv']) {
        final (result, counts, _) = await _check(
          (_) => _answer(500),
          stream: StreamResult(url: url, source: 'Test'),
        );
        expect(result.kind, CheckClass.answers, reason: url);
        expect(counts, isEmpty, reason: url);
      }
    });

    test('probeSource gives the race its outcome for every class', () async {
      Future<ProbeOutcome> probe(int status) => http.runWithClient(
        () => probeSource(_film()),
        () => MockClient((request) async => http.Response('', status)),
      );

      expect(await probe(206), ProbeOutcome.healthy);
      expect(await probe(404), ProbeOutcome.unhealthy);
      expect(await probe(503), ProbeOutcome.unhealthy);
    });
  });
}
