import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/captcha_solver.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/network/clearance/widget_tap.dart';

import 'fakes.dart';

final _keys = SiteKeys.parse(
  File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
);

const _turnstileKey = '0x4AAAAAAAkB2nGLjpB0hLFZ';
const _hcaptchaKey = '10000000-ffff-ffff-ffff-000000000001';
const _recaptchaKey = '6LeIxAcTAAAAAJcZVRqyHh71UMIEGNQ_MXjiZKhI';
const _url = 'https://www.example.com/download';
const _source = 'js:com_a__sub1';

/// A page with a captcha widget: [token] answers its response field, and
/// [render] what rendering one for a key ended in. [widget] is where its
/// widget is, read in an isolated world or, with [readInPage], by a script
/// in the page itself.
FakePage _page({
  required String? Function(FakePage page) token,
  String render = 'rendered',
  bool hasWidget = true,
  WidgetBox? widget = const WidgetBox(10, 10, 300, 65),
  WidgetBox? readInPage,
}) {
  late FakePage page;
  page = FakePage(
    const [Step('Downloads')],
    widget: widget,
    onEvaluate: (script) async {
      if (script == widgetBoxScript) {
        final box = readInPage;
        return box == null
            ? 'null'
            : jsonEncode([
                box.left,
                box.top,
                box.width,
                box.height,
                false,
                false,
              ]);
      }
      if (script.contains('__skyCaptcha')) return jsonEncode(render);
      if (script.contains('querySelector(') && script.contains('!!')) {
        return jsonEncode(hasWidget);
      }
      if (script.contains('-response')) return jsonEncode(token(page));
      return 'null';
    },
  );
  return page;
}

/// A sheet that waits for the token, as a person solving it would; [sites]
/// collects the sites it showed.
CheckPresenter _person(List<String> sites) =>
    ({required page, required site, required cleared}) async {
      sites.add(site);
      await cleared;
      return ChallengeSheetResult.verified;
    };

void main() {
  late ClearanceStore store;

  setUp(() => store = ClearanceStore());

  ClearanceSolver solverFor(
    List<FakePage> pages, {
    bool canTap = true,
    bool isolatedWorlds = true,
  }) => ClearanceSolver(
    store: store,
    siteKeys: _keys,
    openPage: PageFactory(pages).call,
    pollEvery: const Duration(milliseconds: 2),
    tapEvery: const Duration(milliseconds: 20),
    canTap: canTap,
    isolatedWorlds: isolatedWorlds,
  );

  CaptchaSolver captchas(ClearanceSolver solver) => CaptchaSolver(
    solver,
    tokenWait: const Duration(milliseconds: 20),
    giveUpAfter: const Duration(milliseconds: 300),
    pollEvery: const Duration(milliseconds: 2),
  );

  group('captchaKindOf', () {
    test('tells the three apart by their keys', () {
      expect(captchaKindOf(_turnstileKey), CaptchaKind.turnstile);
      // Cloudflare's test keys, which demo pages use.
      expect(captchaKindOf('1x00000000000000000000AA'), CaptchaKind.turnstile);
      expect(captchaKindOf('3x00000000000000000000FF'), CaptchaKind.turnstile);
      expect(captchaKindOf(_hcaptchaKey), CaptchaKind.hcaptcha);
      expect(captchaKindOf(_recaptchaKey), CaptchaKind.recaptcha);
      expect(captchaKindOf('6Labc'), isNull);
      expect(captchaKindOf('abc'), isNull);
      expect(captchaKindOf(''), isNull);
    });
  });

  group('Turnstile', () {
    test('a token that comes by itself is returned, with no tap', () async {
      final page = _page(token: (_) => 'tok');
      final token = await captchas(solverFor([page]))
          .solve(siteKey: _turnstileKey, url: _url, personWaiting: false);
      expect(token, 'tok');
      expect(page.taps, isEmpty);
      expect(page.loaded, _url);
      expect(page.disposed, isTrue);
    });

    test('a widget that waits gets tapped, and its token returned', () async {
      final page = _page(token: (p) => p.taps.isEmpty ? '' : 'tapped');
      final token = await captchas(solverFor([page]))
          .solve(siteKey: _turnstileKey, url: _url, personWaiting: false);
      expect(token, 'tapped');
      expect([for (final t in page.taps) (t.x, t.y)], [(35.0, 42.5)]);
    });

    test('no token after three taps, and nobody waiting: it fails, and the '
        'site needs a check', () async {
      final page = _page(token: (_) => '');
      final solver = solverFor([page]);
      await expectLater(
        captchas(solver).solve(
          siteKey: _turnstileKey,
          url: _url,
          personWaiting: false,
          source: _source,
        ),
        throwsA(isA<CaptchaException>()),
      );
      expect(page.taps, hasLength(3));
      expect(page.disposed, isTrue);
      expect(solver.checks['example.com']!.state, CheckState.needsYou);
      expect(solver.checks['example.com']!.sources, {_source});
    });

    test('where nothing can tap (iOS), it waits for the token by itself, '
        'then fails', () async {
      final page = _page(token: (_) => '');
      await expectLater(
        captchas(solverFor([page], canTap: false))
            .solve(siteKey: _turnstileKey, url: _url, personWaiting: false),
        throwsA(isA<CaptchaException>()),
      );
      expect(page.taps, isEmpty);
    });

    test('without an isolated world (Android), the widget is found by a '
        'script in the page', () async {
      final page = _page(
        token: (p) => p.taps.isEmpty ? '' : 'tapped',
        widget: null,
        readInPage: const WidgetBox(20, 30, 300, 65),
      );
      final token = await captchas(solverFor([page], isolatedWorlds: false))
          .solve(siteKey: _turnstileKey, url: _url, personWaiting: false);
      expect(token, 'tapped');
      expect([for (final t in page.taps) (t.x, t.y)], [(45.0, 62.5)]);
      expect(page.widgetAsked, isEmpty);
    });

    test('a page without the widget gets one rendered for the key', () async {
      final page = _page(token: (_) => 'tok', hasWidget: false);
      await captchas(solverFor([page]))
          .solve(siteKey: _turnstileKey, url: _url, personWaiting: false);
      expect(
        page.evaluated.where((s) => s.contains('turnstile/v0/api.js')),
        isNotEmpty,
      );
      expect(
        page.evaluated.where((s) => s.contains(_turnstileKey)),
        isNotEmpty,
      );
    });

    test('with a person waiting where nothing can tap, the sheet shows the '
        'widget and their token is returned', () async {
      final sites = <String>[];
      final page = _page(token: (_) => sites.isEmpty ? '' : 'solved');
      final solver = solverFor([page], canTap: false)
        ..presenter = _person(sites);
      final token = await captchas(solver)
          .solve(siteKey: _turnstileKey, url: _url, personWaiting: true);
      expect(token, 'solved');
      expect(sites, ['example.com']);
      expect(page.taps, isEmpty);
    });

    test('with a person waiting, the sheet comes once the taps are done, '
        'long before the browser would give up', () async {
      final sites = <String>[];
      final page = _page(token: (_) => sites.isEmpty ? '' : 'solved');
      final solver = solverFor([page])..presenter = _person(sites);
      final token =
          await CaptchaSolver(
                solver,
                tokenWait: const Duration(milliseconds: 20),
                pollEvery: const Duration(milliseconds: 2),
              )
              .solve(siteKey: _turnstileKey, url: _url, personWaiting: true)
              .timeout(const Duration(seconds: 5));
      expect(token, 'solved');
    });

    test('with a person waiting, three taps come first, then the '
        'sheet', () async {
      final sites = <String>[];
      final page = _page(token: (_) => sites.isEmpty ? '' : 'solved');
      final solver = solverFor([page])..presenter = _person(sites);
      final token = await captchas(solver)
          .solve(siteKey: _turnstileKey, url: _url, personWaiting: true);
      expect(token, 'solved');
      expect(page.taps, hasLength(3));
      expect(sites, ['example.com']);
    });
  });

  group('hCaptcha and reCAPTCHA', () {
    test('without a person waiting, it fails and the site needs a '
        'check', () async {
      final pages = PageFactory([_page(token: (_) => 'tok')]);
      final solver = ClearanceSolver(
        store: store,
        siteKeys: _keys,
        openPage: pages.call,
      );
      await expectLater(
        captchas(solver).solve(
          siteKey: _hcaptchaKey,
          url: _url,
          personWaiting: false,
          source: _source,
        ),
        throwsA(isA<CaptchaException>()),
      );
      expect(pages.opened, 0);
      expect(solver.checks['example.com']!.state, CheckState.needsYou);
      expect(solver.checks['example.com']!.sources, {_source});
      expect(store['example.com']!.checkUrl, _url);
    });

    test('with a person waiting, the sheet shows it and the token they earn '
        'is returned', () async {
      final sites = <String>[];
      final page = _page(token: (_) => sites.isEmpty ? '' : 'solved');
      final solver = solverFor([page])..presenter = _person(sites);
      final token = await captchas(solver)
          .solve(siteKey: _recaptchaKey, url: _url, personWaiting: true);
      expect(token, 'solved');
      expect(sites, ['example.com']);
      expect(page.taps, isEmpty, reason: 'only Turnstile is tapped');
      expect(page.disposed, isTrue);
    });

    test('a sheet closed with no token fails', () async {
      final page = _page(token: (_) => '');
      final solver = solverFor([page])
        ..presenter = ({
          required page,
          required site,
          required cleared,
        }) async => ChallengeSheetResult.closed;
      await expectLater(
        captchas(solver)
            .solve(siteKey: _hcaptchaKey, url: _url, personWaiting: true),
        throwsA(isA<CaptchaException>()),
      );
    });

    test("don't ask again in its sheet fails, and quiets the site", () async {
      final page = _page(token: (_) => '');
      final solver = solverFor([page])
        ..presenter = ({
          required page,
          required site,
          required cleared,
        }) async => ChallengeSheetResult.quiet;
      await expectLater(
        captchas(solver)
            .solve(siteKey: _hcaptchaKey, url: _url, personWaiting: true),
        throwsA(isA<CaptchaException>()),
      );
      expect(store.isQuiet('example.com'), isTrue);
    });

    test('a quiet site is not asked, as if nobody were waiting', () async {
      final pages = PageFactory([_page(token: (_) => 'tok')]);
      final sites = <String>[];
      final solver = ClearanceSolver(
        store: store,
        siteKeys: _keys,
        openPage: pages.call,
      )..presenter = _person(sites);
      store.setQuiet('example.com', true);
      await expectLater(
        captchas(solver)
            .solve(siteKey: _hcaptchaKey, url: _url, personWaiting: true),
        throwsA(isA<CaptchaException>()),
      );
      expect(pages.opened, 0);
      expect(sites, isEmpty);
      expect(solver.checks['example.com']!.state, CheckState.needsYou);
    });

    test('a key that renders no widget (reCAPTCHA v3) fails at once', () async {
      final sites = <String>[];
      final page = _page(token: (_) => '', hasWidget: false, render: 'failed');
      final solver = solverFor([page])..presenter = _person(sites);
      await expectLater(
        captchas(solver)
            .solve(siteKey: _recaptchaKey, url: _url, personWaiting: true),
        throwsA(isA<CaptchaException>()),
      );
      expect(sites, isEmpty);
      expect(page.disposed, isTrue);
    });

    test('its sheet waits for one already showing', () async {
      final sites = <String>[];
      final verifyLeft = Completer<ChallengeSheetResult>();
      final captchaPage = _page(token: (_) => sites.length > 1 ? 'solved' : '');
      final solver =
          solverFor([
              FakePage(const [Step.check()]),
              captchaPage,
            ])
            ..presenter =
                ({required page, required site, required cleared}) async {
                  sites.add(site);
                  if (site == 'other.com') return verifyLeft.future;
                  await cleared;
                  return ChallengeSheetResult.verified;
                };
      final verified = solver.verify('other.com');
      await pumpEventQueue();
      final token = captchas(solver)
          .solve(siteKey: _hcaptchaKey, url: _url, personWaiting: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sites, ['other.com']);
      verifyLeft.complete(ChallengeSheetResult.closed);
      expect(await token, 'solved');
      expect(sites, ['other.com', 'example.com']);
      await verified;
    });
  });

  test('an unknown key, or no page to solve it on, fails at once', () async {
    final pages = PageFactory([_page(token: (_) => 'tok')]);
    final solver = ClearanceSolver(
      store: store,
      siteKeys: _keys,
      openPage: pages.call,
    );
    await expectLater(
      captchas(solver).solve(siteKey: 'abc', url: _url, personWaiting: true),
      throwsA(isA<CaptchaException>()),
    );
    await expectLater(
      captchas(solver)
          .solve(siteKey: _turnstileKey, url: '', personWaiting: true),
      throwsA(isA<CaptchaException>()),
    );
    expect(pages.opened, 0);
  });
}
