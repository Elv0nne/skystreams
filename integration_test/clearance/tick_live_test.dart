/// Hidden solves of live bot checks through the app's solver, with its taps:
/// the tick spike's 24 Cloudflare sites, then one site of each other vendor
/// (AWS WAF, Anubis, HostAdmin, Vercel), one at a time, each from a fresh
/// start. Then `solveCaptcha` on three live Turnstile widget pages, with
/// nobody waiting.
///
/// ```
/// flutter test integration_test/clearance/tick_live_test.dart -d DEVICE \
///   --dart-define=TICK_E2E=true [--dart-define=SITES=URL,URL] \
///   [--dart-define=VENDORS=false] [--dart-define=CAPTCHAS=false] \
///   [--dart-define=PERSON_AFTER_S=20] [--dart-define=WORK_AFTER_S=60]
/// ```
///
/// PERSON_AFTER_S and WORK_AFTER_S lengthen the waits before a check is
/// handed to a person (the app's 20 s, and 60 s for checks that only
/// compute), to measure how long a slow check takes on a device.
///
/// Prints `TICK-SITE {json}` per site: how its solve ended, its taps, and
/// each widget box read where pages have an isolated world. `TICK-CAPTCHA
/// {json}` per widget page, and `TICK-END {json}`: the outcomes, the median
/// solve time, and how many Cloudflare sites ended needing a person.
///
/// It fails when a tapping platform leaves more than 2 of the 24 needing a
/// person, or when a box read is more than 8 px from where Android taps
/// blind ([fixedWidgetBox]), or faces the other way from the device's
/// language: a change in Cloudflare's layout shows up here before it reaches
/// Android.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/network/clearance/captcha_solver.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/network/clearance/widget_tap.dart';

import '../cloudstream/support.dart' show whilePumping;

const _live = bool.fromEnvironment('TICK_E2E');
const _vendors = bool.fromEnvironment('VENDORS', defaultValue: true);
const _captchas = bool.fromEnvironment('CAPTCHAS', defaultValue: true);
const _sitesDefine = String.fromEnvironment('SITES');
const _personAfter = int.fromEnvironment('PERSON_AFTER_S', defaultValue: 20);
const _workAfter = int.fromEnvironment('WORK_AFTER_S', defaultValue: 60);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the tick on live Cloudflare checks, and Turnstile tokens',
    skip: !_live,
    (tester) async {
      // A window on screen, drawing, as the app's always is: Linux's hidden
      // pages take taps only then.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('Ticks'))),
        ),
      );
      final keys = await SiteKeys.load();
      final capabilities = await ChallengeBrowser.capabilities();
      final rtl = widgetRtlIn(Platform.localeName);
      final urls = [
        if (_sitesDefine.isEmpty) ..._sites else ..._sitesDefine.split(','),
        if (_vendors && _sitesDefine.isEmpty) ..._vendorSites,
      ];
      print(
        'TICK-START ${jsonEncode({'platform': Platform.operatingSystem, 'sites': urls.length, 'canTap': capabilities.canTap, 'isolatedWorlds': capabilities.isolatedWorlds, 'rtl': rtl, 'locale': Platform.localeName})}',
      );

      // The browser's own cookie store keeps clearances across runs.
      final cleaner = await ChallengeBrowser.create();
      for (final url in [...urls, for (final w in _widgets) w.url]) {
        await cleaner.deleteCookies(url);
      }
      await cleaner.dispose();

      final watched = <_WatchedPage>[];
      final solver = ClearanceSolver(
        store: ClearanceStore(),
        siteKeys: keys,
        openPage: () async {
          final page = _WatchedPage(await BrowserCheckPage.open());
          watched.add(page);
          return page;
        },
        needsPersonAfter: const Duration(seconds: _personAfter),
        workAfter: const Duration(seconds: _workAfter),
        giveUpAfter: Duration(seconds: max(30, _personAfter + 10)),
      );
      // Taps, isolated reads and the device's language, as the app sets them.
      await Clearance.fitToBrowser(solver);

      final results = <Map<String, Object?>>[];
      for (final url in urls) {
        final opened = watched.length;
        final watch = Stopwatch()..start();
        final outcome = await whilePumping(
          tester,
          solver.solve(Uri.parse(url)),
        );
        final pages = watched.sublist(opened);
        final taps = [for (final p in pages) ...p.taps];
        final boxes = [for (final p in pages) ...p.boxes];
        final fixed = fixedWidgetBox(rtl: rtl);
        final out = <String, Object?>{
          'url': url,
          'outcome': outcome.result.name,
          'seconds': watch.elapsedMilliseconds / 1000,
          'taps': taps.length,
          'tapsAt': [for (final t in taps) t.at],
          'boxes': [
            for (final b in boxes)
              [b.left, b.top, b.width, b.height].map((v) => v.round()).toList(),
          ],
          if (boxes.isNotEmpty)
            'boxAtFixedPlace': boxes.every(
              (b) =>
                  (b.left - fixed.left).abs() <= 8 &&
                  (b.top - fixed.top).abs() <= 8 &&
                  (b.width - fixed.width).abs() <= 8 &&
                  (b.height - fixed.height).abs() <= 8 &&
                  b.rtl == rtl,
            ),
          if (_vendorSites.contains(url)) 'vendor': true,
          if (outcome.elsewhere != null) 'elsewhere': outcome.elsewhere,
        };
        results.add(out);
        print('TICK-SITE ${jsonEncode(out)}');
      }

      final tokens = <Map<String, Object?>>[];
      if (_captchas) {
        final captchas = CaptchaSolver(solver);
        for (final widget in _widgets) {
          final watch = Stopwatch()..start();
          final opened = watched.length;
          final out = <String, Object?>{'url': widget.url};
          try {
            final token = await whilePumping(
              tester,
              captchas.solve(
                siteKey: widget.siteKey,
                url: widget.url,
                personWaiting: false,
              ),
            );
            out['outcome'] = 'token';
            out['tokenLength'] = token.length;
          } on CaptchaException catch (e) {
            out['outcome'] = 'failed';
            out['reason'] = e.reason;
          }
          out['seconds'] = watch.elapsedMilliseconds / 1000;
          out['taps'] = [for (final p in watched.sublist(opened)) ...p.taps]
              .length;
          tokens.add(out);
          print('TICK-CAPTCHA ${jsonEncode(out)}');
        }
      }
      await solver.dispose();

      final cloudflare = [
        for (final r in results)
          if (r['vendor'] != true) r,
      ];
      final outcomes = <String, int>{};
      for (final r in cloudflare) {
        outcomes.update(
          r['outcome']! as String,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
      }
      final cleared = [
        for (final r in cloudflare)
          if (r['outcome'] == 'cleared') r['seconds']! as double,
      ]..sort();
      final boxesOff = results
          .where((r) => r['boxAtFixedPlace'] == false)
          .length;
      final needsPerson = outcomes['needsPerson'] ?? 0;
      print(
        'TICK-END ${jsonEncode({
          'platform': Platform.operatingSystem,
          'sites': cloudflare.length,
          'outcomes': outcomes,
          'vendors': {for (final r in results)
            if (r['vendor'] == true) r['url']: r['outcome']},
          'needsPerson': needsPerson,
          'medianClearSeconds': cleared.isEmpty ? null : cleared[cleared.length ~/ 2],
          'clearedAfterTaps': cloudflare.where((r) => r['outcome'] == 'cleared' && (r['taps']! as int) > 0).length,
          'boxesOffFixedPlace': boxesOff,
          'tokens': tokens.where((t) => t['outcome'] == 'token').length,
          'widgetPages': tokens.length,
        })}',
      );
      expect(
        boxesOff,
        0,
        reason:
            "each widget box read is where Android taps blind, facing the "
            "device's way",
      );
      if (capabilities.canTap && _sitesDefine.isEmpty) {
        expect(
          needsPerson,
          lessThanOrEqualTo(2),
          reason: 'a tapping platform ends at most 2 of 24 needing a person',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 40)),
  );
}

/// A solver's page, with the taps it was sent and the widget boxes read.
class _WatchedPage implements CheckPage {
  _WatchedPage(this._page);

  final CheckPage _page;
  final DateTime _opened = DateTime.now();
  final List<({double x, double y, double at})> taps = [];
  final List<WidgetBox> boxes = [];

  @override
  ChallengeBrowser? get browser => _page.browser;

  @override
  Future<void> load(String url, {Map<String, String> headers = const {}}) =>
      _page.load(url, headers: headers);

  @override
  Stream<BrowserEvent> get events => _page.events;

  @override
  Future<void> setCapture(bool enabled) => _page.setCapture(enabled);

  @override
  Future<String> evaluate(String script) => _page.evaluate(script);

  @override
  Future<void> tap(double x, double y) {
    taps.add((
      x: x,
      y: y,
      at: DateTime.now().difference(_opened).inMilliseconds / 1000,
    ));
    return _page.tap(x, y);
  }

  @override
  Future<void> deleteCookies(String url, {String? name}) =>
      _page.deleteCookies(url, name: name);

  @override
  Future<WidgetBox?> widgetBox() async {
    final box = await _page.widgetBox();
    if (box != null) boxes.add(box);
    return box;
  }

  @override
  Future<PageGlance?> glance() => _page.glance();

  @override
  Future<List<StoredCookie>> cookies(String url) => _page.cookies(url);

  @override
  Future<String> userAgent() => _page.userAgent();

  @override
  Future<InPageResponse> fetch(InPageRequest request) => _page.fetch(request);

  @override
  Future<void> dispose() => _page.dispose();
}

/// The tick spike's sites behind Cloudflare's interstitial (2026-10-04):
/// extension hosts, then public sites.
const _sites = [
  'https://vcloud.fit/',
  'https://cinemacity.cc/',
  'https://french-anime.com/',
  'https://onlykdrama.shop/',
  'https://jkanime.net/',
  'https://api.viduki.net/',
  'https://www.scrapingcourse.com/cloudflare-challenge',
  'https://desenefaine.com/',
  'https://anime-phoenix.com/',
  'https://anime3rb.com/',
  'https://api.allanime.day/',
  'https://cinehdplus.org/',
  'https://cizgimax.online/',
  'https://extto.com/',
  'https://invidious.perennialte.ch/',
  'https://movielinkbd.shop/',
  'https://movielinkbd.work/',
  'https://p.111477.xyz/',
  'https://w30.shahidwbas.tv/',
  'https://www.adkami.com/',
  'https://gat.animerco.org/',
  'https://w1.anime4up.rest/',
  'https://nopecha.com/demo/cloudflare',
  'https://gitlab.com/users/sign_in',
];

/// Other vendors' checks: AWS WAF (IMDb), Anubis, HostAdmin and Vercel.
const _vendorSites = [
  'https://www.imdb.com/',
  'https://invidious.f5.si/',
  'https://kinoger.com/',
  'https://mal-stremio.vercel.app/',
];

/// Turnstile widgets on ordinary pages, with their keys: Cloudflare's test
/// keys, one that passes by itself and one that asks for the checkbox.
const _widgets = [
  (
    url: 'https://demo.turnstile.workers.dev/',
    siteKey: '1x00000000000000000000AA',
  ),
  (
    url: 'https://seleniumbase.io/apps/turnstile',
    siteKey: '3x00000000000000000000FF',
  ),
  (
    url: 'https://2captcha.com/demo/cloudflare-turnstile',
    siteKey: '3x00000000000000000000FF',
  ),
];
