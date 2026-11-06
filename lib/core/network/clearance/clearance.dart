import 'dart:async';
import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../logger/app_logger.dart';
import '../../providers/device_info_provider.dart';
import 'captcha_solver.dart';
import 'clearance_interceptor.dart';
import 'clearance_solver.dart';
import 'clearance_store.dart';
import 'site_checks.dart';
import 'site_keys.dart';
import 'widget_tap.dart';

/// The app's bot-check clearances: one store and one solver, used by every
/// extension kind and every client. A check cleared for one extension's
/// request is cleared for all of them on that site, for as long as the site's
/// clearance lasts.
class Clearance {
  Clearance._();

  static final instance = Clearance._();

  ClearanceStore? _store;
  SiteKeys? _siteKeys;
  ClearanceSolver? _solver;
  Captchas? _captchas;
  Future<void>? _ready;

  /// Whether [init] has finished.
  bool get isReady => _solver != null;

  ClearanceStore get store => _store!;
  SiteKeys get siteKeys => _siteKeys!;
  ClearanceSolver get solver => _solver!;

  /// Each site's check this run, for the screens that wait on them: the
  /// solver's own, so what it reports is what screens read.
  SiteChecks get checks => _solver!.checks;

  /// Plugins' captcha tokens (`solveCaptcha`); null before [init] finishes.
  Captchas? get captchas => _captchas;

  /// Reads the Public Suffix List and the saved clearances. Opens no browser.
  ///
  /// The clearances live in Application Support, never Documents: they are
  /// session cookies and a record of the sites used, and on iOS Documents is
  /// shown in Files and copied into unencrypted backups.
  Future<void> init() => _ready ??= _init();

  Future<void> _init() async {
    try {
      final keys = await SiteKeys.load();
      final support = await getApplicationSupportDirectory();
      final store = ClearanceStore(
        file: File(p.join(support.path, 'clearance', 'clearances.json')),
      );
      await store.load();
      _siteKeys = keys;
      _store = store;
      final solver = _solver = ClearanceSolver(store: store, siteKeys: keys);
      _captchas = CaptchaSolver(solver);
      await fitToBrowser(solver);
    } catch (e) {
      // Without it, requests go out as they come and checks stay unsolved.
      talker.error('[Clearance] init failed', e);
    }
  }

  /// Sets [solver] up for this platform's browser: whether it can tap a
  /// Cloudflare checkbox (not iOS) and read where its widget is (not
  /// Android), which way the device's language faces and where Cloudflare
  /// puts the widget in it, and on Android whether System WebView is too old.
  static Future<void> fitToBrowser(ClearanceSolver solver) async {
    try {
      final capabilities = await ChallengeBrowser.capabilities();
      solver
        ..canTap = capabilities.canTap
        ..isolatedWorlds = capabilities.isolatedWorlds
        ..rtl = widgetRtlIn(Platform.localeName)
        ..widgetRaised = widgetRaisedIn(Platform.localeName);
      if (Platform.isAndroid) {
        solver.engineOutdated = ClearanceSolver.engineIsOutdated(
          await ChallengeBrowser.engineVersion(),
        );
        // Android 7 can't install a WebView past 119.
        solver.engineUpdatable =
            (await DeviceInfoPlugin().androidInfo).version.sdkInt >= 26;
      }
    } catch (e) {
      talker.debug('[Clearance] no browser capabilities: $e');
    }
  }

  /// Set up for tests, with a store and solver of their own. [checks], when
  /// given, must be the solver's: there is one list.
  @visibleForTesting
  void debugUse({
    required ClearanceStore store,
    required SiteKeys siteKeys,
    required ClearanceSolver solver,
    SiteChecks? checks,
  }) {
    assert(checks == null || identical(checks, solver.checks));
    _store = store;
    _siteKeys = siteKeys;
    _solver = solver;
    _captchas = CaptchaSolver(solver);
    _ready = Future.value();
  }

  /// For tests of what asks for captcha tokens: [captchas] answers them; null
  /// puts back the solver's own, if there is a solver.
  @visibleForTesting
  void debugUseCaptchas(Captchas? captchas) {
    final solver = _solver;
    _captchas = captchas ?? (solver == null ? null : CaptchaSolver(solver));
  }

  /// Sizes the solver for [profile]: fewer pages at once on a low-end
  /// device, whose memory a few heavy pages fill.
  void fitTo(DeviceProfile profile) {
    final solver = _solver;
    if (solver == null) return;
    solver.parallel = profile.isLowEnd
        ? ClearanceSolver.lowEndParallel
        : ClearanceSolver.defaultParallel;
  }

  /// The interceptor for a client, or null before [init] finishes.
  ClearanceInterceptor? interceptorFor(Dio dio) {
    final solver = _solver;
    if (solver == null) return null;
    return ClearanceInterceptor(
      dio: dio,
      store: store,
      solver: solver,
      siteKeys: siteKeys,
      checks: checks,
    );
  }

  /// The clearance [uri]'s site holds, if any: its cookies for [uri] and the
  /// agent they hold under. For clients outside the shared one, such as the
  /// player's stream requests.
  ({Map<String, String> cookies, String agent})? forUri(Uri uri) {
    final store = _store;
    final keys = _siteKeys;
    if (store == null || keys == null) return null;
    final entry = store[keys.siteOf(uri.host)];
    if (entry == null || !entry.hasClearance) return null;
    return (
      cookies: {
        for (final c in entry.cookies)
          if (c.matches(uri.host, uri.path)) c.name: c.value,
      },
      agent: entry.agent!,
    );
  }

  /// Every site that holds a clearance, for engines that send their own
  /// requests: `{site, cookies: {name: value}, userAgent, browserOnly?}`.
  List<Map<String, Object?>> liveClearances() {
    final store = _store;
    if (store == null) return const [];
    return [
      for (final entry in store.all)
        if (entry.hasClearance)
          {
            'site': entry.site,
            'cookies': {for (final c in entry.cookies) c.name: c.value},
            'userAgent': entry.agent,
            if (entry.browserOnly) 'browserOnly': true,
          },
    ];
  }

  /// Adds [uri]'s clearance to [headers]: its cookies merged into any Cookie
  /// header (the clearance's winning), and its agent unless the headers carry
  /// one already.
  Map<String, String> withClearance(Uri uri, Map<String, String> headers) {
    final clearance = forUri(uri);
    if (clearance == null || clearance.cookies.isEmpty) return headers;
    final merged = Map<String, String>.of(headers);
    final cookieKey = merged.keys
        .where((k) => k.toLowerCase() == 'cookie')
        .firstOrNull;
    final cookies = <String, String>{};
    if (cookieKey != null) {
      for (final pair in merged.remove(cookieKey)!.split(';')) {
        final at = pair.indexOf('=');
        if (at > 0) {
          cookies[pair.substring(0, at).trim()] = pair.substring(at + 1).trim();
        }
      }
    }
    cookies.addAll(clearance.cookies);
    merged['Cookie'] = [for (final e in cookies.entries) '${e.key}=${e.value}']
        .join('; ');
    if (!merged.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      merged['User-Agent'] = clearance.agent;
    }
    return merged;
  }
}
