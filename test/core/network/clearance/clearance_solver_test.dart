import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_interceptor.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/network/clearance/widget_tap.dart';
import 'package:skystream/core/providers/device_info_provider.dart';

import 'fakes.dart';

final _keys = SiteKeys.parse(
  File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
);

ClearanceSolver _solver(
  ClearanceStore store,
  Future<CheckPage> Function() open, {
  int parallel = 3,
  Duration workAfter = const Duration(milliseconds: 600),
}) => ClearanceSolver(
  store: store,
  siteKeys: _keys,
  openPage: open,
  parallel: parallel,
  pollEvery: const Duration(milliseconds: 2),
  needsPersonAfter: const Duration(milliseconds: 150),
  workAfter: workAfter,
  giveUpAfter: const Duration(milliseconds: 400),
  idlePages: const Duration(milliseconds: 300),
  callLimit: const Duration(milliseconds: 100),
);

/// A solver that taps: first after [tapAfter], then every [tapEvery].
ClearanceSolver _tapper(
  ClearanceStore store,
  Future<CheckPage> Function() open, {
  bool canTap = true,
  bool isolatedWorlds = true,
  bool rtl = false,
  int parallel = 3,
}) => ClearanceSolver(
  store: store,
  siteKeys: _keys,
  openPage: open,
  parallel: parallel,
  pollEvery: const Duration(milliseconds: 2),
  needsPersonAfter: const Duration(milliseconds: 200),
  giveUpAfter: const Duration(milliseconds: 500),
  idlePages: const Duration(milliseconds: 300),
  callLimit: const Duration(milliseconds: 100),
  tapAfter: const Duration(milliseconds: 40),
  tapEvery: const Duration(milliseconds: 30),
  canTap: canTap,
  isolatedWorlds: isolatedWorlds,
  rtl: rtl,
);

const _box = WidgetBox(56, 304, 912, 68);

/// The check, then the site with a fresh clearance.
List<Step> _clears({String value = 'fresh'}) => [
  const Step.check(),
  const Step.check(),
  Step('Example', clearance: value),
];

void main() {
  late ClearanceStore store;

  setUp(() => store = ClearanceStore());

  group('an outdated Android System WebView', () {
    test('tries nothing: no page opens, and the row says so', () async {
      final pages = PageFactory([
        FakePage(const [Step.check()]),
      ]);
      final solver = _solver(store, pages.call)..engineOutdated = true;
      final outcome = await solver.solve(
        Uri.parse('https://www.example.com/'),
        personWaiting: true,
      );
      expect(outcome.result, SolveResult.outdated);
      expect(pages.opened, 0);
      expect(solver.checks['example.com']!.state, CheckState.outdated);
    });

    test('Verify still shows the check, for the person to try', () async {
      var shown = 0;
      final solver =
          _solver(
              store,
              PageFactory([
                FakePage(const [Step.check()]),
              ]).call,
            )
            ..engineOutdated = true
            ..presenter =
                ({required page, required site, required cleared}) async {
                  shown++;
                  return ChallengeSheetResult.closed;
                };
      await solver.verify('example.com');
      expect(shown, 1);
    });

    test("is older than 120, by the version's major", () {
      expect(ClearanceSolver.engineIsOutdated('119.0.6045.193'), isTrue);
      expect(ClearanceSolver.engineIsOutdated('69.0.3497.100'), isTrue);
      expect(ClearanceSolver.engineIsOutdated('120.0.1'), isFalse);
      expect(ClearanceSolver.engineIsOutdated('133.0.6943.137'), isFalse);
      expect(ClearanceSolver.engineIsOutdated(''), isFalse);
      expect(ClearanceSolver.engineIsOutdated('dev build'), isFalse);
    });
  });

  group("don't ask again", () {
    final url = Uri.parse('https://www.example.com/a');

    test('a person-waiting solve of a quiet site opens no sheet; Verify '
        'still does', () async {
      var shown = 0;
      final solver =
          _solver(
              store,
              PageFactory([
                FakePage(const [Step.check()]),
              ]).call,
            )
            ..presenter =
                ({required page, required site, required cleared}) async {
                  shown++;
                  return ChallengeSheetResult.closed;
                };
      store.setQuiet('example.com', true);
      final outcome = await solver.solve(url, personWaiting: true);
      expect(outcome.result, SolveResult.needsPerson);
      expect(shown, 0);
      expect(solver.checks['example.com']!.state, CheckState.needsYou);
      await solver.verify('example.com');
      expect(shown, 1);
    });

    test('a sheet closed with "don\'t open this automatically" makes the '
        'site quiet', () async {
      final solver =
          _solver(
              store,
              PageFactory([
                FakePage(const [Step.check()]),
              ]).call,
            )
            ..presenter = ({
              required page,
              required site,
              required cleared,
            }) async => ChallengeSheetResult.quiet;
      final outcome = await solver.solve(url, personWaiting: true);
      expect(outcome.result, SolveResult.needsPerson);
      expect(store.isQuiet('example.com'), isTrue);
      expect(solver.checks['example.com']!.state, CheckState.needsYou);
    });
  });

  group("Verify's loop guard", () {
    /// A check that mints a new clearance on every look and comes back.
    List<Step> looping() => [
      for (var i = 0; i < 400; i++) Step.check(clearance: 'loop${i ~/ 2}'),
    ];

    /// Shows the page for [shownFor], or until its check clears.
    CheckPresenter presenter(Duration shownFor) =>
        ({required page, required site, required cleared}) async {
          var done = false;
          await Future.any([
            cleared.then((_) => done = true),
            Future<void>.delayed(shownFor),
          ]);
          return done
              ? ChallengeSheetResult.verified
              : ChallengeSheetResult.closed;
        };

    test('after three loops it starts the check afresh, once, and a site that '
        'loops on says it keeps asking', () async {
      final page = FakePage(looping());
      final solver = _solver(store, PageFactory([page]).call)
        ..presenter = presenter(const Duration(milliseconds: 400));
      store.recordCheck('example.com', 'https://example.com/');
      final outcome = await solver.verify('example.com');
      expect(outcome.result, SolveResult.needsPerson);
      expect(page.loads, 2, reason: 'the first load, and one fresh start');
      expect([for (final d in page.deleted) d.name], ['cf_clearance']);
      expect(solver.checks['example.com']!.state, CheckState.keepsAsking);
    });

    test(
      'a check that clears after the fresh start counts as cleared',
      () async {
        final page = FakePage(looping(), clearsOnReload: true);
        final solver = _solver(store, PageFactory([page]).call)
          ..presenter = presenter(const Duration(milliseconds: 600));
        store.recordCheck('example.com', 'https://example.com/');
        final outcome = await solver.verify('example.com');
        expect(outcome.result, SolveResult.cleared);
        expect(page.loads, 2);
        expect(solver.checks['example.com']!.state, CheckState.cleared);
      },
    );

    test('a check that only waits on the person never restarts', () async {
      final page = FakePage(const [Step.check()]);
      final solver = _solver(store, PageFactory([page]).call)
        ..presenter = presenter(const Duration(milliseconds: 200));
      store.recordCheck('example.com', 'https://example.com/');
      await solver.verify('example.com');
      expect(page.loads, 1);
      expect(page.deleted, isEmpty);
      expect(solver.checks['example.com']!.state, CheckState.needsYou);
    });
  });

  group('taps the checkbox', () {
    final url = Uri.parse('https://www.example.com/a');

    test(
      'a check that clears by itself before the first tap gets none',
      () async {
        final page = FakePage(
          const [],
          clearsAfter: const Duration(milliseconds: 10),
          widget: _box,
        );
        final outcome = await _tapper(
          store,
          PageFactory([page]).call,
        ).solve(url);
        expect(outcome.result, SolveResult.cleared);
        expect(page.taps, isEmpty);
      },
    );

    test("the first tap comes after tapAfter, 25 px in from the widget's start edge", () async {
      final page = FakePage(
        const [Step.check()],
        widget: _box,
        clearsAfterTaps: 1,
      );
      final outcome = await _tapper(store, PageFactory([page]).call).solve(url);
      expect(outcome.result, SolveResult.cleared);
      expect(store['example.com']!.cookies.single.value, 'tapped');
      expect([for (final t in page.taps) (t.x, t.y)], [(81.0, 338.0)]);
      expect(
        page.taps.single.at,
        greaterThanOrEqualTo(const Duration(milliseconds: 40)),
      );
    });

    test('at most three taps, tapEvery apart, then the person, with the page kept for Verify', () async {
      final page = FakePage(const [Step.check()], widget: _box);
      final outcome = await _tapper(store, PageFactory([page]).call).solve(url);
      expect(outcome.result, SolveResult.needsPerson);
      expect(page.taps, hasLength(3));
      for (var i = 1; i < page.taps.length; i++) {
        expect(
          page.taps[i].at - page.taps[i - 1].at,
          greaterThanOrEqualTo(const Duration(milliseconds: 25)),
          reason: 'taps $i and ${i + 1} are tapEvery apart',
        );
      }
      expect(page.disposed, isFalse, reason: 'parked for the sheet');
    });

    test(
      'nothing taps where the platform can\'t (iOS): the person, as before',
      () async {
        final page = FakePage(const [Step.check()], widget: _box);
        final outcome = await _tapper(
          store,
          PageFactory([page]).call,
          canTap: false,
        ).solve(url);
        expect(outcome.result, SolveResult.needsPerson);
        expect(page.taps, isEmpty);
        expect(page.widgetAsked, isEmpty);
      },
    );

    test('a check that clears just before the tap gets none: the page is looked at again first', () async {
      final page = FakePage(
        const [Step.check()],
        widget: _box,
        onWidgetBox: (p) => p.clearNow(),
      );
      final outcome = await _tapper(store, PageFactory([page]).call).solve(url);
      expect(outcome.result, SolveResult.cleared);
      expect(page.taps, isEmpty);
      expect(page.widgetAsked, isNotEmpty);
    });

    test('a widget whose token is already filled gets no tap', () async {
      final page = FakePage(const [
        Step.check(),
      ], widget: const WidgetBox(56, 304, 912, 68, answered: true));
      await _tapper(store, PageFactory([page]).call).solve(url);
      expect(page.taps, isEmpty);
    });

    test("without an isolated world (Android) the tap goes to the widget's fixed place", () async {
      final page = FakePage(const [Step.check()], clearsAfterTaps: 1);
      final outcome = await _tapper(
        store,
        PageFactory([page]).call,
        isolatedWorlds: false,
      ).solve(url);
      expect(outcome.result, SolveResult.cleared);
      expect([for (final t in page.taps) (t.x, t.y)], [(81.0, 338.0)]);
    });

    test("a Cloudflare check that passes into another vendor's gets no more "
        'taps (kinoger.com: then HostAdmin\'s)', () async {
      final page = FakePage(
        const [],
        timeline: const [
          (Duration.zero, Step.check()),
          (
            Duration(milliseconds: 60),
            Step('Verification...', clearance: 'cf'),
          ),
          (Duration(milliseconds: 400), Step('Kinoger', clearance: 'cf')),
        ],
      );
      final outcome = await _tapper(
        store,
        PageFactory([page]).call,
        isolatedWorlds: false,
      ).solve(url);
      expect(outcome.result, SolveResult.cleared);
      expect(page.taps, isNotEmpty, reason: "Cloudflare's check is tapped");
      for (final tap in page.taps) {
        expect(
          tap.at,
          lessThan(const Duration(milliseconds: 60)),
          reason: "no tap once HostAdmin's check shows",
        );
      }
    });

    test('in Arabic or Hebrew the blind taps start at the raised row, then '
        'try the other', () async {
      final page = FakePage(const [Step.check()]);
      final solver = _tapper(
        store,
        PageFactory([page]).call,
        isolatedWorlds: false,
        rtl: true,
      )..widgetRaised = true;
      await solver.solve(url);
      expect(
        [for (final t in page.taps) (t.x, t.y)],
        [(943.0, 314.5), (943.0, 314.5), (943.0, 338.0)],
      );
    });

    test('a right-to-left language mirrors the fixed place', () async {
      final page = FakePage(const [Step.check()], clearsAfterTaps: 1);
      await _tapper(
        store,
        PageFactory([page]).call,
        isolatedWorlds: false,
        rtl: true,
      ).solve(url);
      expect([for (final t in page.taps) (t.x, t.y)], [(943.0, 338.0)]);
    });

    test('with an isolated world, no widget found means no tap', () async {
      final page = FakePage(const [Step.check()]);
      final outcome = await _tapper(store, PageFactory([page]).call).solve(url);
      expect(outcome.result, SolveResult.needsPerson);
      expect(page.taps, isEmpty);
    });

    test(
      'a check that comes back after each new clearance stops the taps: a loop',
      () async {
        final page = FakePage(
          const [Step.check()],
          widget: _box,
          loopsOnTap: true,
        );
        final outcome = await _tapper(
          store,
          PageFactory([page]).call,
        ).solve(url);
        expect(outcome.result, SolveResult.needsPerson);
        expect(
          page.taps,
          hasLength(2),
          reason: 'two new clearances and the check back: no third tap',
        );
      },
    );

    test("Anubis's check clears by itself once its title goes, with no cf_clearance, and isn't tapped", () async {
      const anubis = Step("Making sure you're not a bot!");
      final page = FakePage([
        for (var i = 0; i < 6; i++) anubis,
        const Step(
          'Site',
          cookies: [
            StoredCookie(
              name: 'techaro.lol-anubis-auth-1',
              value: 'jwt',
              domain: 'www.example.com',
            ),
          ],
        ),
      ], widget: _box);
      final outcome = await _tapper(store, PageFactory([page]).call).solve(url);
      expect(outcome.result, SolveResult.cleared);
      expect(
        [for (final c in store['example.com']!.cookies) c.name],
        ['techaro.lol-anubis-auth-1'],
        reason: "recorded once past the check, not while it showed",
      );
      expect(page.taps, isEmpty);
    });

    test(
      "AWS WAF's untitled check page counts as a check, and isn't tapped",
      () async {
        final page = FakePage([
          for (var i = 0; i < 6; i++) const Step('', awsWaf: true),
          const Step(
            'IMDb',
            cookies: [
              StoredCookie(
                name: 'aws-waf-token',
                value: 't',
                domain: '.example.com',
              ),
            ],
          ),
        ], widget: _box);
        final outcome = await _tapper(
          store,
          PageFactory([page]).call,
        ).solve(url);
        expect(outcome.result, SolveResult.cleared);
        expect(
          [for (final c in store['example.com']!.cookies) c.name],
          ['aws-waf-token'],
        );
        expect(page.taps, isEmpty);
      },
    );

    test('a check that only computes (Anubis, HostAdmin, AWS WAF, Vercel) '
        'gets until workAfter before it needs a person', () async {
      for (final check in const [
        Step("Making sure you're not a bot!"),
        Step('Verification...'),
        Step('', awsWaf: true),
        Step('Vercel Security Checkpoint'),
      ]) {
        final page = FakePage(
          const [],
          clearsAfter: const Duration(milliseconds: 300),
          timedCheck: check,
        );
        final outcome = await _solver(
          ClearanceStore(),
          PageFactory([page]).call,
        ).solve(url);
        expect(outcome.result, SolveResult.cleared, reason: check.title);
      }
    });

    test("a computed check's page that can't be read for a while (busy, "
        'between documents) is not given up at giveUpAfter', () async {
      final page = FakePage(
        const [],
        timeline: const [
          (Duration.zero, Step("Making sure you're not a bot!")),
          (Duration(milliseconds: 100), Step.blank()),
          (Duration(milliseconds: 600), Step('Example', clearance: 'done')),
        ],
      );
      final outcome = await _solver(store, PageFactory([page]).call).solve(url);
      expect(outcome.result, SolveResult.cleared);
    });

    test('one still computing at workAfter needs a person, then', () async {
      final page = FakePage(
        const [],
        clearsAfter: const Duration(seconds: 5),
        timedCheck: const Step("Making sure you're not a bot!"),
      );
      final watch = Stopwatch()..start();
      final outcome = await _solver(
        store,
        PageFactory([page]).call,
        workAfter: const Duration(milliseconds: 300),
      ).solve(url);
      expect(outcome.result, SolveResult.needsPerson);
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 300)),
      );
    });

    test("Cloudflare's and DDoS-Guard's checks still go to a person at "
        'needsPersonAfter', () async {
      for (final check in const [Step.check(), Step('DDoS-Guard')]) {
        final page = FakePage(
          const [],
          clearsAfter: const Duration(milliseconds: 300),
          timedCheck: check,
        );
        final outcome = await _solver(
          ClearanceStore(),
          PageFactory([page]).call,
        ).solve(url);
        expect(outcome.result, SolveResult.needsPerson, reason: check.title);
      }
    });

    test("DDoS-Guard's check is never tapped", () async {
      final page = FakePage(const [Step('DDoS-Guard')], widget: _box);
      await _tapper(store, PageFactory([page]).call).solve(url);
      expect(page.taps, isEmpty);
    });

    test(
      'beside other solves, the first tap waits on the stretched clock',
      () async {
        final pages = [
          for (var i = 0; i < 3; i++)
            FakePage(const [Step.check()], widget: _box),
        ];
        final solver = _tapper(store, PageFactory(pages).call);
        await Future.wait([
          for (final site in [
            'a.example.com',
            'b.example.org',
            'c.example.net',
          ])
            solver.solve(Uri.parse('https://$site/')),
        ]);
        for (final page in pages) {
          expect(page.taps, isNotEmpty);
          // Three at once run 1 + 0.5 × 2 = 2 times as long: the first tap at 2 × 40 ms.
          expect(
            page.taps.first.at,
            greaterThanOrEqualTo(const Duration(milliseconds: 70)),
          );
        }
      },
    );

    test('Verify while a solve is tapping waits for it, and nothing taps the page the sheet shows', () async {
      final page = FakePage(const [Step.check()], widget: _box);
      final solver = _tapper(store, PageFactory([page]).call);
      Duration? shownAt;
      final loadedAt = DateTime.now();
      solver.presenter =
          ({required page, required site, required cleared}) async {
            shownAt = DateTime.now().difference(loadedAt);
            return ChallengeSheetResult.closed;
          };
      final solving = solver.solve(url);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final verified = solver.verify('example.com');
      expect((await solving).result, SolveResult.needsPerson);
      await verified;
      expect(shownAt, isNotNull);
      expect(page.taps, hasLength(3));
      final tapsAfter = page.taps.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        page.taps,
        hasLength(tapsAfter),
        reason: 'no tap once the sheet has the page',
      );
    });
  });

  group('ClearanceSolver', () {
    test('a cleared check stores the cookies and the agent', () async {
      final pages = PageFactory([FakePage(_clears(), agent: 'WebView/148')]);
      final solver = _solver(store, pages.call);
      final outcome = await solver.solve(
        Uri.parse('https://www.example.com/a'),
      );
      expect(outcome.result, SolveResult.cleared);
      final entry = store['example.com']!;
      expect(entry.cookies.single.value, 'fresh');
      expect(entry.agent, 'WebView/148');
      expect(store.isFresh('example.com'), isTrue);
      expect(pages.pages.single.disposed, isTrue);
    });

    test(
      'a cleared check whose page never finishes loading still clears',
      () async {
        final pages = PageFactory([
          FakePage(const [
            Step.check(),
            Step.check(),
            Step('Example', ready: 'interactive', clearance: 'fresh'),
          ]),
        ]);
        final outcome = await _solver(
          store,
          pages.call,
        ).solve(Uri.parse('https://example.com/'));
        expect(outcome.result, SolveResult.cleared);
        expect(store['example.com']!.cookies.single.value, 'fresh');
      },
    );

    test('one solve per site: later callers join it', () async {
      final pages = PageFactory([FakePage(_clears())]);
      final solver = _solver(store, pages.call);
      final outcomes = await Future.wait([
        solver.solve(Uri.parse('https://example.com/1')),
        solver.solve(Uri.parse('https://cdn.example.com/2')),
        solver.solve(Uri.parse('https://example.com/3')),
      ]);
      expect(outcomes.map((o) => o.result), everyElement(SolveResult.cleared));
      expect(pages.opened, 1);
    });

    test('a few sites at once, never more', () async {
      final pages = PageFactory([
        for (var i = 0; i < 6; i++) FakePage(_clears()),
      ]);
      final solver = _solver(store, pages.call, parallel: 3);
      await Future.wait([
        for (var i = 0; i < 6; i++)
          solver.solve(Uri.parse('https://site$i.com/')),
      ]);
      expect(pages.opened, 6);
      expect(pages.mostOpen, 3);
      expect(solver.activeSolves, 0);
    });

    test('a page that stops answering gives its place up', () async {
      final pages = PageFactory([
        FakePage(const [Step.check()], hangs: true),
        FakePage(_clears()),
      ]);
      final solver = _solver(store, pages.call, parallel: 1);
      final outcomes = await Future.wait([
        solver.solve(Uri.parse('https://stuck.com/')),
        solver.solve(Uri.parse('https://example.com/')),
      ]).timeout(const Duration(seconds: 3));
      expect(outcomes.first.result, SolveResult.failed);
      expect(outcomes.last.result, SolveResult.cleared);
      expect(solver.activeSolves, 0);
    });

    test(
      'a browser-only site whose page stops answering fails its request',
      () async {
        final pages = PageFactory([
          FakePage(const [Step.check()], hangs: true),
        ]);
        final solver = _solver(store, pages.call);
        await expectLater(
          solver
              .fetchInPage(
                Uri.parse('https://example.com/x'),
                const InPageRequest('https://example.com/x'),
              )
              .timeout(const Duration(seconds: 3)),
          throwsA(isNot(isA<TimeoutException>())),
        );
      },
    );

    test(
      'few pages are kept for browser-only sites; the idle oldest goes',
      () async {
        final release = Completer<void>();
        Future<InPageResponse> answer(InPageRequest r) async {
          await release.future;
          return InPageResponse(
            status: 200,
            url: Uri.parse(r.url),
            headers: const {},
            body: r.url,
          );
        }

        final pages = PageFactory([
          for (var i = 0; i < 4; i++)
            FakePage(const [Step('Site')], onFetch: answer),
        ]);
        final solver = ClearanceSolver(
          store: store,
          siteKeys: _keys,
          openPage: pages.call,
          parallel: 3,
          keptOrigins: 2,
          pollEvery: const Duration(milliseconds: 2),
          idlePages: const Duration(seconds: 5),
        );
        final replies = [
          for (var i = 0; i < 4; i++)
            solver.fetchInPage(
              Uri.parse('https://site$i.com/x'),
              InPageRequest('https://site$i.com/x'),
            ),
        ];
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(pages.opened, 2, reason: 'the others wait for a page');
        release.complete();
        final bodies = [for (final r in await Future.wait(replies)) r.body];
        expect(bodies, [for (var i = 0; i < 4; i++) 'https://site$i.com/x']);
        expect(pages.opened, 4);
        expect(pages.mostOpen, 2);
        await solver.dispose();
      },
    );

    test(
      'a page still loading its extras can send the site\'s requests',
      () async {
        final pages = PageFactory([
          FakePage(
            const [Step('Site', ready: 'interactive')],
            onFetch: (r) async => InPageResponse(
              status: 200,
              url: Uri.parse(r.url),
              headers: const {},
              body: 'ok',
            ),
          ),
        ]);
        final solver = _solver(store, pages.call);
        final reply = await solver.fetchInPage(
          Uri.parse('https://example.com/x'),
          const InPageRequest('https://example.com/x'),
        );
        expect(reply.body, 'ok');
        await solver.dispose();
      },
    );

    test(
      'a page sent off to another origin can\'t send the site\'s requests',
      () async {
        final pages = PageFactory([
          FakePage(const [
            Step('Elsewhere', href: 'https://other.com/'),
          ], onFetch: (r) async => throw StateError('should not be sent')),
        ]);
        final solver = _solver(store, pages.call);
        await expectLater(
          solver.fetchInPage(
            Uri.parse('https://example.com/x'),
            const InPageRequest('https://example.com/x'),
          ),
          throwsStateError,
        );
        expect(pages.pages.single.fetched, isEmpty);
        expect(pages.open, 0, reason: 'closed');
      },
    );

    test(
      'a check that loops (a clearance, then the check again) is no clearance',
      () async {
        final pages = PageFactory([
          FakePage([
            const Step.check(),
            const Step('Example', clearance: 'once'),
            const Step.check(clearance: 'once'),
          ]),
        ]);
        final solver = _solver(store, pages.call);
        final outcome = await solver.solve(Uri.parse('https://example.com/'));
        expect(outcome.result, SolveResult.needsPerson);
        expect(store['example.com']!.hasClearance, isFalse);
      },
    );

    test('an old clearance in the browser is not a fresh one', () async {
      final pages = PageFactory([
        FakePage([
          const Step.check(clearance: 'stale'),
          const Step('Example', clearance: 'stale'),
        ]),
      ]);
      final outcome = await _solver(
        store,
        pages.call,
      ).solve(Uri.parse('https://example.com/'));
      expect(outcome.result, isNot(SolveResult.cleared));
    });

    test('DDoS-Guard clears without a Cloudflare cookie', () async {
      final pages = PageFactory([
        FakePage(const [Step('DDoS-Guard'), Step('DDoS-Guard'), Step('Site')]),
      ]);
      final outcome = await _solver(
        store,
        pages.call,
      ).solve(Uri.parse('https://example.com/'));
      expect(outcome.result, SolveResult.cleared);
    });

    test(
      'a check still showing after a while needs a person; its page waits',
      () async {
        final pages = PageFactory([
          FakePage(const [Step.check()]),
        ]);
        final solver = _solver(store, pages.call);
        final outcome = await solver.solve(Uri.parse('https://example.com/x'));
        expect(outcome.result, SolveResult.needsPerson);
        expect(store['example.com']!.needsPerson, isTrue);
        expect(store['example.com']!.checkUrl, 'https://example.com/x');
        expect(solver.parkedSites, {'example.com'});
        expect(pages.pages.single.disposed, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(
          pages.pages.single.disposed,
          isTrue,
          reason: 'parked pages expire',
        );
      },
    );

    test(
      'a site that wanted a person gets no new hidden solve for a while',
      () async {
        final pages = PageFactory([
          FakePage(const [Step.check()]),
        ]);
        final solver = _solver(store, pages.call);
        final url = Uri.parse('https://example.com/x');
        expect((await solver.solve(url)).result, SolveResult.needsPerson);
        expect((await solver.solve(url)).result, SolveResult.needsPerson);
        expect(pages.opened, 1, reason: 'the second fails fast');
      },
    );

    test('the blank page before the site\'s own is no page at all', () async {
      final pages = PageFactory([
        FakePage([
          for (var i = 0; i < 5; i++) const Step.blank(),
          ..._clears(),
        ]),
      ]);
      final outcome = await _solver(
        store,
        pages.call,
      ).solve(Uri.parse('https://example.com/'));
      expect(outcome.result, SolveResult.cleared);
      expect(store['example.com']!.cookies.single.value, 'fresh');
    });

    test(
      'a solve that failed or met a block page isn\'t tried again at once',
      () async {
        final pages = PageFactory([
          FakePage(const [Step.blank()]),
          FakePage(const [Step('Attention Required! | Cloudflare')]),
        ]);
        final solver = _solver(store, pages.call);
        final stuck = Uri.parse('https://stuck.com/');
        final blocked = Uri.parse('https://blocked.com/');
        expect((await solver.solve(stuck)).result, SolveResult.failed);
        expect((await solver.solve(blocked)).result, SolveResult.blocked);
        expect((await solver.solve(stuck)).result, SolveResult.failed);
        expect((await solver.solve(blocked)).result, SolveResult.blocked);
        expect(pages.opened, 2);
      },
    );

    test(
      'pages of every kind share one budget; parked pages go first',
      () async {
        final pages = PageFactory([
          FakePage(const [Step.check()]),
          FakePage(const [Step.check()]),
          FakePage(_clears()),
        ]);
        final solver = _solver(store, pages.call, parallel: 2);
        expect(
          (await solver.solve(Uri.parse('https://a.com/'))).result,
          SolveResult.needsPerson,
        );
        expect(
          (await solver.solve(Uri.parse('https://b.com/'))).result,
          SolveResult.needsPerson,
        );
        expect(solver.parkedSites, {'a.com', 'b.com'});
        expect(
          (await solver.solve(Uri.parse('https://example.com/'))).result,
          SolveResult.cleared,
        );
        expect(pages.mostOpen, 2, reason: 'never more pages than the budget');
        expect(solver.parkedSites, {
          'b.com',
        }, reason: 'the oldest parked page made room');
      },
    );

    test('a parked check that clears by itself clears its site', () async {
      final pages = PageFactory([
        FakePage([
          for (var i = 0; i < 120; i++) const Step.check(),
          ..._clears(value: 'late'),
        ]),
      ]);
      final solver = _solver(store, pages.call);
      final outcome = await solver.solve(Uri.parse('https://example.com/'));
      expect(outcome.result, SolveResult.needsPerson);
      for (var i = 0; i < 100 && solver.parkedSites.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final entry = store['example.com']!;
      expect(entry.cookies.single.value, 'late');
      expect(entry.needsPerson, isFalse);
      expect(solver.parkedSites, isEmpty);
      expect(pages.pages.single.disposed, isTrue);
    });

    test('a site whose page moves to another site is not cleared', () async {
      final pages = PageFactory([
        FakePage(const [
          Step('Domain for sale', href: 'https://www.atom.com/name'),
        ]),
      ]);
      final outcome = await _solver(
        store,
        pages.call,
      ).solve(Uri.parse('https://old-mirror.xyz/'));
      expect(outcome.result, SolveResult.sentElsewhere);
      expect(outcome.elsewhere, 'www.atom.com');
      expect(store['old-mirror.xyz']?.solvedAt, isNull);
    });

    test(
      'a check gets longer to clear while other solves share the device',
      () async {
        const slow = Duration(milliseconds: 220);
        final alone = PageFactory([FakePage(const [], clearsAfter: slow)]);
        final outcome = await _solver(
          store,
          alone.call,
        ).solve(Uri.parse('https://alone.com/'));
        expect(outcome.result, SolveResult.needsPerson);

        final shared = PageFactory([
          for (var i = 0; i < 3; i++) FakePage(const [], clearsAfter: slow),
        ]);
        final solver = _solver(store, shared.call, parallel: 3);
        final outcomes = await Future.wait([
          for (var i = 0; i < 3; i++)
            solver.solve(Uri.parse('https://site$i.com/')),
        ]);
        expect(
          outcomes.map((o) => o.result),
          everyElement(SolveResult.cleared),
        );
      },
    );

    test('a block page is reported, not waited on', () async {
      final pages = PageFactory([
        FakePage(const [Step('Attention Required! | Cloudflare')]),
      ]);
      final outcome = await _solver(
        store,
        pages.call,
      ).solve(Uri.parse('https://example.com/'));
      expect(outcome.result, SolveResult.blocked);
    });

    test(
      'a site that shows the browser no check is recorded as it is',
      () async {
        final pages = PageFactory([
          FakePage(const [Step('Example')]),
        ]);
        final outcome = await _solver(
          store,
          pages.call,
        ).solve(Uri.parse('https://example.com/'));
        expect(outcome.result, SolveResult.cleared);
      },
    );
  });

  group('check states', () {
    late SiteChecks checks;

    setUp(() => checks = SiteChecks());

    ClearanceSolver solverWith(PageFactory pages, {int parallel = 3}) =>
        ClearanceSolver(
          store: store,
          siteKeys: _keys,
          checks: checks,
          openPage: pages.call,
          parallel: parallel,
          pollEvery: const Duration(milliseconds: 2),
          needsPersonAfter: const Duration(milliseconds: 150),
          giveUpAfter: const Duration(milliseconds: 400),
          idlePages: const Duration(milliseconds: 300),
          callLimit: const Duration(milliseconds: 100),
        );

    test('a hidden try is checking, then cleared', () async {
      final solver = solverWith(PageFactory([FakePage(_clears())]));
      final solving = solver.solve(Uri.parse('https://example.com/'));
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(checks['example.com']!.state, CheckState.checking);
      await solving;
      expect(checks['example.com']!.state, CheckState.cleared);
    });

    test('a check that wants a person needs you; a block page is blocked; '
        'a page that never settles is unreachable', () async {
      final solver = solverWith(
        PageFactory([
          FakePage(const [Step.check()]),
          FakePage(const [Step('Attention Required! | Cloudflare')]),
          FakePage(const [Step('', ready: 'loading')]),
        ]),
      );
      await solver.solve(Uri.parse('https://example.com/'));
      await solver.solve(Uri.parse('https://blocked.org/'));
      await solver.solve(Uri.parse('https://slow.net/'));
      expect(checks['example.com']!.state, CheckState.needsYou);
      expect(checks['blocked.org']!.state, CheckState.blocked);
      expect(checks['slow.net']!.state, CheckState.unreachable);
    });

    test('a browser sent to another site after its check is sent elsewhere, '
        'and nothing is recorded', () async {
      final solver = solverWith(
        PageFactory([
          FakePage(const [
            Step.check(),
            Step('Reviews', href: 'https://reviews.org/', clearance: 'x'),
          ]),
        ]),
      );
      final outcome = await solver.solve(Uri.parse('https://example.com/'));
      expect(outcome.result, SolveResult.sentElsewhere);
      expect(outcome.elsewhere, 'reviews.org');
      expect(checks['example.com']!.state, CheckState.sentElsewhere);
      expect(checks['example.com']!.elsewhere, 'reviews.org');
      expect(store.isFresh('example.com'), isFalse);
    });

    test('Verify is opening, then cleared when the check clears', () async {
      final solver = solverWith(PageFactory([FakePage(_clears())]));
      final states = <CheckState>[];
      final sub = checks.changes.listen(
        (_) => states.add(checks['example.com']!.state),
      );
      solver.presenter =
          ({required page, required site, required cleared}) async {
            await cleared;
            return ChallengeSheetResult.verified;
          };
      final outcome = await solver.verify('example.com');
      await pumpEventQueue();
      await sub.cancel();
      expect(outcome.result, SolveResult.cleared);
      expect(states.first, CheckState.opening);
      expect(checks['example.com']!.state, CheckState.cleared);
    });

    test('a closed sheet needs you again', () async {
      final solver = solverWith(
        PageFactory([
          FakePage(const [Step.check()]),
        ]),
      );
      solver.presenter = ({
        required page,
        required site,
        required cleared,
      }) async => ChallengeSheetResult.closed;
      await solver.verify('example.com');
      expect(checks['example.com']!.state, CheckState.needsYou);
    });

    test(
      'Done on a page still showing its check is still not cleared',
      () async {
        final solver = solverWith(
          PageFactory([
            FakePage(const [Step.check()]),
          ]),
        );
        solver.presenter = ({
          required page,
          required site,
          required cleared,
        }) async => ChallengeSheetResult.done;
        final outcome = await solver.verify('example.com');
        expect(outcome.result, SolveResult.needsPerson);
        expect(checks['example.com']!.state, CheckState.stillNotCleared);
        expect(store.isFresh('example.com'), isFalse);
      },
    );

    test(
      'a Verify whose page can\'t be opened goes back to needing a person',
      () async {
        final solver = ClearanceSolver(
          store: store,
          siteKeys: _keys,
          checks: checks,
          openPage: () async => throw StateError('no browser'),
          callLimit: const Duration(milliseconds: 100),
        );
        solver.presenter = ({
          required page,
          required site,
          required cleared,
        }) async => ChallengeSheetResult.done;
        final outcome = await solver.verify('example.com');
        expect(outcome.result, SolveResult.needsPerson);
        expect(checks['example.com']!.state, CheckState.needsYou);
      },
    );

    test(
      'Done on a page past its check counts, on the person\'s word',
      () async {
        final solver = solverWith(
          PageFactory([
            FakePage(const [Step('Example')]),
          ]),
        );
        solver.presenter = ({
          required page,
          required site,
          required cleared,
        }) async => ChallengeSheetResult.done;
        expect(
          (await solver.verify('example.com')).result,
          SolveResult.cleared,
        );
      },
    );

    test('Verify on a site whose try is running joins it, and shows its '
        'page', () async {
      final pages = PageFactory([
        FakePage(const [Step.check()]),
      ]);
      final solver = solverWith(pages, parallel: 2);
      CheckPage? shown;
      solver.presenter =
          ({required page, required site, required cleared}) async {
            shown = page;
            return ChallengeSheetResult.closed;
          };
      final hidden = solver.solve(Uri.parse('https://example.com/'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await solver.verify('example.com');
      await hidden;
      expect(pages.opened, 1, reason: 'no second page for the same site');
      expect(shown, isNotNull);
    });

    test('Verify waiting for room takes a page as soon as one is only kept '
        'warm', () async {
      // One page: another site's hidden try holds it until it wants a person
      // (150 ms), then keeps it warm. Verify, asked meanwhile, must not wait
      // for the warm page's idle timer (600 ms).
      final pages = PageFactory([
        FakePage(const [Step.check()]),
        FakePage(const [Step.check()]),
      ]);
      final solver = solverWith(pages, parallel: 1);
      solver.presenter = ({
        required page,
        required site,
        required cleared,
      }) async => ChallengeSheetResult.closed;
      unawaited(solver.solve(Uri.parse('https://other.com/')));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final watch = Stopwatch()..start();
      await solver.verify('example.com');
      expect(watch.elapsedMilliseconds, lessThan(450));
      expect(pages.opened, 2);
    });
  });

  group('moved sites', () {
    late _Moved site;
    late Dio dio;
    late PageFactory pages;
    late ClearanceSolver solver;

    void build(_Moved adapter, {List<FakePage>? pageList}) {
      site = adapter;
      pages = PageFactory(
        pageList ??
            [FakePage(_clears(value: 'good'), cookieDomain: '.new.org')],
      );
      solver = _solver(store, pages.call);
      dio = Dio()..httpClientAdapter = site;
      dio.interceptors.add(
        ClearanceInterceptor(
          dio: dio,
          store: store,
          solver: solver,
          siteKeys: _keys,
          checks: solver.checks,
        ),
      );
    }

    test(
      'a site that moved is checked and cleared on its new domain',
      () async {
        build(_Moved());
        final response = await dio.get<String>(
          'https://www.old.com/search?q=a',
        );
        expect(response.data, 'results from www.new.org');
        expect(store.movedTo('www.old.com'), Uri.parse('https://www.new.org'));
        expect(pages.pages.single.loaded, 'https://www.new.org/search?q=a');
        expect(site.requests.last.host, 'www.new.org');
        expect(solver.checks['new.org']!.movedFrom, 'old.com');
        expect(store.isFresh('new.org'), isTrue);
      },
    );

    test(
      'later requests to the old domain go straight to the new one',
      () async {
        build(_Moved());
        store
          ..recordMove('www.old.com', Uri.parse('https://www.new.org'))
          ..recordSolve(
            'new.org',
            cookies: const [
              StoredCookie(
                name: 'cf_clearance',
                value: 'good',
                domain: '.new.org',
              ),
            ],
            agent: 'Engine/1.0',
            url: 'https://www.new.org/',
          );
        final response = await dio.get<String>('https://www.old.com/a?b=1');
        expect(response.data, 'results from www.new.org');
        expect(site.requests.single, Uri.parse('https://www.new.org/a?b=1'));
        expect(pages.opened, 0);
      },
    );

    test('a temporary redirect in the chain is no move', () async {
      build(_Moved(codes: const [301, 302]));
      await dio.get<String>('https://www.old.com/search?q=a');
      expect(store.movedTo('www.old.com'), isNull);
    });

    test('a dead new domain drops the move, and the old address is asked '
        'once', () async {
      build(_Moved()..newDown = true);
      store.recordMove('www.old.com', Uri.parse('https://www.new.org'));
      final response = await dio.get<String>('https://www.old.com/a');
      expect(response.data, 'results from www.old.com');
      expect(store.movedTo('www.old.com'), isNull);
      expect(site.requests, [
        Uri.parse('https://www.new.org/a'),
        Uri.parse('https://www.old.com/a'),
      ]);
    });

    test('a move is its host\'s: the old site\'s other hosts stay where '
        'they are', () async {
      build(_Moved());
      await dio.get<String>('https://www.old.com/search?q=a');
      site.requests.clear();
      final response = await dio.get<String>('https://api.old.com/v1');
      expect(site.requests.first, Uri.parse('https://api.old.com/v1'));
      expect(response.data, 'results from api.old.com');
    });

    test('a site that moves again: its old address goes straight to the '
        'newest', () async {
      // Both behind Cloudflare: a check on each, cleared in turn.
      build(
        _Moved()..newerChecks = true,
        pageList: [
          FakePage(_clears(value: 'good'), cookieDomain: '.new.org'),
          FakePage(_clears(value: 'good'), cookieDomain: '.newer.org'),
        ],
      );
      await dio.get<String>('https://www.old.com/a');
      site.newerMove = true;
      await dio.get<String>('https://www.old.com/a');
      site.requests.clear();
      final response = await dio.get<String>('https://www.old.com/a');
      expect(site.requests.first.host, 'www.newer.org');
      expect(response.data, 'results from www.newer.org');
      expect(store.movedTo('www.old.com'), Uri.parse('https://www.newer.org'));
    });

    test('a redirect to a site whose clearance is fresh takes the '
        'clearance there, and is no refusal', () async {
      build(_Moved(codes: const [302]));
      store.recordSolve(
        'new.org',
        cookies: const [
          StoredCookie(name: 'cf_clearance', value: 'good', domain: '.new.org'),
        ],
        agent: 'Engine/1.0',
        url: 'https://www.new.org/',
      );
      final response = await dio.get<String>('https://www.old.com/a');
      expect(response.data, 'results from www.new.org');
      expect(store['new.org']!.browserOnly, isFalse);
      expect(pages.opened, 0);
      expect(solver.checks['new.org']?.pending ?? false, isFalse);
    });

    test('a request sent where its site moved leaves its own cookies '
        'behind', () async {
      build(_Moved());
      final options = Options(headers: {'Cookie': 'session=old'});
      await dio.get<String>('https://www.old.com/a', options: options);
      expect(site.cookies.last, isNot(contains('session=old')));
      await dio.get<String>('https://www.old.com/b', options: options);
      expect(site.requests.last.host, 'www.new.org');
      expect(site.cookies.last, isNot(contains('session=old')));
      expect(site.cookies.last, contains('cf_clearance=good'));
    });

    // GitHub sends a repository's raw address to github.com, path kept, for
    // good: that's no site moving. Only a site behind a bot check is followed.
    test(
      'a permanent redirect to an answer that is no check is no move',
      () async {
        build(_Moved()..newOpen = true);
        final response = await dio.get<String>('https://www.old.com/a');
        expect(response.data, 'results from www.new.org');
        expect(store.movedTo('www.old.com'), isNull);
      },
    );

    test('a site that moved back is no longer sent away', () async {
      build(_Moved()..movedBack = true);
      store.recordMove('www.old.com', Uri.parse('https://www.new.org'));
      final response = await dio.get<String>('https://www.old.com/a');
      expect(response.data, 'results from www.old.com');
      expect(store.movedTo('www.old.com'), isNull);
    });

    test('a new domain whose TLS handshake fails is dead too', () async {
      build(_Moved()..newTlsFails = true);
      store.recordMove('www.old.com', Uri.parse('https://www.new.org'));
      final response = await dio.get<String>('https://www.old.com/a');
      expect(response.data, 'results from www.old.com');
      expect(store.movedTo('www.old.com'), isNull);
    });
  });

  group('Clearance', () {
    test('a low-end device gets two pages, others the platform\'s default', () {
      final solver = _solver(store, PageFactory(const []).call);
      Clearance.instance.debugUse(
        store: store,
        siteKeys: _keys,
        solver: solver,
      );
      Clearance.instance.fitTo(const DeviceProfile(tier: DeviceTier.low));
      expect(solver.parallel, 2);
      expect(solver.keptOrigins, 1);
      Clearance.instance.fitTo(const DeviceProfile());
      expect(solver.parallel, ClearanceSolver.defaultParallel);
      expect(solver.keptOrigins, ClearanceSolver.defaultParallel - 1);
    });
  });

  group('ClearanceInterceptor', () {
    late _Site site;
    late Dio dio;
    late PageFactory pages;
    late ClearanceSolver solver;

    void build({List<FakePage>? pageList}) {
      pages = PageFactory(pageList ?? [FakePage(_clears(value: 'good'))]);
      solver = _solver(store, pages.call);
      dio = Dio()..httpClientAdapter = site;
      dio.interceptors.add(
        ClearanceInterceptor(
          dio: dio,
          store: store,
          solver: solver,
          siteKeys: _keys,
          checks: solver.checks,
        ),
      );
    }

    setUp(() => site = _Site());

    test('a site on hold meets its check: its row says it couldn\'t be '
        'reached, not that it is checking', () async {
      build();
      solver.markIneffective('example.com');
      await dio.get<String>(
        'https://www.example.com/',
        options: Options(validateStatus: (_) => true),
      );
      expect(solver.checks['example.com']!.state, CheckState.ineffective);
    });

    test(
      'an API call on a site\'s own port is checked at that port\'s root',
      () async {
        build();
        await dio.get<String>(
          'https://www.example.com:8443/v1/search?q=a',
          options: Options(headers: {'Accept': 'application/json'}),
        );
        expect(pages.pages.single.loaded, 'https://www.example.com:8443/');
      },
    );

    test(
      "a 200 page that is Anubis's check is solved, and the request sent again",
      () async {
        final anubis = _AnubisSite();
        pages = PageFactory([FakePage(_clears(value: 'good'))]);
        solver = _solver(store, pages.call);
        dio = Dio()..httpClientAdapter = anubis;
        dio.interceptors.add(
          ClearanceInterceptor(
            dio: dio,
            store: store,
            solver: solver,
            siteKeys: _keys,
            checks: solver.checks,
          ),
        );
        final response = await dio.get<String>('https://www.example.com/');
        expect(response.data, 'results');
        expect(pages.opened, 1);
      },
    );

    test(
      "a 200 answer is read for a check only if it's HTML, and then only its "
      'first 16 KB',
      () async {
        // Phase 4's review: every 200 answer read as bytes was decoded whole
        // before its type was looked at (a poster, a subtitle file). Anubis'
        // and HostAdmin's marks are in a page's head, as the engine reads it.
        final read = <String, int>{};
        pages = PageFactory([FakePage(_clears(value: 'good'))]);
        solver = _solver(store, pages.call);
        dio = Dio()..httpClientAdapter = _Large();
        dio.interceptors
          ..add(
            InterceptorsWrapper(
              onResponse: (response, handler) {
                final path = response.requestOptions.uri.path;
                response.data = _Counted(response.data as List<int>, (index) {
                  read[path] = index > (read[path] ?? -1) ? index : read[path]!;
                });
                handler.next(response);
              },
            ),
          )
          ..add(
            ClearanceInterceptor(
              dio: dio,
              store: store,
              solver: solver,
              siteKeys: _keys,
              checks: solver.checks,
            ),
          );
        final bytes = Options(responseType: ResponseType.bytes);
        await dio.get<List<int>>(
          'https://www.example.com/poster.jpg',
          options: bytes,
        );
        await dio.get<List<int>>('https://www.example.com/', options: bytes);
        expect(read['/poster.jpg'], isNull, reason: 'not HTML: never read');
        expect(read['/'], lessThan(16 * 1024));
        expect(pages.opened, 0);
      },
    );

    test('a streamed 200 answer is never read to look for a check', () async {
      final anubis = _AnubisSite();
      pages = PageFactory([FakePage(_clears(value: 'good'))]);
      solver = _solver(store, pages.call);
      dio = Dio()..httpClientAdapter = anubis;
      dio.interceptors.add(
        ClearanceInterceptor(
          dio: dio,
          store: store,
          solver: solver,
          siteKeys: _keys,
          checks: solver.checks,
        ),
      );
      final response = await dio.get<ResponseBody>(
        'https://www.example.com/',
        options: Options(responseType: ResponseType.stream),
      );
      expect(response.statusCode, 200);
      expect(pages.opened, 0);
    });

    test('a challenge is met under the extension that asked', () async {
      build();
      await dio.get<String>(
        'https://www.example.com/',
        options: Options(extra: {ClearanceExtra.source: 'js:a'}),
      );
      expect(solver.checks['example.com']!.sources, {'js:a'});
    });

    test(
      'a challenge is solved and the request sent again with the clearance',
      () async {
        build();
        final response = await dio.get<String>(
          'https://www.example.com/search?q=a',
          options: Options(headers: {'User-Agent': 'Plugin/1'}),
        );
        expect(response.statusCode, 200);
        expect(response.data, 'results');
        final retry = site.requests.last;
        expect(retry.headers['Cookie'], contains('cf_clearance=good'));
        expect(retry.headers['User-Agent'], 'Engine/1.0');
        expect(pages.pages.single.loaded, 'https://www.example.com/search?q=a');
      },
    );

    test('a cleared site gets its cookies and agent with no solve', () async {
      store.recordSolve(
        'example.com',
        cookies: const [
          StoredCookie(
            name: 'cf_clearance',
            value: 'good',
            domain: '.example.com',
          ),
        ],
        agent: 'Engine/1.0',
        url: 'https://example.com/',
      );
      build();
      final response = await dio.get<String>(
        'https://api.example.com/x',
        options: Options(headers: {'Cookie': 'session=1; cf_clearance=old'}),
      );
      expect(response.data, 'results');
      expect(pages.opened, 0);
      final sent = site.requests.single.headers['Cookie'] as String;
      expect(sent, contains('session=1'));
      expect(sent, contains('cf_clearance=good'));
      expect(sent, isNot(contains('old')));
    });

    test('the plugin keeps its own agent when it asks to', () async {
      store.recordSolve(
        'example.com',
        cookies: const [
          StoredCookie(
            name: 'cf_clearance',
            value: 'good',
            domain: '.example.com',
          ),
        ],
        agent: 'Engine/1.0',
        url: 'https://example.com/',
      );
      site.needsAgent = false;
      build();
      await dio.get<String>(
        'https://example.com/x',
        options: Options(
          headers: {'User-Agent': 'Plugin/1', keepUserAgentHeader: '1'},
        ),
      );
      final sent = site.requests.single.headers;
      expect(sent['User-Agent'], 'Plugin/1');
      expect(sent.keys, isNot(contains(keepUserAgentHeader)));
    });

    test(
      'a site refusing a fresh clearance goes browser-only, through a page',
      () async {
        site.refusesClients = true;
        final inPage = FakePage(
          const [Step('Example')],
          onFetch: (r) async => InPageResponse(
            status: 200,
            url: Uri.parse(r.url),
            headers: const {'content-type': 'text/html'},
            body: 'from the page',
          ),
        );
        build(
          pageList: [
            FakePage(_clears(value: 'good')),
            inPage,
          ],
        );
        final response = await dio.get<String>('https://example.com/list');
        expect(response.data, 'from the page');
        expect(store['example.com']!.browserOnly, isTrue);
        // The next request goes straight to the page.
        final next = await dio.get<String>('https://example.com/other');
        expect(next.data, 'from the page');
        expect(inPage.fetched.map((r) => r.url), [
          'https://example.com/list',
          'https://example.com/other',
        ]);
      },
    );

    test('a site the browser sees no check on, that refuses clients, goes through the page', () async {
      site.refusesClients = true;
      final inPage = FakePage(
        const [Step('Example')],
        onFetch: (r) async => InPageResponse(
          status: 200,
          url: Uri.parse(r.url),
          headers: const {'content-type': 'text/html'},
          body: 'from the page',
        ),
      );
      build(
        pageList: [
          FakePage(const [Step('Example')]),
          inPage,
        ],
      );
      final response = await dio.get<String>('https://example.com/list');
      expect(response.data, 'from the page');
      final sent = site.requests.length;
      final next = await dio.get<String>('https://example.com/other');
      expect(next.data, 'from the page');
      expect(site.requests.length, sent, reason: 'straight to the page');
    });

    test(
      'a site whose page can\'t send its requests is left alone for a while',
      () async {
        site.refusesClients = true;
        final inPage = FakePage(
          const [Step('Example')],
          onFetch: (r) async =>
              throw const InPageFetchException('TypeError: Failed to fetch'),
        );
        build(
          pageList: [
            FakePage(const [Step('Example')]),
            inPage,
          ],
        );
        final options = Options(validateStatus: (_) => true);
        final first = await dio.get<String>(
          'https://example.com/a',
          options: options,
        );
        expect(first.statusCode, 403);
        final again = await dio.get<String>(
          'https://example.com/b',
          options: options,
        );
        expect(again.statusCode, 403);
        expect(pages.opened, 2, reason: 'no new solve, no page');
        expect(inPage.fetched, hasLength(1));
      },
    );

    test(
      'a site even its page can\'t get through is left alone for a while',
      () async {
        site.refusesClients = true;
        final inPage = FakePage(
          const [Step('Example')],
          onFetch: (r) async => InPageResponse(
            status: 403,
            url: Uri.parse(r.url),
            headers: const {'cf-mitigated': 'challenge'},
            body: '<title>Just a moment...</title>',
          ),
        );
        build(
          pageList: [
            FakePage(const [Step('Example')]),
            inPage,
          ],
        );
        final options = Options(validateStatus: (_) => true);
        final first = await dio.get<String>(
          'https://example.com/a',
          options: options,
        );
        expect(first.statusCode, 403);
        expect(pages.opened, 2);
        final again = await dio.get<String>(
          'https://example.com/b',
          options: options,
        );
        expect(again.statusCode, 403);
        expect(pages.opened, 2, reason: 'no new solve, no page');
        expect(inPage.fetched, hasLength(1));
      },
    );

    test('a retry that fails leaves the challenge readable', () async {
      site.failCleared = true;
      build();
      final response = await dio.get<ResponseBody>(
        'https://example.com/list',
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (_) => true,
        ),
      );
      expect(response.statusCode, 403);
      final body = await utf8.decodeStream(response.data!.stream);
      expect(body, contains('Just a moment'));
    });

    test(
      'a streamed Cloudflare 403 without cf-mitigated is read and kept',
      () async {
        site.sendMitigated = false;
        build();
        final response = await dio.get<ResponseBody>(
          'https://example.com/list',
          options: Options(responseType: ResponseType.stream),
        );
        final body = await utf8.decodeStream(response.data!.stream);
        expect(body, 'results');

        // A plain 403 of the site's own is passed on, body intact.
        final forbidden = await dio.get<ResponseBody>(
          'https://example.com/forbidden',
          options: Options(
            responseType: ResponseType.stream,
            validateStatus: (_) => true,
          ),
        );
        expect(forbidden.statusCode, 403);
        expect(await utf8.decodeStream(forbidden.data!.stream), 'not yours');
      },
    );

    test('a check that wants a person passes the challenge on', () async {
      build(
        pageList: [
          FakePage(const [Step.check()]),
        ],
      );
      final response = await dio.get<String>(
        'https://example.com/list',
        options: Options(validateStatus: (_) => true),
      );
      expect(response.statusCode, 403);
      expect(store['example.com']!.needsPerson, isTrue);
    });

    test('any request starts a solve, home rows\' too', () async {
      build();
      final response = await dio.get<String>('https://www.example.com/');
      expect(response.data, 'results');
      expect(pages.opened, 1);
    });

    test('a lapsed clearance is learned from and solved again', () async {
      var time = DateTime(2026, 10, 1, 12);
      store = ClearanceStore(clock: () => time);
      store.recordSolve(
        'example.com',
        cookies: const [
          StoredCookie(
            name: 'cf_clearance',
            value: 'lapsed',
            domain: '.example.com',
          ),
        ],
        agent: 'Engine/1.0',
        url: 'https://example.com/',
      );
      time = time.add(const Duration(minutes: 31));
      build();
      final response = await dio.get<String>('https://example.com/list');
      expect(response.data, 'results');
      expect(store['example.com']!.lifetime, const Duration(minutes: 30));
      expect(store['example.com']!.cookies.single.value, 'good');
    });
  });

  group('sendFromPage', () {
    FakePage origin(
      Future<InPageResponse> Function(InPageRequest request) answer,
    ) => FakePage(const [Step('Example')], onFetch: answer);

    test(
      'sends from a page on the origin, without the headers a page may not set',
      () async {
        final page = origin(
          (request) async => InPageResponse(
            status: 200,
            url: Uri.parse(request.url),
            headers: const {'content-type': 'text/html'},
            body: 'hello',
          ),
        );
        final solver = _solver(store, PageFactory([page]).call);
        final reply = await solver.sendFromPage(
          Uri.parse('https://example.com/a'),
          const InPageRequest(
            'https://example.com/a',
            headers: {
              'Accept': 'text/html',
              'Cookie': 'a=1',
              'User-Agent': 'X',
              'Referer': 'https://example.com/',
            },
          ),
        );
        expect(reply?.body, 'hello');
        expect(page.loaded, 'https://example.com/');
        expect(page.fetched.single.headers, {'Accept': 'text/html'});
        await solver.dispose();
      },
    );

    test(
      'a site that refuses its own page is held, and not asked again meanwhile',
      () async {
        var fetches = 0;
        final page = origin((request) async {
          fetches++;
          return InPageResponse(
            status: 403,
            url: Uri.parse(request.url),
            headers: const {'cf-mitigated': 'challenge'},
            body: '',
          );
        });
        final solver = _solver(store, PageFactory([page]).call);
        final url = Uri.parse('https://example.com/a');
        const request = InPageRequest('https://example.com/a');
        expect(await solver.sendFromPage(url, request), isNull);
        expect(solver.isIneffective('example.com'), isTrue);
        expect(await solver.sendFromPage(url, request), isNull);
        expect(fetches, 1);
        await solver.dispose();
      },
    );

    test('a page that can\'t send it holds the site too', () async {
      final page = origin(
        (_) async =>
            throw const InPageFetchException('TypeError: Failed to fetch'),
      );
      final solver = _solver(store, PageFactory([page]).call);
      expect(
        await solver.sendFromPage(
          Uri.parse('https://example.com/a'),
          const InPageRequest('https://example.com/a'),
        ),
        isNull,
      );
      expect(solver.isIneffective('example.com'), isTrue);
      await solver.dispose();
    });
  });
}

/// A site whose answers are 1 MB each: a JPEG at `/poster.jpg`, an HTML page
/// anywhere else.
class _Large implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final image = options.uri.path.endsWith('.jpg');
    return ResponseBody.fromBytes(
      Uint8List.fromList(List.filled(1024 * 1024, 0x61)),
      200,
      headers: {
        'content-type': [image ? 'image/jpeg' : 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// [bytes], telling [onRead] each index anything reads.
class _Counted extends ListBase<int> {
  _Counted(this.bytes, this.onRead);

  final List<int> bytes;
  final void Function(int index) onRead;

  @override
  int get length => bytes.length;

  @override
  set length(int value) => throw UnsupportedError('fixed');

  @override
  int operator [](int index) {
    onRead(index);
    return bytes[index];
  }

  @override
  void operator []=(int index, int value) => bytes[index] = value;
}

/// A site behind Cloudflare: a challenge unless the request carries
/// `cf_clearance=good` and the engine's agent.
/// Anubis in front of a site: a 200 check page until the request carries the
/// clearance the fake browser earns (`cf_clearance=good`).
class _AnubisSite implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final cookie = options.headers['Cookie']?.toString() ?? '';
    if (cookie.contains('cf_clearance=good')) {
      return ResponseBody.fromString('results', 200);
    }
    return ResponseBody.fromString(
      '<!doctype html><html><head><title>Making sure you&#39;re not a bot!'
      '</title><link rel="stylesheet" href="/.within.website/x/xess/xess.min.css">',
      200,
      headers: {
        'content-type': ['text/html; charset=utf-8'],
        'server': ['nginx'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _Site implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  bool sendMitigated = true;
  bool refusesClients = false;
  bool needsAgent = true;

  /// A request with the clearance fails on the way, with no response.
  bool failCleared = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.uri.path == '/forbidden') {
      return ResponseBody.fromString(
        'not yours',
        403,
        headers: {
          'server': ['cloudflare'],
        },
      );
    }
    final cookie = options.headers['Cookie']?.toString() ?? '';
    final agent = options.headers['User-Agent']?.toString() ?? '';
    final cleared =
        cookie.contains('cf_clearance=good') &&
        (!needsAgent || agent == 'Engine/1.0') &&
        !refusesClients;
    if (cleared && failCleared) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'reset',
      );
    }
    if (cleared) return ResponseBody.fromString('results', 200);
    return ResponseBody.fromString(
      '<html><title>Just a moment...</title><script>window._cf_chl_opt={}</script></html>',
      403,
      headers: {
        'server': ['cloudflare'],
        if (sendMitigated) 'cf-mitigated': ['challenge'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// `www.old.com` moved to `www.new.org`: a request to it comes back from the
/// new domain through [codes] (one 301 by default), the way Dio reports
/// redirects it followed. `www.new.org` is behind Cloudflare, as [_Site] is;
/// every other host answers. With [newDown], the new domain doesn't answer
/// and the old one serves; with [newTlsFails], its TLS handshake fails. With
/// [newerMove], `www.new.org` itself moved on to `www.newer.org`.
class _Moved implements HttpClientAdapter {
  _Moved({this.codes = const [301]});

  final List<int> codes;
  bool newDown = false;
  bool newTlsFails = false;
  bool newerMove = false;

  /// `www.new.org` sends visitors back to `www.old.com`: the site moved back.
  bool movedBack = false;

  /// `www.new.org` answers without a bot check.
  bool newOpen = false;

  /// `www.newer.org` is behind Cloudflare too.
  bool newerChecks = false;
  final List<Uri> requests = [];

  /// The `Cookie` header of each request, in order.
  final List<String> cookies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var uri = options.uri;
    requests.add(uri);
    final cookie = options.headers['Cookie']?.toString() ?? '';
    cookies.add(cookie);
    final redirects = <RedirectRecord>[];
    if (uri.host == 'www.old.com' && !newDown && !newTlsFails && !movedBack) {
      uri = uri.replace(host: 'www.new.org');
      redirects.addAll([
        for (final code in codes) RedirectRecord(code, 'GET', uri),
      ]);
    }
    if (uri.host == 'www.new.org' && newDown) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'gone',
      );
    }
    if (uri.host == 'www.new.org' && newTlsFails) {
      throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
    }
    if (uri.host == 'www.new.org' && newerMove) {
      uri = uri.replace(host: 'www.newer.org');
      redirects.add(RedirectRecord(301, 'GET', uri));
    }
    if (uri.host == 'www.new.org' && movedBack) {
      uri = uri.replace(host: 'www.old.com');
      redirects.add(RedirectRecord(301, 'GET', uri));
    }
    final checked =
        uri.host == 'www.new.org' && !newOpen ||
        uri.host == 'www.newer.org' && newerChecks;
    // As dart:io follows redirects: a cookie doesn't go on to another origin.
    final carried = uri.host == options.uri.host ? cookie : '';
    final body = !checked || carried.contains('cf_clearance=good')
        ? ResponseBody.fromString('results from ${uri.host}', 200)
        : ResponseBody.fromString(
            '<html><title>Just a moment...</title><script>window._cf_chl_opt={}</script></html>',
            403,
            headers: {
              'server': ['cloudflare'],
              'cf-mitigated': ['challenge'],
            },
          );
    return body..redirects = redirects;
  }

  @override
  void close({bool force = false}) {}
}
