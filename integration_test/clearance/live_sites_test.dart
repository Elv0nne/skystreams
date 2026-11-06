/// Bot checks on live sites, through SkyStream's own clearance layer: the
/// app's shared Dio with its clearance interceptor, requests sent the way JS
/// extensions send them, and the solver's hidden pages.
///
/// ```
/// flutter test integration_test/clearance/live_sites_test.dart -d DEVICE \
///   --dart-define=CLEARANCE_E2E=true [--dart-define=SITES=URL,URL] \
///   [--dart-define=AT_ONCE=30]
/// ```
///
/// Three rounds over the sites, each sending AT_ONCE requests at a time, as a
/// big search's plugins do:
/// 1. **first:** an empty store, and the browser's cookies for the sites
///    deleted. Checks are solved in hidden pages, a few at a time.
/// 2. **again:** within the clearances' lifetime: the site's cookies go out,
///    and nothing is solved or opened unless the site refuses them.
/// 3. **restart:** a new store reads the file back, with a new solver and
///    client: still no solve. Browser-only sites open a page to send from.
///
/// Prints `CLR-SITE {json}` per site and round, `CLR-ROUND {json}` per round,
/// `CLR-CHECK` lines for what broke the rules above, and `CLR-NOTE` lines for
/// sites that refused their own clearance early.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart';
import 'package:skystream/core/network/clearance/challenge_triage.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_interceptor.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/network/clearance/widget_tap.dart';
import 'package:skystream/core/network/dio_client_provider.dart';
import 'package:skystream/core/providers/device_info_provider.dart';

import '../cloudstream/support.dart' show whilePumping;

const _live = bool.fromEnvironment('CLEARANCE_E2E');
const _sitesDefine = String.fromEnvironment('SITES');

/// Requests in flight at once: a big search's worth. All 114 at once swamps
/// a 2 GB device with connections and bodies before any check is met.
const _atOnce = int.fromEnvironment('AT_ONCE', defaultValue: 30);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'bot checks on live sites, through the clearance layer',
    skip: !_live,
    (tester) async {
      // A window on screen, drawing, as the app's always is: Linux's hidden
      // pages take taps only then.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('Checks'))),
        ),
      );
      final keys = await SiteKeys.load();
      final urls = _sitesDefine.isEmpty
          ? [..._checked, ..._blocked]
          : _sitesDefine.split(',');
      final file = File(
        '${(await Directory.systemTemp.createTemp('clearance')).path}'
        '/clearances.json',
      );
      print('CLR-START ${urls.length} sites, ${Platform.operatingSystem}');

      // The browser's own cookie store keeps clearances across runs.
      final cleaner = await ChallengeBrowser.create();
      for (final url in urls) {
        await cleaner.deleteCookies(url);
      }
      await cleaner.dispose();

      final rounds = <String, List<Map<String, Object?>>>{};
      var layer = await _Layer.open(keys, file);
      rounds['first'] = await whilePumping(
        tester,
        _round('first', layer, urls),
      );
      rounds['again'] = await whilePumping(
        tester,
        _round('again', layer, urls),
      );
      await layer.close();

      layer = await _Layer.open(keys, file);
      print(
        'CLR-STORE read back ${layer.store.all.length} sites, '
        '${file.lengthSync()} bytes',
      );
      rounds['restart'] = await whilePumping(
        tester,
        _round('restart', layer, urls),
      );
      await layer.close();

      _check(rounds);
    },
    timeout: const Timeout(Duration(minutes: 60)),
  );
}

/// The clearance layer as the app builds it: a store on a file, a solver
/// whose pages are counted per site, and the app's shared Dio.
class _Layer {
  _Layer._(
    this.keys,
    this.store,
    this.solver,
    this.pages,
    this.loadedAt,
    this.container,
    this.dio,
  );

  static Future<_Layer> open(SiteKeys keys, File file) async {
    final store = ClearanceStore(file: file);
    await store.load();
    final pages = <String, int>{};
    final loadedAt = <String, DateTime>{};
    final solver = ClearanceSolver(
      store: store,
      siteKeys: keys,
      openPage: () async => _CountedPage(await BrowserCheckPage.open(), (url) {
        final site = keys.siteOf(Uri.parse(url).host);
        pages.update(site, (n) => n + 1, ifAbsent: () => 1);
        // The first page is the solve's; a later one is a browser-only site's.
        loadedAt.putIfAbsent(site, DateTime.now);
      }),
    );
    // Taps, isolated reads and the device's language, as the app sets them.
    await Clearance.fitToBrowser(solver);
    Clearance.instance.debugUse(store: store, siteKeys: keys, solver: solver);
    final container = ProviderContainer();
    // Sized for the device, as the app's ClearanceBridge does.
    Clearance.instance.fitTo(
      await container.read(deviceProfileProvider.future),
    );
    final dio = container.read(dioClientProvider);
    final layer = _Layer._(
      keys,
      store,
      solver,
      pages,
      loadedAt,
      container,
      dio,
    );
    // First, so it sees each response before the clearance interceptor does.
    dio.interceptors.insert(0, layer.raw);
    return layer;
  }

  final SiteKeys keys;
  final ClearanceStore store;
  final ClearanceSolver solver;

  /// Pages each site's solves and sends opened.
  final Map<String, int> pages;

  /// When each site's first page started loading: a solve's own time,
  /// without its wait for a free page.
  final Map<String, DateTime> loadedAt;
  final ProviderContainer container;
  final Dio dio;
  final _RawResponses raw = _RawResponses();

  Future<void> close() async {
    await store.flush();
    await solver.dispose();
    // Its idle connections would stay open for minutes beside the next
    // layer's.
    dio.close(force: true);
    container.dispose();
  }
}

/// Every response as the server sent it, before the clearance layer.
class _RawResponses extends Interceptor {
  final Map<String, List<String>> seen = {};

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler h) {
    _note(response);
    h.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler h) {
    if (err.response case final response?) _note(response);
    h.next(err);
  }

  static bool _sentCookies(RequestOptions options) => options.headers.entries
      .any((e) => e.key.toLowerCase() == 'cookie' && '${e.value}'.isNotEmpty);

  void _note(Response<dynamic> response) {
    final options = response.requestOptions;
    final key = options.extra['test.url'] as String? ?? '${options.uri}';
    final mitigated = response.headers.value('cf-mitigated');
    final server = response.headers.value('server') ?? '';
    seen
        .putIfAbsent(key, () => [])
        .add(
          [
            '${response.statusCode}',
            if (mitigated != null) 'cf-$mitigated',
            if (server.isNotEmpty) server,
            if (options.extra[ClearanceExtra.retried] == true) 'retried',
            // The clearance interceptor adds the site's cookies to these
            // same options before sending.
            if (_sentCookies(options)) 'sent-cookies',
          ].join(' '),
        );
  }
}

/// Counts the sites a solver's pages load.
class _CountedPage implements CheckPage {
  _CountedPage(this._page, this._loaded);

  final CheckPage _page;
  final void Function(String url) _loaded;

  @override
  ChallengeBrowser? get browser => _page.browser;

  @override
  Future<void> load(String url, {Map<String, String> headers = const {}}) {
    _loaded(url);
    return _page.load(url, headers: headers);
  }

  @override
  Stream<BrowserEvent> get events => _page.events;

  @override
  Future<void> setCapture(bool enabled) => _page.setCapture(enabled);

  @override
  Future<String> evaluate(String script) => _page.evaluate(script);

  @override
  Future<void> tap(double x, double y) => _page.tap(x, y);

  @override
  Future<void> deleteCookies(String url, {String? name}) =>
      _page.deleteCookies(url, name: name);

  @override
  Future<WidgetBox?> widgetBox() => _page.widgetBox();

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

Future<List<Map<String, Object?>>> _round(
  String name,
  _Layer layer,
  List<String> urls,
) async {
  final started = DateTime.now();
  layer.raw.seen.clear();
  var mostActive = 0;
  final sampler = Timer.periodic(const Duration(milliseconds: 200), (_) {
    mostActive = max(mostActive, layer.solver.activeSolves);
  });
  final results = List<Map<String, Object?>?>.filled(urls.length, null);
  var next = 0;
  await Future.wait([
    for (var lane = 0; lane < min(_atOnce, urls.length); lane++)
      () async {
        while (next < urls.length) {
          final i = next++;
          results[i] = await _visit(name, layer, urls[i]);
        }
      }(),
  ]);
  sampler.cancel();
  final done = results.cast<Map<String, Object?>>();
  final outcomes = <String, int>{};
  for (final r in done) {
    outcomes.update(r['outcome']! as String, (n) => n + 1, ifAbsent: () => 1);
  }
  print(
    'CLR-ROUND ${jsonEncode({'round': name, 'seconds': DateTime.now().difference(started).inMilliseconds / 1000, 'sites': urls.length, 'outcomes': outcomes, 'solves': done.where((r) => r['solved'] == true).length, 'pages': layer.pages.values.fold<int>(0, (a, b) => a + b), 'mostSolvesAtOnce': mostActive, 'parallelLimit': layer.solver.parallel})}',
  );
  return done;
}

/// One request to [url], as a JS extension's search sends it.
Future<Map<String, Object?>> _visit(
  String round,
  _Layer layer,
  String url,
) async {
  final site = layer.keys.siteOf(Uri.parse(url).host);
  final before = layer.store[site];
  final pagesBefore = layer.pages[site] ?? 0;
  final watch = Stopwatch()..start();
  final out = <String, Object?>{'round': round, 'url': url, 'site': site};
  Triage? left;
  try {
    final response = await fetchCappedPlainBody(
      layer.dio,
      url,
      options: Options(
        method: 'GET',
        headers: {
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        },
        validateStatus: (_) => true,
        followRedirects: true,
        sendTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        extra: {ClearanceExtra.personWaiting: false, 'test.url': url},
      ),
    );
    final status = response.statusCode;
    left = triageHeaders(status, response.headers.value);
    if (left == Triage.unsure || left == Triage.none && status >= 400) {
      left = triageBody(response.body);
    }
    out['status'] = status;
    out['left'] = left.name;
    out['title'] = _title(response.body);
    out['bytes'] = response.body.length;
  } catch (e) {
    final text = '$e'.replaceAll('\n', ' ');
    out['error'] = text.length > 140 ? text.substring(0, 140) : text;
  }
  final entry = layer.store[site];
  final solved = entry?.solvedAt != null && entry!.solvedAt != before?.solvedAt;
  final raw = layer.raw.seen[url] ?? const [];
  final challenged =
      raw.any((r) => r.contains('cf-challenge')) ||
      raw.isNotEmpty &&
          raw.first.contains('ddos-guard') &&
          (raw.first.startsWith('403') || raw.first.startsWith('503'));
  out.addAll({
    'raw': raw,
    'solved': solved,
    if (solved && layer.loadedAt[site] != null)
      'solveSeconds':
          entry.solvedAt!.difference(layer.loadedAt[site]!).inMilliseconds /
          1000,
    'pages': (layer.pages[site] ?? 0) - pagesBefore,
    'clearance': entry?.hasClearance ?? false,
    'cookies': [
      for (final c in entry?.cookies ?? const <StoredCookie>[]) c.name,
    ],
    'browserOnly': entry?.browserOnly ?? false,
    'needsPerson': entry?.needsPerson ?? false,
    'seconds': watch.elapsedMilliseconds / 1000,
  });
  out['outcome'] = switch (left) {
    null => 'error',
    _ when entry?.needsPerson ?? false => 'needs-person',
    Triage.challenge => 'still-challenged',
    Triage.block => 'blocked',
    _ when entry?.browserOnly ?? false => 'browser-only',
    _ when solved => 'cleared',
    _ when entry?.hasClearance ?? false => 'with-clearance',
    _ when challenged => 'challenge-passed',
    _ => 'no-check',
  };
  print('CLR-SITE ${jsonEncode(out)}');
  return out;
}

String _title(String body) {
  final match = RegExp(
    r'<title[^>]*>([^<]*)</title>',
    caseSensitive: false,
  ).firstMatch(body);
  final title = (match?.group(1) ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
  return title.length > 70 ? title.substring(0, 70) : title;
}

/// The rules the rounds must keep, printed for each site that broke one.
void _check(Map<String, List<Map<String, Object?>>> rounds) {
  final first = {for (final r in rounds['first']!) r['url']: r};
  var broken = 0;
  void broke(String rule, Map<String, Object?> r) {
    broken++;
    print('CLR-CHECK ${r['round']} $rule: ${r['url']} ${jsonEncode(r)}');
  }

  for (final r in rounds['first']!) {
    if (r['outcome'] == 'blocked' && (r['pages']! as int) > 0) {
      broke('a block page opened a page', r);
    }
  }
  var revoked = 0;
  for (final round in ['again', 'restart']) {
    for (final r in rounds[round]!) {
      final was = first[r['url']]!;
      final cleared = {'cleared', 'with-clearance'}.contains(was['outcome']);
      if (!cleared) continue;
      final raw = (r['raw']! as List).cast<String>();
      if (raw.isEmpty) continue; // No answer at all (a timeout).
      if (!raw.first.contains('sent-cookies')) {
        broke('sent without its clearance', r);
        continue;
      }
      if (raw.first.contains('cf-challenge')) {
        // The site refused its own clearance before its lifetime was up:
        // the solve or the page that follow are the layer's answer to that.
        revoked++;
        print('CLR-NOTE ${r['round']} site refused its clearance: ${r['url']}');
        continue;
      }
      if (r['solved'] == true) broke('solved with no challenge', r);
      final pageExpected = r['outcome'] == 'browser-only';
      if ((r['pages']! as int) > 0 && !pageExpected) {
        broke('opened a page', r);
      }
    }
  }
  print('CLR-END $broken broken, $revoked refused their clearance early');
}

/// Sites that answered a plain client with a bot check: hosts of CloudStream
/// and JS extensions (the MegaRepo survey, 2026-10-01), then public sites.
const _checked = [
  // Cloudflare's challenge, extension hosts.
  'https://1azayf9w.xyz/',
  'https://1jour1film.shop/',
  'https://1jour1film0426c.site/',
  'https://abysscdn.com/',
  'https://anime-phoenix.com/',
  'https://anime3rb.com/',
  'https://animepahe.com/',
  'https://animepahe.org/',
  'https://animepahe.pw/',
  'https://api.allanime.day/',
  'https://buzzheavier.com/',
  'https://cinehdplus.org/',
  'https://cinemacity.cc/',
  'https://d0000d.com/',
  'https://d000d.com/',
  'https://d0o0d.com/',
  'https://data.simkl.in/',
  'https://dn4z5b.movielinkbd.li/',
  'https://do7go.com/',
  'https://dood.la/',
  'https://dood.li/',
  'https://dood.re/',
  'https://dood.wf/',
  'https://doods.pro/',
  'https://dooodster.com/',
  'https://doply.net/',
  'https://dorabash.in/',
  'https://dotplay.net/',
  'https://ds2play.com/',
  'https://ext.to/',
  'https://extranet.torrentbay.st/',
  'https://extto.com/',
  'https://exxample.com/',
  'https://flemmix.cafe/',
  'https://flexy.stream/',
  'https://french-anime.com/',
  'https://funmovieslix.com/',
  'https://gat.animerco.org/',
  'https://gudangvape.com/',
  'https://jkanime.net/',
  'https://kinoger.com/',
  'https://kuramadrive.com/',
  'https://masstamilan.dev/',
  'https://mlsbd.co/',
  'https://moflix-stream.xyz/',
  'https://movielinkbd.shop/',
  'https://movielinkbd.tv/',
  'https://movielinkbd.work/',
  'https://myvidplay.com/',
  'https://net52.cc/',
  'https://playmogo.com/',
  'https://qiwi.gg/',
  'https://r.cimalight.co/',
  'https://rumble.com/',
  'https://savefiles.com/',
  'https://vcloud.fit/',
  'https://vide0.net/',
  'https://vidtube.one/',
  'https://w1.anime4up.rest/',
  'https://w30.shahidwbas.tv/',
  'https://web31018x.faselhdx.bid/',
  'https://web31312x.faselhdx.bid/',
  'https://wecima.ac/',
  'https://witanime.you/',
  'https://www.documaniatv.com/',
  'https://www.skillshare.com/',
  'https://www.tamildhool.tech/',
  'https://www.watch-movies.com.pk/',
  'https://www.wcoflix.tv/',
  'https://www.wcoforever.net/',
  'https://yip.su/',
  'https://zw73hk.movielinkbd.li/',
  // DDoS-Guard, extension hosts.
  'https://aniworld.to/',
  'https://doodstream.com/',
  'https://filmo.to/',
  'https://goofy-banana.com/',
  'https://kinoger.ru/',
  'https://monstro.online/',
  'https://player.videasy.to/',
  'https://serienstream.to/',
  'https://streamed.pk/',
  'https://voe.sx/',
  'https://waaw.to/',
  'https://ww3.gnulahd.nu/',
  // Public sites behind Cloudflare's challenge.
  'https://www.scrapingcourse.com/cloudflare-challenge',
  'https://nopecha.com/demo/cloudflare',
  'https://gitlab.com/users/sign_in',
  'https://www.indeed.com/',
  'https://chatgpt.com/',
  'https://www.crunchyroll.com/',
  'https://www.patreon.com/login',
  'https://www.g2.com/',
  // Turnstile in a page: no interstitial, so nothing for the layer to do.
  'https://demo.turnstile.workers.dev/',
  'https://seleniumbase.io/apps/turnstile',
  'https://2captcha.com/demo/cloudflare-turnstile',
  'https://nowsecure.nl/',
];

/// Cloudflare block pages, extension hosts: no check clears them, so no page
/// may open for them.
const _blocked = [
  'https://animesdrive.online/',
  'https://api.kryzox.xyz/',
  'https://cdn.imgnex.top/',
  'https://comix.to/',
  'https://def11.ycnapi.com/',
  'https://deft.yacinelive.com/',
  'https://desustream.me/',
  'https://embed.settlar.io/',
  'https://engifuosi.com/',
  'https://kuronime.biz/',
  'https://megap.norami.top/',
  'https://n.elif.news/',
  'https://pegasus.5387692.xyz/',
  'https://search.pingora.fyi/',
  'https://seriesboa.live/',
  'https://uakino.best/',
  'https://v4.kuramanime.run/',
  'https://watchanimeworld.top/',
];
