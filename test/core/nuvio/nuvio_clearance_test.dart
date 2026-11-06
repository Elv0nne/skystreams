import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/nuvio/data/nuvio_clearance.dart';
import 'package:skystream/core/nuvio/data/nuvio_engine.dart';
import 'package:skystream/core/nuvio/data/nuvio_polyfill.dart';

/// The main side as a scraper's worker sees it: answers set by the test.
class _Channel implements NuvioClearanceChannel {
  NuvioAnswer answer = const NuvioAnswer();
  NuvioAnswer retriedAnswer = const NuvioAnswer();
  NuvioAnswer pageAnswer = const NuvioAnswer();
  Duration delay = Duration.zero;
  NuvioRunClock? clock;
  bool pausedDuringCall = false;

  final challenged = <({Map<String, dynamic> request, bool retried})>[];
  final fromPages = <Map<String, dynamic>>[];
  final solves = <String>[];

  @override
  Future<NuvioAnswer> challengedRequest(
    Map<String, dynamic> request, {
    required bool retried,
  }) async {
    challenged.add((request: request, retried: retried));
    pausedDuringCall = clock?.isPaused ?? false;
    await Future<void>.delayed(delay);
    return retried ? retriedAnswer : answer;
  }

  @override
  Future<NuvioAnswer> fromPage(Map<String, dynamic> request) async {
    fromPages.add(request);
    return pageAnswer;
  }

  @override
  Future<NuvioGrant?> solve(String url) async {
    solves.add(url);
    return answer.grant;
  }
}

const _grant = NuvioGrant(
  site: '127.0.0.1',
  cookies: {'cf_clearance': 'granted'},
  agent: 'Granted/1.0',
);

/// Nuvio scrapers' requests meeting bot checks, in the worker.
void main() {
  late HttpServer server;
  late String base;
  final seen = <({String path, String? cookie, String? agent})>[];

  void challenge(HttpResponse response) {
    response.statusCode = 403;
    response.headers.set('cf-mitigated', 'challenge');
    response.headers.set('server', 'cloudflare');
    response.write('<title>Just a moment...</title>');
  }

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final cookie = request.headers.value('cookie');
      final agent = request.headers.value('user-agent');
      seen.add((path: request.uri.path, cookie: cookie, agent: agent));
      final response = request.response;
      switch (request.uri.path) {
        case '/movie':
          // Cleared only with the clearance's cookie and the agent it was
          // issued to.
          if ((cookie ?? '').contains('cf_clearance=granted') &&
              agent == 'Granted/1.0') {
            response.write('the movie');
          } else {
            challenge(response);
          }
        case '/always':
          challenge(response);
        case '/anubis':
          // Anubis answers 200 with its check page until the request carries
          // the clearance.
          if ((cookie ?? '').contains('cf_clearance=granted') &&
              agent == 'Granted/1.0') {
            response.write('the movie');
          } else {
            response.headers.contentType = ContentType.html;
            response.write(
              "<title>Making sure you're not a bot!</title>"
              '<link rel="stylesheet" href="/.within.website/x/xess/xess.min.css">',
            );
          }
        case '/denied':
          // Refused, with nothing that says it's a check.
          response.statusCode = 403;
          response.write('denied');
        case '/block':
          response.statusCode = 403;
          response.headers.set('server', 'cloudflare');
          response.write(
            '<title>Attention Required! | Cloudflare</title> '
            'Sorry, you have been blocked',
          );
        default:
          response.write('ok');
      }
      await response.close();
    });
  });

  tearDown(() => server.close(force: true));

  Map<String, dynamic> get(String path, [Map<String, String>? headers]) => {
    'url': '$base$path',
    'method': 'GET',
    'headers': ?headers,
  };

  test(
    'a challenge is solved once and the request sent again with the clearance',
    () async {
      final channel = _Channel()..answer = const NuvioAnswer(grant: _grant);
      final http = NuvioEngineHttp(channel: channel);
      addTearDown(http.close);

      final payload = await http.fetch(get('/movie'));

      expect(payload['status'], 200);
      expect(payload['body'], 'the movie');
      expect(channel.challenged.single.retried, isFalse);
      expect(channel.challenged.single.request['url'], '$base/movie');
      expect(seen.last.cookie, contains('cf_clearance=granted'));
      expect(seen.last.agent, 'Granted/1.0');
    },
  );

  test("a 200 page that is Anubis's check is solved too", () async {
    final channel = _Channel()..answer = const NuvioAnswer(grant: _grant);
    final http = NuvioEngineHttp(channel: channel);
    addTearDown(http.close);

    final payload = await http.fetch(get('/anubis'));

    expect(payload['status'], 200);
    expect(payload['body'], 'the movie');
    expect(channel.challenged.single.request['url'], '$base/anubis');
  });

  test('a block page never asks for a solve', () async {
    final channel = _Channel()..answer = const NuvioAnswer(grant: _grant);
    final http = NuvioEngineHttp(channel: channel);
    addTearDown(http.close);

    final payload = await http.fetch(get('/block'));

    expect(payload['status'], 403);
    expect(channel.challenged, isEmpty);
  });

  test(
    'sent again and still challenged, it goes through the site\'s page',
    () async {
      final channel = _Channel()
        ..answer = const NuvioAnswer(grant: _grant)
        ..retriedAnswer = const NuvioAnswer(
          response: {
            'status': 200,
            'url': 'https://example.com/always',
            'headers': {'Content-Type': 'text/html'},
            'body': 'from the page',
          },
        );
      final http = NuvioEngineHttp(channel: channel);
      addTearDown(http.close);

      final payload = await http.fetch(get('/always'));

      expect([for (final c in channel.challenged) c.retried], [false, true]);
      expect(payload['status'], 200);
      expect(payload['ok'], isTrue);
      expect(payload['body'], 'from the page');
      expect(payload['headers'], {'content-type': 'text/html'});
    },
  );

  test('two requests to a site challenged together share one solve', () async {
    final channel = _Channel()
      ..answer = const NuvioAnswer(grant: _grant)
      ..delay = const Duration(milliseconds: 100);
    final http = NuvioEngineHttp(channel: channel);
    addTearDown(http.close);

    final both = await Future.wait([
      http.fetch(get('/movie')),
      http.fetch(get('/movie')),
    ]);

    expect(channel.challenged, hasLength(1));
    expect([for (final p in both) p['body']], ['the movie', 'the movie']);
  });

  test('a run that may not start a solve gets the challenge', () async {
    final channel = _Channel()..answer = const NuvioAnswer(grant: _grant);
    final http = NuvioEngineHttp(channel: channel, mayStart: false);
    addTearDown(http.close);

    final payload = await http.fetch(get('/movie'));

    expect(payload['status'], 403);
    expect(channel.challenged, isEmpty);
  });

  test('a live clearance goes with the first request, the scraper\'s own cookies kept', () async {
    final channel = _Channel();
    final http = NuvioEngineHttp(channel: channel, grants: const [_grant]);
    addTearDown(http.close);

    final payload = await http.fetch(
      get('/movie', {'User-Agent': 'Scraper/1.0', 'Cookie': 'session=7'}),
    );

    expect(payload['body'], 'the movie');
    expect(channel.challenged, isEmpty);
    expect(seen.single.agent, 'Granted/1.0');
    expect(seen.single.cookie, contains('session=7'));
    expect(seen.single.cookie, contains('cf_clearance=granted'));
  });

  test(
    'a site that lets only the browser through is asked from its page',
    () async {
      final channel = _Channel()
        ..pageAnswer = const NuvioAnswer(
          response: {
            'status': 200,
            'url': 'https://example.com/movie',
            'headers': <String, String>{},
            'body': 'from the page',
          },
        );
      final http = NuvioEngineHttp(
        channel: channel,
        grants: const [
          NuvioGrant(
            site: '127.0.0.1',
            cookies: {'cf_clearance': 'granted'},
            agent: 'Granted/1.0',
            browserOnly: true,
          ),
        ],
      );
      addTearDown(http.close);

      final payload = await http.fetch(get('/movie'));

      expect(payload['body'], 'from the page');
      expect(channel.fromPages.single['url'], '$base/movie');
      expect(seen, isEmpty);
    },
  );

  test(
    'the run\'s clock stops while the worker waits on the main side',
    () async {
      final clock = NuvioRunClock();
      final channel = _Channel()
        ..answer = const NuvioAnswer(grant: _grant)
        ..clock = clock;
      final http = NuvioEngineHttp(channel: channel, clock: clock);
      addTearDown(http.close);

      await http.fetch(get('/movie'));

      expect(channel.pausedDuringCall, isTrue);
      expect(clock.isPaused, isFalse);
    },
  );

  test(
    'a main side that doesn\'t answer in time leaves the challenge',
    () async {
      final channel = _Channel()
        ..answer = const NuvioAnswer(grant: _grant)
        ..delay = const Duration(seconds: 5);
      final http = NuvioEngineHttp(
        channel: channel,
        maxWait: const Duration(milliseconds: 100),
      );
      addTearDown(http.close);

      final payload = await http.fetch(get('/movie'));

      expect(payload['status'], 403);
    },
  );

  test(
    'Cloudflare.solve asks nothing for a host that answered with a block page',
    () async {
      final channel = _Channel()..answer = const NuvioAnswer(grant: _grant);
      final blocked = NuvioEngineHttp(channel: channel);
      addTearDown(blocked.close);
      await blocked.fetch(get('/block'));
      expect(await blocked.solveFor('$base/movie'), isNull);
      expect(channel.solves, isEmpty);

      // A run the host refused, with no block, asks.
      final other = NuvioEngineHttp(channel: channel);
      addTearDown(other.close);
      await other.fetch(get('/denied'));
      expect((await other.solveFor('$base/movie'))?.agent, 'Granted/1.0');
      expect(channel.solves, ['$base/movie']);
    },
  );

  test(
    'Cloudflare.solve asks nothing for a host that never refused the run',
    () async {
      // A scraper's way to the app's browser is a site that refused it, not
      // any address it names.
      final channel = _Channel()..answer = const NuvioAnswer(grant: _grant);
      final http = NuvioEngineHttp(channel: channel);
      addTearDown(http.close);
      await http.fetch(get('/'));
      expect(await http.solveFor('$base/movie'), isNull);
      expect(channel.solves, isEmpty);
    },
  );

  group('the run clock', () {
    test('counts only running time', () async {
      final clock = NuvioRunClock();
      clock.pause();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(clock.running, lessThan(const Duration(milliseconds: 60)));
      clock.resume();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        clock.running,
        greaterThanOrEqualTo(const Duration(milliseconds: 50)),
      );
    });

    test(
      'expires once the running time reaches the budget, not while paused',
      () async {
        final clock = NuvioRunClock();
        var expired = false;
        unawaited(
          clock
              .expires(
                const Duration(milliseconds: 80),
                every: const Duration(milliseconds: 10),
              )
              .then((_) => expired = true),
        );
        clock.pause();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(expired, isFalse);
        clock.resume();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(expired, isTrue);
      },
    );
  });

  group('the engine', () {
    test('a run carries its source, its person and the live clearances to its worker', () {
      const request = NuvioEngineRequest(
        code: 'x',
        scraperId: 'vixsrc',
        scraperName: 'VixSrc',
        source: 'nuvio:vixsrc',
        personWaiting: true,
        grants: [
          {
            'site': 'example.com',
            'cookies': {'cf_clearance': 'ok'},
            'userAgent': 'Browser/1.0',
          },
        ],
      );
      final back = NuvioEngineRequest.fromMap(
        jsonDecode(jsonEncode(request.toMap())) as Map,
      );
      expect(back.source, 'nuvio:vixsrc');
      expect(back.personWaiting, isTrue);
      expect(back.grants.single['site'], 'example.com');
      expect(NuvioGrant.fromMap(back.grants.single)?.agent, 'Browser/1.0');
      // Older callers: none of it.
      final plain = NuvioEngineRequest.fromMap(const {'code': 'x'});
      expect(plain.source, '');
      expect(plain.personWaiting, isFalse);
      expect(plain.grants, isEmpty);
    });

    test(
      'Cloudflare.solve resolves to the headers scrapers send, or nothing',
      () {
        expect(NuvioEngine.cloudflareReply(null), isNull);
        expect(
          NuvioEngine.cloudflareReply(
            const NuvioGrant(
              site: 'example.com',
              cookies: {'cf_clearance': 'ok', '__cf_bm': 'b'},
              agent: 'Browser/1.0',
            ),
          ),
          {'Cookie': 'cf_clearance=ok; __cf_bm=b', 'User-Agent': 'Browser/1.0'},
        );
      },
    );

    test('scrapers find Cloudflare.solve in their environment', () {
      // QuickJS doesn't run in the test host: the call itself is proven on
      // devices.
      final source = buildNuvioPolyfill(
        scraperIdJson: '"x"',
        settingsJson: '{}',
        tmdbKeyJson: '""',
      );
      expect(source, contains('G.Cloudflare'));
      expect(source, contains("sendMessage('nuvio_cf_solve'"));
    });
  });

  group('between a worker and the main isolate', () {
    test(
      'a worker\'s call reaches the main side and its answer comes back',
      () async {
        final toMain = ReceivePort();
        addTearDown(toMain.close);
        final worker = NuvioWorkerLink(toMain.sendPort);
        final calls = <Map<dynamic, dynamic>>[];
        final main = NuvioMainLink((call) async {
          calls.add(call);
          return const NuvioAnswer(grant: _grant).toMap();
        });
        // The main isolate's replies reach the worker's command port.
        toMain.listen((message) {
          main.handle(message, reply: (answer) => worker.handle(answer));
        });
        final channel = NuvioCallChannel(
          (message) => worker.call(7, message),
          source: 'nuvio:vixsrc',
          personWaiting: true,
        );

        final answer = await channel.challengedRequest({
          'url': 'https://example.com/a',
        }, retried: true);

        expect(answer.grant?.agent, 'Granted/1.0');
        expect(calls.single['op'], 'challenged');
        expect(calls.single['job'], 7);
        expect(calls.single['source'], 'nuvio:vixsrc');
        expect(calls.single['personWaiting'], isTrue);
        expect(calls.single['retried'], isTrue);
        expect(await channel.solve('https://example.com/'), isNotNull);
        expect(calls.last['op'], 'solve');
      },
    );

    test('a job\'s backstop doesn\'t run while it waits on a call', () async {
      final answered = Completer<Map<String, Object?>>();
      final main = NuvioMainLink((_) => answered.future);
      final worker = Completer<String>();
      final guarded = main.guard(
        3,
        worker.future,
        const Duration(milliseconds: 150),
      );
      main.handle({
        'broker': true,
        'call': 0,
        'job': 3,
        'op': 'solve',
      }, reply: (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 400));
      var ended = false;
      unawaited(guarded.then((_) => ended = true));
      await Future<void>.delayed(Duration.zero);
      expect(ended, isFalse);
      answered.complete(const {});
      expect(await guarded, contains('did not answer'));
    });

    test('a run without a worker asks the main side directly', () async {
      final calls = <Map<dynamic, dynamic>>[];
      final channel = NuvioCallChannel(
        (message) async {
          calls.add(message);
          return const NuvioAnswer(response: {'status': 200}).toMap();
        },
        source: 'nuvio:a',
        personWaiting: false,
      );
      final answer = await channel.fromPage({'url': 'https://example.com/a'});
      expect(answer.response, {'status': 200});
      expect(calls.single['op'], 'fromPage');
    });
  });

  test('grants and answers cross isolates as plain maps', () {
    expect(NuvioGrant.fromMap(_grant.toMap())?.toMap(), _grant.toMap());
    expect(_grant.covers('127.0.0.1'), isTrue);
    const site = NuvioGrant(site: 'example.com', cookies: {}, agent: 'A');
    expect(site.covers('www.example.com'), isTrue);
    expect(site.covers('badexample.com'), isFalse);
    final answer = NuvioAnswer.fromMap(
      const NuvioAnswer(grant: _grant, response: {'status': 200}).toMap(),
    );
    expect(answer.grant?.agent, 'Granted/1.0');
    expect(answer.response, {'status': 200});
    expect(NuvioGrant.fromMap({'site': 'x'}), isNull);
  });
}
