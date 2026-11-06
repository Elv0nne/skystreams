import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_broker.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';

import 'fakes.dart';

final _keys = SiteKeys.parse(
  File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
);

/// A solver that notes how it was asked.
class _SpySolver extends ClearanceSolver {
  _SpySolver({
    required super.store,
    required super.siteKeys,
    required super.openPage,
  }) : super(
         needsPersonAfter: const Duration(milliseconds: 100),
         giveUpAfter: const Duration(milliseconds: 150),
         pollEvery: const Duration(milliseconds: 2),
         callLimit: const Duration(milliseconds: 200),
       );

  final asked = <({Uri url, bool personWaiting})>[];

  @override
  Future<SolveOutcome> solve(Uri url, {bool personWaiting = false}) {
    asked.add((url: url, personWaiting: personWaiting));
    return super.solve(url, personWaiting: personWaiting);
  }
}

/// The app's side of clearing a check for engines outside the shared HTTP
/// client: CloudStream's, and Nuvio's workers.
void main() {
  late ClearanceStore store;
  late PageFactory pages;
  late _SpySolver solver;

  ClearanceBroker broker(List<FakePage> pageList) {
    pages = PageFactory(pageList);
    solver = _SpySolver(store: store, siteKeys: _keys, openPage: pages.call);
    Clearance.instance.debugUse(store: store, siteKeys: _keys, solver: solver);
    return ClearanceBroker(Clearance.instance);
  }

  void cleared(String site, {DateTime? at}) => store.recordSolve(
    site,
    cookies: [
      StoredCookie(name: 'cf_clearance', value: 'ok', domain: '.$site'),
    ],
    agent: 'Browser/1.0',
    url: 'https://$site/',
  );

  /// A page that shows Cloudflare's check, then clears it.
  FakePage clearing() =>
      FakePage(const [Step.check(), Step('Example', clearance: 'fresh')]);

  /// A page that answers requests sent from inside it.
  FakePage answering(String body) => FakePage(
    const [Step('Example')],
    onFetch: (request) async => InPageResponse(
      status: 200,
      url: Uri.parse(request.url),
      headers: const {'content-type': 'text/html'},
      body: body,
    ),
  );

  const page = InPageRequest('https://www.example.com/movie/1');

  setUp(() => store = ClearanceStore());

  tearDown(() => Clearance.instance.solver.dispose());

  group('solve', () {
    test('a fresh clearance goes back as it is, opening no page', () async {
      var now = DateTime(2026, 10, 10, 12);
      store = ClearanceStore(clock: () => now);
      final b = broker([clearing()]);
      cleared('example.com');
      now = now.add(const Duration(minutes: 2));
      final grant = await b.solve(Uri.parse('https://www.example.com/a'));
      expect(grant?.site, 'example.com');
      expect(grant?.cookies, {'cf_clearance': 'ok'});
      expect(grant?.agent, 'Browser/1.0');
      expect(grant?.earned, isFalse);
      expect(pages.opened, 0);
    });

    test('an uncleared site is filed under its source and solved, a person waiting or not', () async {
      final b = broker([clearing()]);
      final grant = await b.solve(
        Uri.parse('https://www.example.com/a'),
        source: 'nuvio:vixsrc',
        personWaiting: true,
      );
      expect(grant?.cookies, {'cf_clearance': 'fresh'});
      expect(grant?.agent, store['example.com']!.agent);
      expect(grant?.earned, isTrue);
      expect(solver.asked.single.personWaiting, isTrue);
      expect(Clearance.instance.checks['example.com']!.sources, {
        'nuvio:vixsrc',
      });
    });

    test('a refused clearance it holds has lapsed, however fresh: solved again, its lifetime learned', () async {
      // The streaming follow-ups' review: a clearance that lapsed sooner than the app expected went back as fresh,
      // met the check again, and the engine marked the site browser-only for good.
      var now = DateTime(2026, 10, 10, 12);
      store = ClearanceStore(clock: () => now);
      final b = broker([clearing()]);
      cleared('example.com');
      now = now.add(const Duration(minutes: 16));
      final grant = await b.solve(
        Uri.parse('https://www.example.com/a'),
        failed: {'cf_clearance': 'ok'},
      );
      expect(pages.opened, 1);
      expect(grant?.cookies, {'cf_clearance': 'fresh'});
      expect(grant?.earned, isTrue);
      expect(store['example.com']!.lifetime, const Duration(minutes: 15));
    });

    test('a refused clearance it no longer holds leaves the fresh one it holds to go back', () async {
      // A request sent before the last solve: the clearance it carried is gone, the new one is the answer.
      var now = DateTime(2026, 10, 10, 12);
      store = ClearanceStore(clock: () => now);
      final b = broker([clearing()]);
      cleared('example.com');
      now = now.add(const Duration(minutes: 2));
      final grant = await b.solve(
        Uri.parse('https://www.example.com/a'),
        failed: {'cf_clearance': 'older'},
      );
      expect(pages.opened, 0);
      expect(grant?.cookies, {'cf_clearance': 'ok'});
      expect(grant?.earned, isFalse);
    });
    test('a refused clearance solved moments ago didn\'t lapse: it goes back as earned, opening no page', () async {
      // The streaming follow-ups' second review: a request sent with a clearance just solved, and answered by the check
      // after it, had the app drop it, learn a 5-minute lifetime and solve again. A clearance that new meeting the
      // check says the site lets only the browser through, as the app's own interceptor reads it.
      final b = broker([clearing()]);
      cleared('example.com');
      final grant = await b.solve(
        Uri.parse('https://www.example.com/a'),
        failed: {'cf_clearance': 'ok'},
      );
      expect(pages.opened, 0);
      expect(grant?.cookies, {'cf_clearance': 'ok'});
      expect(grant?.earned, isTrue);
      expect(store['example.com']!.lifetime, isNull);
    });

    test('two requests naming the same refused clearance at once share one solve, its lifetime learned once', () async {
      var now = DateTime(2026, 10, 10, 12);
      store = ClearanceStore(clock: () => now);
      final b = broker([clearing()]);
      cleared('example.com');
      now = now.add(const Duration(minutes: 16));
      final url = Uri.parse('https://www.example.com/a');
      final grants = await Future.wait([
        b.solve(url, failed: {'cf_clearance': 'ok'}),
        b.solve(url, failed: {'cf_clearance': 'ok'}),
      ]);
      expect(pages.opened, 1);
      expect(
        [for (final g in grants) g?.cookies],
        [
          {'cf_clearance': 'fresh'},
          {'cf_clearance': 'fresh'},
        ],
      );
      expect([for (final g in grants) g?.earned], [true, true]);
      expect(store['example.com']!.lifetime, const Duration(minutes: 15));
    });

    test('a refused clearance is the one held only when every cookie it names matches', () async {
      var now = DateTime(2026, 10, 10, 12);
      store = ClearanceStore(clock: () => now);
      final b = broker([clearing()]);
      store.recordSolve(
        'example.com',
        cookies: const [
          StoredCookie(
            name: 'cf_clearance',
            value: 'ok',
            domain: '.example.com',
          ),
          StoredCookie(name: '__cf_bm', value: 'a', domain: '.example.com'),
        ],
        agent: 'Browser/1.0',
        url: 'https://example.com/',
      );
      now = now.add(const Duration(minutes: 2));
      final url = Uri.parse('https://www.example.com/a');
      final other = await b.solve(
        url,
        failed: {'cf_clearance': 'ok', '__cf_bm': 'b'},
      );
      expect(pages.opened, 0);
      expect(other?.earned, isFalse);
      final named = await b.solve(url, failed: {'cf_clearance': 'ok'});
      expect(pages.opened, 1);
      expect(named?.earned, isTrue);
    });
  });

  test(
    'a request sent from the site\'s page marks the site browser-only',
    () async {
      final b = broker([answering('from the page')]);
      cleared('example.com');
      final response = await b.sendFromPage(
        Uri.parse('https://example.com/list'),
        const InPageRequest('https://example.com/list'),
      );
      expect(response?.body, 'from the page');
      expect(store['example.com']!.browserOnly, isTrue);
    },
  );

  group('a challenged request', () {
    test('on a site solving can\'t help yet keeps its challenge', () async {
      final b = broker([clearing()]);
      solver.markIneffective('example.com');
      final answer = await b.answerChallenge(
        Uri.parse('https://www.example.com/movie/1'),
        page,
        source: 'nuvio:a',
      );
      expect(answer, isA<KeepChallenge>());
      expect(Clearance.instance.checks['example.com']!.sources, {'nuvio:a'});
    });

    test('sent again after a solve and still challenged goes through the site\'s page', () async {
      // Solved minutes ago: only being sent again with it says the site
      // refuses requests from outside the browser.
      var now = DateTime(2026, 10, 3, 9);
      store = ClearanceStore(clock: () => now);
      final b = broker([answering('the movie')]);
      cleared('example.com');
      now = now.add(const Duration(minutes: 5));
      final answer = await b.answerChallenge(
        Uri.parse('https://www.example.com/movie/1'),
        page,
        retried: true,
      );
      expect((answer as UsePageResponse).response.body, 'the movie');
      expect(store['example.com']!.browserOnly, isTrue);
    });

    test('challenged right after another\'s solve is solved again, not taken as browser-only', () async {
      // A run sends with the clearances it started with: one cleared since
      // wasn't on the request. Only a request sent again with a clearance
      // tells (retried).
      final b = broker([clearing()]);
      cleared('example.com');
      final answer = await b.answerChallenge(
        Uri.parse('https://www.example.com/movie/1'),
        page,
      );
      expect((answer as SendWithGrant).grant.cookies, {
        'cf_clearance': 'fresh',
      });
      expect(store['example.com']!.browserOnly, isFalse);
    });

    test(
      'is solved, with its person waiting, and sent again with the clearance',
      () async {
        final b = broker([clearing()]);
        final answer = await b.answerChallenge(
          Uri.parse('https://www.example.com/movie/1'),
          page,
          source: 'nuvio:a',
          personWaiting: true,
        );
        final grant = (answer as SendWithGrant).grant;
        expect(grant.site, 'example.com');
        expect(grant.cookies, {'cf_clearance': 'fresh'});
        expect(solver.asked.single.personWaiting, isTrue);
        // A page request opens its own address.
        expect(
          solver.asked.single.url,
          Uri.parse('https://www.example.com/movie/1'),
        );
      },
    );

    test('an API request opens the site\'s root for its check', () async {
      final b = broker([clearing()]);
      await b.answerChallenge(
        Uri.parse('https://api.example.com/v1/search?q=a'),
        const InPageRequest(
          'https://api.example.com/v1/search?q=a',
          headers: {'Accept': 'application/json'},
        ),
      );
      expect(solver.asked.single.url, Uri.parse('https://api.example.com/'));
    });

    test('that the solve doesn\'t clear keeps its challenge', () async {
      final b = broker([
        FakePage(const [Step.check()]),
      ]);
      final answer = await b.answerChallenge(
        Uri.parse('https://www.example.com/movie/1'),
        page,
      );
      expect(answer, isA<KeepChallenge>());
    });
  });

  test('an API call on a site\'s own port is checked at that port\'s root', () {
    expect(
      ClearanceBroker.checkUrlFor(
        Uri.parse('http://127.0.0.1:8123/api/streams?id=603'),
        const InPageRequest(
          'http://127.0.0.1:8123/api/streams?id=603',
          headers: {'Accept': 'application/json'},
        ),
      ),
      Uri.parse('http://127.0.0.1:8123/'),
    );
  });

  test('the live clearances are the sites that hold one', () {
    broker([clearing()]);
    cleared('example.com');
    store.recordCheck('other.com', 'https://other.com/');
    store.markBrowserOnly('example.com');
    expect(Clearance.instance.liveClearances(), [
      {
        'site': 'example.com',
        'cookies': {'cf_clearance': 'ok'},
        'userAgent': 'Browser/1.0',
        'browserOnly': true,
      },
    ]);
  });
}
