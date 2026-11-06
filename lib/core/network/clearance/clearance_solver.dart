import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/foundation.dart';

import '../../logger/app_logger.dart';
import 'challenge_triage.dart';
import 'clearance_store.dart';
import 'site_checks.dart';
import 'site_keys.dart';
import 'widget_tap.dart';

/// What a page shows while a check may be running, read without disturbing
/// the check (see [CheckPage.glance]).
@immutable
class PageGlance {
  const PageGlance({
    required this.title,
    required this.href,
    required this.ready,
    required this.cloudflare,
    this.awsWaf = false,
  });

  final String title;
  final String href;

  /// `document.readyState`.
  final String ready;

  /// Cloudflare's challenge script is on the page (`window._cf_chl_opt`).
  final bool cloudflare;

  /// AWS WAF's challenge script is on the page (`window.gokuProps`): its
  /// page has no title.
  final bool awsWaf;

  /// Whose check the page shows, if any.
  CheckVendor? get vendor => cloudflare
      ? CheckVendor.cloudflare
      : awsWaf
      ? CheckVendor.awsWaf
      : vendorOfTitle(title);

  /// A check is running, any vendor's.
  bool get checking => vendor != null;

  bool get blocked => blockTitle.hasMatch(title);

  /// The page holds a site's document: a new page shows `about:blank` until
  /// its first load commits, and that is neither a check nor the site.
  bool get onSite => href.startsWith('http');
}

/// What the solver needs from a page. [BrowserCheckPage] is the real one,
/// over the challenge browser; tests use fakes.
abstract interface class CheckPage {
  /// Loads [url], with [headers] on the request (a referer, for one).
  Future<void> load(String url, {Map<String, String> headers = const {}});

  /// The page's title, address and state. Never a lookup of the check's own
  /// elements: Cloudflare's check notices those and answers with a clearance
  /// it then refuses, in a loop.
  Future<PageGlance?> glance();

  /// The cookies the browser holds for [url].
  Future<List<StoredCookie>> cookies(String url);

  /// Deletes [url]'s cookie [name], or all of its cookies when [name] is null.
  Future<void> deleteCookies(String url, {String? name});

  Future<String> userAgent();

  /// A request from inside the page (same origin), with its cookies and TLS.
  Future<InPageResponse> fetch(InPageRequest request);

  /// What happens in the page: the requests it makes (while [setCapture] is
  /// on), and its renderer ending.
  Stream<BrowserEvent> get events;

  /// Reports the page's requests as [CapturedRequest] events: observed only.
  Future<void> setCapture(bool enabled);

  /// Runs [script] in the page; its result as JSON text. Never on a page
  /// showing a check (see [glance]).
  Future<String> evaluate(String script);

  /// A tap or click at [x], [y] CSS pixels, as the platform's own input.
  Future<void> tap(double x, double y);

  /// Where Turnstile's widget is, read where the check's scripts can't see
  /// the look ([widgetBoxScript]); null without an isolated world, or with no
  /// widget.
  Future<WidgetBox?> widgetBox();

  /// The browser, for showing the page in the check sheet; null in tests.
  ChallengeBrowser? get browser;

  Future<void> dispose();
}

/// A page in the platform's own browser engine.
class BrowserCheckPage implements CheckPage {
  BrowserCheckPage._(this.browser);

  static Future<CheckPage> open() async =>
      BrowserCheckPage._(await ChallengeBrowser.create());

  @override
  final ChallengeBrowser browser;

  static const _glance = '''
(function(){
  return [document.title, location.href, document.readyState,
    typeof window._cf_chl_opt !== 'undefined',
    typeof window.gokuProps !== 'undefined'];
})()''';

  @override
  Future<void> load(String url, {Map<String, String> headers = const {}}) =>
      browser.load(url, headers: headers);

  @override
  Stream<BrowserEvent> get events => browser.events;

  @override
  Future<void> setCapture(bool enabled) => browser.setCapture(enabled);

  @override
  Future<String> evaluate(String script) => browser.evaluate(script);

  @override
  Future<void> tap(double x, double y) => browser.tap(x, y);

  @override
  Future<void> deleteCookies(String url, {String? name}) =>
      browser.deleteCookies(url, name: name);

  @override
  Future<WidgetBox?> widgetBox() async {
    try {
      return WidgetBox.fromJson(
        jsonDecode(await browser.evaluateIsolated(widgetBoxScript)),
      );
    } catch (_) {
      // No isolated world here, or the page is between documents.
      return null;
    }
  }

  @override
  Future<PageGlance?> glance() async {
    try {
      final json = jsonDecode(await browser.evaluate(_glance));
      if (json is! List || json.length < 4) return null;
      return PageGlance(
        title: json[0] as String? ?? '',
        href: json[1] as String? ?? '',
        ready: json[2] as String? ?? '',
        cloudflare: json[3] == true,
        awsWaf: json.length > 4 && json[4] == true,
      );
    } catch (_) {
      return null; // Between documents.
    }
  }

  @override
  Future<List<StoredCookie>> cookies(String url) async => [
    for (final c in await browser.cookies(url))
      StoredCookie(
        name: c.name,
        value: c.value,
        domain: c.domain,
        path: c.path,
        expires: c.expires,
        httpOnly: c.httpOnly,
        secure: c.secure,
      ),
  ];

  @override
  Future<String> userAgent() => browser.userAgent;

  @override
  Future<InPageResponse> fetch(InPageRequest request) =>
      browser.fetchInPage(request);

  @override
  Future<void> dispose() => browser.dispose();
}

/// How a solve ended.
enum SolveResult {
  /// The check cleared; the site's clearance is in the store.
  cleared,

  /// The check wants a person: Cloudflare's checkbox, or a puzzle.
  needsPerson,

  /// A block page: no check clears it.
  blocked,

  /// The page failed to load, or the check neither cleared nor asked for a
  /// person in time.
  failed,

  /// After its check, the browser was sent to another site: nothing it holds
  /// clears this one.
  sentElsewhere,

  /// Android System WebView is too old for the check: nothing was tried.
  outdated,
}

/// Checks that only compute: no person can help them along ([workAfter]).
const _computedChecks = {
  CheckVendor.anubis,
  CheckVendor.hostAdmin,
  CheckVendor.awsWaf,
  CheckVendor.vercel,
};

/// Shows [page], whose check wants a person, in the check sheet: how the
/// sheet was left.
typedef CheckPresenter = Future<ChallengeSheetResult> Function({
  required CheckPage page,
  required String site,
  required Future<void> cleared,
});

/// Clears sites' bot checks in hidden pages: one solve per site at a time,
/// and a few sites at once.
class ClearanceSolver {
  ClearanceSolver({
    required this.store,
    required this.siteKeys,
    Future<CheckPage> Function()? openPage,
    int? parallel,
    this.needsPersonAfter = const Duration(seconds: 20),
    this.workAfter = const Duration(seconds: 60),
    this.giveUpAfter = const Duration(seconds: 30),
    this.pollEvery = const Duration(milliseconds: 500),
    this.idlePages = const Duration(seconds: 60),
    this.personHold = const Duration(minutes: 5),
    this.failedHold = const Duration(minutes: 1),
    this.ineffectiveHold = const Duration(minutes: 10),
    this.callLimit = const Duration(seconds: 10),
    this.tapAfter = const Duration(seconds: 6),
    this.tapEvery = const Duration(seconds: 4),
    this.maxTaps = 3,
    this.canTap = false,
    this.isolatedWorlds = false,
    this.rtl = false,
    int? keptOrigins,
    SiteChecks? checks,
  }) : checks = checks ?? SiteChecks(),
       _openPage = openPage ?? BrowserCheckPage.open,
       parallel = parallel ?? defaultParallel,
       _keptOrigins = keptOrigins;

  /// Hidden pages at once (decision 19): 3 on phones and TVs, 4 on desktops.
  static int get defaultParallel =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
      ? 4
      : 3;

  /// Pages at once on a low-end device (under 2 GB, or Android's low-RAM
  /// flag): three ran a 2 GB TV out of memory.
  static const lowEndParallel = 2;

  final ClearanceStore store;
  final SiteKeys siteKeys;

  /// Each site's check, for the screens that wait on them.
  final SiteChecks checks;
  final Future<CheckPage> Function() _openPage;

  /// Pages open at once, of every kind, and so solves at once too. Set once
  /// the device is known ([Clearance.fitTo]).
  int parallel;

  /// Pages kept open on browser-only sites' origins, at most: one fewer than
  /// [parallel], so a solve always has room.
  int get keptOrigins => _keptOrigins ?? max(1, parallel - 1);
  final int? _keptOrigins;

  /// A check still running this long into a hidden solve wants a person,
  /// when the solve has the device to itself; half as long again for each
  /// other solve running ([_stretch]).
  final Duration needsPersonAfter;

  /// The same for a check that only computes ([_computedChecks]): no person
  /// can help it along, and on a slow device it takes longer (Anubis took
  /// 43 s on a phone emulator).
  final Duration workAfter;

  /// A solve that hasn't settled by then has failed.
  final Duration giveUpAfter;
  final Duration pollEvery;

  /// How long a parked or browser-only page waits for its next use.
  final Duration idlePages;

  /// A site whose check wanted a person, or that showed the browser a block
  /// page, gets no new hidden solve for this long, as the next would end the
  /// same way: its requests fail fast, and Verify still opens its check.
  final Duration personHold;

  /// A site whose solve failed (its page didn't load, or its check didn't
  /// settle in time) gets no new one for this long.
  final Duration failedHold;

  /// A site that refused even a request from inside its page after a solve
  /// gets no new solve for this long: solving again wouldn't help.
  final Duration ineffectiveHold;

  /// The longest one call to a page may take. A browser can stop answering
  /// (Android's `evaluateJavascript` callback sometimes never fires); a call
  /// left waiting would hold its solve's place for good.
  final Duration callLimit;

  /// A Cloudflare check still showing this long into a hidden solve gets its
  /// checkbox tapped, on the same stretched clock as [needsPersonAfter]:
  /// most checks clear by themselves within a few seconds.
  final Duration tapAfter;

  /// Time between taps, for the check to answer the last one.
  final Duration tapEvery;

  /// Taps on one check before it goes to the person.
  final int maxTaps;

  /// The platform's browser can tap ([BrowserCapabilities.canTap]): every
  /// platform but iOS. Set by the app at start ([Clearance.init]).
  bool canTap;

  /// Pages can be read where their scripts can't see
  /// ([BrowserCapabilities.isolatedWorlds]): the widget's box is read; without
  /// one (Android), the tap goes to [fixedWidgetBox].
  bool isolatedWorlds;

  /// The device's language reads right to left: Cloudflare mirrors its
  /// widget, and the fixed tap with it.
  bool rtl;

  /// Cloudflare's interstitial raises its widget in the device's language
  /// ([widgetRaisedIn]): the blind taps start at the raised row. Set by the
  /// app at start.
  bool widgetRaised = false;

  /// Android System WebView is too old to pass checks ([engineIsOutdated]):
  /// hidden solves are skipped, and rows say why. Set by the app at start.
  bool engineOutdated = false;

  /// This Android can update its WebView (8 and later); on 7 the last is too
  /// old ([engineIsOutdated]).
  bool engineUpdatable = true;

  /// The first Android System WebView that passes Cloudflare's checks: 115
  /// passed none of 14 sites on 2026-10-04, while 138 passed like today's.
  static const firstPassingEngine = 120;

  /// Whether a WebView [version] name is older than [firstPassingEngine]; an
  /// unreadable one isn't.
  static bool engineIsOutdated(String version) {
    final major = int.tryParse(version.split('.').first.trim());
    return major != null && major < firstPassingEngine;
  }

  /// Set by the app once it can show the check sheet.
  CheckPresenter? presenter;

  final Map<String, Future<SolveOutcome>> _running = {};
  int _active = 0;

  /// Pages open, of every kind: solves', parked, and browser-only sites'.
  /// At most [parallel]: each holds renderer memory a TV has little of.
  int _pages = 0;

  /// Pages open now, of every kind.
  int get openPages => _pages;

  /// Completed when a page closes, for whoever waits for room.
  Completer<void>? _pageFreed;

  /// Verify calls waiting for a page: automatic tries wait behind them.
  int _urgent = 0;
  final List<Completer<void>> _waiting = [];

  /// Pages whose check wants a person, kept warm for the sheet.
  final Map<String, _KeptPage> _parked = {};

  /// Until when each site gets no new hidden solve, and how its last ended.
  final Map<String, ({DateTime until, SolveResult result})> _holds = {};

  /// When each site last refused a request from inside its page.
  final Map<String, DateTime> _ineffective = {};

  /// Pages on browser-only sites' origins, for their requests: the least
  /// recently used first.
  final Map<String, _KeptPage> _originPages = {};

  /// Origin pages still loading.
  final Map<String, Future<_KeptPage>> _openingOrigins = {};

  /// Completed when an origin page is let go of or closed, for requests
  /// waiting for room.
  Completer<void>? _originFreed;

  /// One sheet at a time.
  Future<void> _sheet = Future.value();

  String _agent = '';

  /// Solves [url]'s site, or joins its solve already running. Whatever made
  /// the request may start one (the owner, 2026-10-03). With [personWaiting]
  /// (a title opening, its streams), a check that wants a person opens the
  /// check sheet.
  Future<SolveOutcome> solve(Uri url, {bool personWaiting = false}) async {
    final site = siteKeys.siteOf(url.host);
    final running = _running[site];
    if (running != null) {
      final outcome = await running;
      if (outcome.result == SolveResult.needsPerson && personWaiting) {
        return await _askPerson(site);
      }
      return outcome;
    }
    if (isIneffective(site)) {
      _note(site, CheckState.ineffective);
      return const SolveOutcome(SolveResult.failed);
    }
    final hold = _holds[site];
    if (hold != null && DateTime.now().isBefore(hold.until)) {
      if (hold.result != SolveResult.needsPerson) {
        _note(site, _stateOf(hold.result));
        return SolveOutcome(hold.result);
      }
      // Cleared meanwhile through Verify, the hold no longer stands.
      if (store[site]?.needsPerson ?? false) {
        if (personWaiting) return await _askPerson(site);
        _note(site, CheckState.needsYou);
        return const SolveOutcome(SolveResult.needsPerson);
      }
    }
    final solve = _solve(site, url.toString());
    _running[site] = solve;
    try {
      final outcome = await solve;
      if (outcome.result == SolveResult.needsPerson && personWaiting) {
        return await _askPerson(site);
      }
      return outcome;
    } finally {
      if (identical(_running[site], solve)) _running.remove(site)?.ignore();
    }
  }

  /// The person waiting on [site]'s check gets its sheet, unless they asked
  /// not to ([ClearanceStore.isQuiet]): then its row waits for Verify.
  Future<SolveOutcome> _askPerson(String site) async {
    if (store.isQuiet(site)) {
      _note(site, CheckState.needsYou);
      return const SolveOutcome(SolveResult.needsPerson);
    }
    return verify(site);
  }

  /// [site] refused a request from inside its page after a solve.
  void markIneffective(String site) => _ineffective[site] = DateTime.now();

  /// Whether solving [site] again wouldn't help yet ([ineffectiveHold]).
  bool isIneffective(String site) {
    final at = _ineffective[site];
    return at != null && DateTime.now().difference(at) < ineffectiveHold;
  }

  /// How a check that ended in [result] shows.
  static CheckState _stateOf(SolveResult result) => switch (result) {
    SolveResult.cleared => CheckState.cleared,
    SolveResult.needsPerson => CheckState.needsYou,
    SolveResult.blocked => CheckState.blocked,
    SolveResult.sentElsewhere => CheckState.sentElsewhere,
    SolveResult.failed => CheckState.unreachable,
    SolveResult.outdated => CheckState.outdated,
  };

  /// [state] for [site], unless a person is verifying it now: a request held
  /// meanwhile mustn't reset its row.
  void _note(String site, CheckState state) {
    if (checks[site]?.state == CheckState.opening) return;
    checks.update(site, state);
  }

  /// Something [source] needed from [site] at [url] wants a person, and none
  /// is there (a captcha, for one): its row asks for Verify, as a check's
  /// would.
  void notePersonNeeded(String site, String url, {String? source}) {
    store.markNeedsPerson(site, url);
    checks.met(site, source: source);
    _note(site, CheckState.needsYou);
  }

  /// Shows [page] in the check sheet once no other sheet is showing: how the
  /// sheet was left, or null when the app can't show one.
  Future<ChallengeSheetResult?> showSheet({
    required CheckPage page,
    required String site,
    required Future<void> cleared,
  }) {
    final result = _sheet.then((_) async {
      final present = presenter;
      if (present == null) return null;
      return present(page: page, site: site, cleared: cleared);
    });
    _sheet = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// Shows [site]'s check in the sheet for a person to finish: its warm page
  /// if a hidden solve left one, else a new one.
  Future<SolveOutcome> verify(String site) {
    final result = _sheet.then((_) => _verify(site));
    _sheet = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<SolveOutcome> _verify(String site) async {
    checks.update(site, CheckState.opening);
    // A hidden try for this site still running: its page is the one to show,
    // or its clearance the answer.
    final running = _running[site];
    if (running != null) await running;
    final entry = store[site];
    final url = entry?.checkUrl ?? 'https://$site/';
    if (store.isFresh(site)) {
      store.markNeedsPerson(site, url, needed: false);
      checks.update(site, CheckState.cleared);
      return _clearedOutcome(site);
    }
    final present = presenter;
    if (present == null) {
      checks.update(site, CheckState.needsYou);
      return const SolveOutcome(SolveResult.needsPerson);
    }
    final kept = _parked.remove(site);
    kept?.idle?.cancel();
    final CheckPage page;
    try {
      page = kept?.page ?? await _open(urgent: true);
    } catch (e) {
      talker.debug('[Clearance] $site: no page for Verify: $e');
      checks.update(site, CheckState.needsYou);
      return const SolveOutcome(SolveResult.needsPerson);
    }
    var watching = true;
    try {
      if (kept == null) await page.load(url);
      final before = await _clearanceValue(page, url);
      var clearedNow = false;
      final guard = _LoopGuard();
      final cleared = _watchCleared(
        page,
        url,
        before,
        () => !watching,
        guard: guard,
      ).then((done) => clearedNow = done);
      final left = await present(
        page: page,
        site: site,
        cleared: cleared.then((_) {}),
      );
      if (left == ChallengeSheetResult.quiet) store.setQuiet(site, true);
      if (await _elsewhere(page, site) case final host?) {
        _hold(site, SolveResult.sentElsewhere);
        checks.update(site, CheckState.sentElsewhere, elsewhere: host);
        return SolveOutcome(SolveResult.sentElsewhere, null, host);
      }
      // Done is the person's word: it counts once the page is past its check.
      final glance = await page.glance();
      final pastCheck = glance != null && glance.onSite && !glance.checking;
      if (clearedNow || left != ChallengeSheetResult.closed && pastCheck) {
        await _record(page, site, url);
        store.markNeedsPerson(site, url, needed: false);
        checks.update(site, CheckState.cleared);
        return _clearedOutcome(site);
      }
      checks.update(
        site,
        guard.loopedAfterRestart
            ? CheckState.keepsAsking
            : left == ChallengeSheetResult.done
            ? CheckState.stillNotCleared
            : CheckState.needsYou,
      );
      return const SolveOutcome(SolveResult.needsPerson);
    } catch (e) {
      // The page, the sheet or the cookies failed: the person can try again.
      talker.debug('[Clearance] $site: Verify failed: $e');
      checks.update(site, CheckState.needsYou);
      return const SolveOutcome(SolveResult.needsPerson);
    } finally {
      watching = false;
      await page.dispose();
    }
  }

  /// Sends [request] from inside a page on its origin: for sites that refuse
  /// requests from outside the browser. The page stays open a while for the
  /// next request; at most [keptOrigins] are, and a request waits for room.
  Future<InPageResponse> fetchInPage(Uri url, InPageRequest request) async {
    final origin = url.origin;
    final kept = await _originPage(origin);
    try {
      return await kept.page.fetch(request);
    } finally {
      kept.busy--;
      if (kept.busy == 0 && identical(_originPages[origin], kept)) {
        kept.idle = Timer(idlePages, () {
          if (identical(_originPages[origin], kept) && kept.busy == 0) {
            _closeOrigin(origin);
          }
        });
      }
      _freeOrigin();
    }
  }

  /// [fetchInPage], for a site that refuses requests from outside the
  /// browser. Null when the page can't send it, or the site refused the page
  /// too; either way the site is held for [ineffectiveHold], and asked
  /// nothing meanwhile. Headers a page's `fetch` may not set are left out.
  Future<InPageResponse?> sendFromPage(Uri url, InPageRequest request) async {
    final site = siteKeys.siteOf(url.host);
    if (isIneffective(site)) return null;
    try {
      final reply = await fetchInPage(
        url,
        InPageRequest(
          request.url,
          method: request.method,
          headers: {
            for (final e in request.headers.entries)
              if (!_forbiddenInPage.contains(e.key.toLowerCase()))
                e.key: e.value,
          },
          body: request.body,
        ),
      );
      if (_refusedInPage(reply)) {
        talker.debug('[Clearance] ${url.host} refuses its own page');
        markIneffective(site);
        return null;
      }
      return reply;
    } catch (e) {
      // The page can't send it (it isn't on the site, or the site is down):
      // the next ones wouldn't get through either.
      talker.debug('[Clearance] in-page request failed: $e');
      markIneffective(site);
      return null;
    }
  }

  /// A page within the page budget, for other work than a solve (resolving
  /// a CloudStream extension's page). Disposing it gives its place back.
  Future<CheckPage> borrowPage() => _open();

  /// [origin]'s page, marked busy: kept, opening, or opened now, closing the
  /// least recently used idle one to make room.
  Future<_KeptPage> _originPage(String origin) async {
    while (true) {
      final kept = _originPages.remove(origin);
      if (kept != null) {
        _originPages[origin] = kept;
        kept.idle?.cancel();
        kept.busy++;
        return kept;
      }
      final opening = _openingOrigins[origin];
      if (opening != null) {
        await opening;
        continue;
      }
      if (_originPages.length + _openingOrigins.length < keptOrigins) {
        final open = _openOrigin(origin);
        _openingOrigins[origin] = open;
        try {
          final page = await open;
          page.busy++;
          _originPages[origin] = page;
          return page;
        } finally {
          _openingOrigins.remove(origin)?.ignore();
          _freeOrigin();
        }
      }
      final idle = _originPages.entries
          .where((e) => e.value.busy == 0)
          .firstOrNull;
      if (idle != null) {
        _closeOrigin(idle.key);
        continue;
      }
      await (_originFreed ??= Completer<void>()).future;
    }
  }

  Future<_KeptPage> _openOrigin(String origin) async {
    final page = await _open();
    try {
      await page.load('$origin/');
      // Wait out a check the origin's page may show; its clearance is the
      // browser's own.
      final end = DateTime.now().add(giveUpAfter);
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(pollEvery);
        final glance = await page.glance();
        // Parsed is enough to send from: a page with endless ads or
        // long-polling never reaches 'complete'.
        if (glance == null ||
            !glance.onSite ||
            glance.checking ||
            glance.ready == 'loading') {
          continue;
        }
        // Sent elsewhere (another host, or www.): its requests to the site
        // would be cross-origin, and fail.
        if (Uri.tryParse(glance.href)?.origin != origin) break;
        return _KeptPage(page);
      }
      // A request sent from a blank page, a check or another site goes
      // nowhere.
      throw StateError('$origin did not load');
    } catch (_) {
      await page.dispose();
      rethrow;
    }
  }

  void _closeOrigin(String origin) {
    final kept = _originPages.remove(origin);
    if (kept == null) return;
    kept.idle?.cancel();
    unawaited(kept.page.dispose());
    _freeOrigin();
  }

  void _freeOrigin() {
    final freed = _originFreed;
    _originFreed = null;
    freed?.complete();
  }

  Future<SolveOutcome> _solve(String site, String url) async {
    if (engineOutdated) {
      // It would fail the check: nothing is tried, and the row says why.
      checks.update(site, CheckState.outdated);
      return const SolveOutcome(SolveResult.outdated);
    }
    await _slot();
    checks.update(site, CheckState.checking);
    final started = DateTime.now();
    CheckPage? page;
    var keep = false;
    try {
      page = await _open();
      final before = await _clearanceValue(page, url);
      await page.load(url);
      final (outcome, taps) = await _wait(page, site, url, before, started);
      _hold(site, outcome.result);
      checks.update(
        site,
        _stateOf(outcome.result),
        elsewhere: outcome.elsewhere,
      );
      talker.debug(
        '[Clearance] $site: ${outcome.result.name} in '
        '${DateTime.now().difference(started).inMilliseconds} ms, taps=$taps',
      );
      if (outcome.result == SolveResult.needsPerson) {
        store.markNeedsPerson(site, url);
        _park(site, url, page, before);
        keep = true;
      }
      return outcome;
    } catch (e) {
      talker.debug('[Clearance] $site: failed: $e');
      _hold(site, SolveResult.failed);
      checks.update(site, CheckState.unreachable);
      return const SolveOutcome(SolveResult.failed);
    } finally {
      if (!keep) await page?.dispose();
      _release();
    }
  }

  /// How much slower a check runs beside the other solves running now.
  double get _stretch => 1 + 0.5 * max(0, _active - 1);

  /// Holds off [site]'s next hidden solve after one that ended in [result].
  void _hold(String site, SolveResult result) {
    final hold = switch (result) {
      SolveResult.needsPerson ||
      SolveResult.blocked ||
      SolveResult.sentElsewhere => personHold,
      SolveResult.failed => failedHold,
      _ => null,
    };
    if (hold == null) return;
    _holds[site] = (until: DateTime.now().add(hold), result: result);
  }

  /// Polls the page until its check clears, wants a person, or blocks; with
  /// the taps it sent.
  Future<(SolveOutcome, int)> _wait(
    CheckPage page,
    String site,
    String url,
    String? before,
    DateTime started,
  ) async {
    var taps = 0;
    final outcome = await _waitFor(page, site, url, before, started, () {
      taps++;
    });
    return (outcome, taps);
  }

  Future<SolveOutcome> _waitFor(
    CheckPage page,
    String site,
    String url,
    String? before,
    DateTime started,
    void Function() tapped,
  ) async {
    var checkSeen = false;
    var cloudflareSeen = false;
    // A check that only computes gets longer, and so does the page it leaves
    // busy or between documents meanwhile.
    var computedSeen = false;
    Duration giveUp() => computedSeen
        ? giveUpAfter + (workAfter - needsPersonAfter)
        : giveUpAfter;
    var clearedPolls = 0;
    var quietPolls = 0;
    // Taps on Cloudflare's checkbox: when the check first showed, the taps
    // sent, and the clearances it minted while the check stayed (a loop).
    Duration? checkFrom;
    var taps = 0;
    var lastClearance = before;
    var minted = 0;
    while (true) {
      await Future<void>.delayed(pollEvery);
      // Measured as if the solve were alone: checks sharing a device run
      // slower (on a 2 GB TV, three at once took 2–3 times as long).
      final elapsed = DateTime.now().difference(started) * (1 / _stretch);
      final glance = await page.glance();
      if (glance == null || !glance.onSite) {
        if (elapsed > giveUp()) {
          return const SolveOutcome(SolveResult.failed);
        }
        continue;
      }
      if (glance.blocked) return const SolveOutcome(SolveResult.blocked);
      if (glance.checking) {
        checkSeen = true;
        cloudflareSeen |= glance.vendor == CheckVendor.cloudflare;
        clearedPolls = 0;
        final computing = _computedChecks.contains(glance.vendor);
        computedSeen |= computing;
        final limit = computing ? workAfter : needsPersonAfter;
        if (elapsed > limit) {
          return const SolveOutcome(SolveResult.needsPerson);
        }
        checkFrom ??= elapsed;
        // Cloudflare's check only, while it shows: one that passes into
        // another vendor's (kinoger.com: then HostAdmin's) gets no more.
        if (canTap &&
            glance.vendor == CheckVendor.cloudflare &&
            taps < maxTaps) {
          // A clearance minted while the check stays is the check looping:
          // tapping on would only feed it.
          final value = await _clearanceValue(page, url);
          if (value != null && value != lastClearance) {
            lastClearance = value;
            minted++;
          }
          if (minted < 2 && elapsed - checkFrom >= tapAfter + tapEvery * taps) {
            if (await _tap(page, taps)) {
              taps++;
              tapped();
            }
          }
        }
        continue;
      }
      // Parsed is settled enough: a cleared site whose ads or long polling
      // never let it reach 'complete' still holds its new cookie.
      if (glance.ready == 'loading') {
        if (elapsed > giveUp()) {
          return const SolveOutcome(SolveResult.failed);
        }
        continue;
      }
      // The browser was sent to another site, after its check or with none
      // (a moved or parked domain): nothing it holds clears this one.
      final landed = Uri.tryParse(glance.href)?.host ?? '';
      if (siteKeys.siteOf(landed) != site) {
        if (checkSeen || ++quietPolls >= 3) {
          talker.debug('[Clearance] $site sent the browser to $landed');
          return SolveOutcome(SolveResult.sentElsewhere, null, landed);
        }
        continue;
      }
      if (checkSeen) {
        // Cloudflare's check leaves a new cf_clearance; the others' only go.
        final value = await _clearanceValue(page, url);
        if (!cloudflareSeen || value != null && value != before) {
          // Two settled looks in a row: a check that loops comes back.
          if (++clearedPolls >= 2) {
            await _record(page, site, url);
            return _clearedOutcome(site);
          }
        }
      } else if (++quietPolls >= 3) {
        // No check in the browser: the site challenged only plain clients.
        // The browser's cookies and agent are what get through.
        await _record(page, site, url);
        return _clearedOutcome(site);
      }
      if (elapsed > giveUp()) return const SolveOutcome(SolveResult.failed);
    }
  }

  /// Watches a shown page until its check clears (true) or [stopped]. With
  /// [guard], a check that comes back after every new clearance is started
  /// afresh, once: its check cookies deleted and its page loaded again.
  Future<bool> _watchCleared(
    CheckPage page,
    String url,
    String? before,
    bool Function() stopped, {
    _LoopGuard? guard,
  }) async {
    var seen = 0;
    var cloudflare = false;
    var latest = before;
    var minted = false;
    while (!stopped()) {
      await Future<void>.delayed(pollEvery);
      if (stopped()) break;
      final glance = await page.glance();
      if (guard != null && glance != null && glance.checking) {
        // A check back after a new clearance: a loop.
        if (minted) {
          minted = false;
          if (guard.restarted) {
            guard.loopedAfterRestart = true;
          } else if (++guard.loops >= _LoopGuard.limit) {
            guard.restarted = true;
            await _startAfresh(page, url);
            latest = null;
            continue;
          }
        }
        final value = await _clearanceValue(page, url);
        if (value != null && value != latest) {
          latest = value;
          minted = true;
        }
      }
      if (glance == null ||
          !glance.onSite ||
          glance.checking ||
          glance.ready == 'loading') {
        if (glance != null && glance.checking) {
          cloudflare |= glance.vendor == CheckVendor.cloudflare;
        }
        seen = 0;
        continue;
      }
      final value = await _clearanceValue(page, url);
      if (!cloudflare && value == null || value != null && value != before) {
        if (++seen >= 2) return true;
      }
    }
    return false;
  }

  /// Taps Cloudflare's checkbox once, where its widget is, unless the check
  /// cleared meanwhile or its widget answered already: [attempt] taps after
  /// the first. Whether it tapped.
  Future<bool> _tap(CheckPage page, int attempt) async {
    final read = await page.widgetBox();
    final box =
        read ??
        (isolatedWorlds
            ? null
            : fixedWidgetBox(
                rtl: rtl,
                raisedFirst: widgetRaised,
                attempt: attempt,
              ));
    if (box == null || box.answered) return false;
    // Looked at again right before: the check may have cleared meanwhile, or
    // passed into another vendor's.
    final fresh = await page.glance();
    if (fresh == null || fresh.vendor != CheckVendor.cloudflare) return false;
    final at = tapPoint(box);
    try {
      await page.tap(at.x, at.y);
      return true;
    } catch (e) {
      talker.debug('[Clearance] tap failed: $e');
      return false;
    }
  }

  /// Deletes [url]'s check cookies and loads its check again: a check stuck
  /// in a loop starts over.
  Future<void> _startAfresh(CheckPage page, String url) async {
    try {
      for (final cookie in await page.cookies(url)) {
        if (isCheckCookie(cookie.name)) {
          await page.deleteCookies(url, name: cookie.name);
        }
      }
      await page.load(url);
    } catch (e) {
      talker.debug('[Clearance] fresh start failed: $e');
    }
  }

  Future<void> _record(CheckPage page, String site, String url) async {
    final cookies = await page.cookies(url);
    if (_agent.isEmpty) _agent = await page.userAgent();
    store.recordSolve(site, cookies: cookies, agent: _agent, url: url);
    _holds.remove(site);
  }

  SolveOutcome _clearedOutcome(String site) =>
      SolveOutcome(SolveResult.cleared, store[site]);

  Future<String?> _clearanceValue(CheckPage page, String url) async {
    try {
      for (final c in await page.cookies(url)) {
        if (c.name == 'cf_clearance') return c.value;
      }
    } catch (_) {}
    return null;
  }

  /// Keeps [site]'s page warm for the sheet, and watches it meanwhile: a
  /// check that was only slow (a busy device) may still clear by itself.
  void _park(String site, String url, CheckPage page, String? before) {
    final previous = _parked.remove(site);
    previous?.idle?.cancel();
    if (previous != null) unawaited(previous.page.dispose());
    // At most two warm pages: they hold a renderer each.
    while (_parked.length >= 2) {
      final oldest = _parked.keys.first;
      final kept = _parked.remove(oldest)!;
      kept.idle?.cancel();
      unawaited(kept.page.dispose());
    }
    final kept = _KeptPage(page);
    kept.idle = Timer(idlePages * 2, () {
      if (identical(_parked[site], kept)) _parked.remove(site);
      unawaited(page.dispose());
    });
    _parked[site] = kept;
    // Someone waiting for room can have it: a page kept warm can be given up.
    _wake();
    unawaited(() async {
      final cleared = await _watchCleared(
        page,
        url,
        before,
        () => !identical(_parked[site], kept),
      );
      if (!cleared || !identical(_parked[site], kept)) return;
      _parked.remove(site);
      kept.idle?.cancel();
      try {
        if (await _elsewhere(page, site) case final host?) {
          _hold(site, SolveResult.sentElsewhere);
          checks.update(site, CheckState.sentElsewhere, elsewhere: host);
          return;
        }
        await _record(page, site, url);
        store.markNeedsPerson(site, url, needed: false);
        checks.update(site, CheckState.cleared);
        talker.debug('[Clearance] $site cleared by itself while parked');
      } catch (_) {
        // The page went away meanwhile.
      } finally {
        await page.dispose();
      }
    }());
  }

  /// The host [page] ended up on, when that is another site than [site].
  Future<String?> _elsewhere(CheckPage page, String site) async {
    final glance = await page.glance();
    if (glance == null || !glance.onSite) return null;
    final host = Uri.tryParse(glance.href)?.host ?? '';
    return siteKeys.siteOf(host) == site ? null : host;
  }

  /// A new page within the page budget, every call to it limited to
  /// [callLimit]. A full budget closes a parked page, then an idle
  /// browser-only one, or waits for one to close.
  Future<CheckPage> _open({bool urgent = false}) async {
    if (urgent) _urgent++;
    try {
      while (_pages >= parallel || !urgent && _urgent > 0) {
        if (_pages < parallel) {
          // Room, but Verify is waiting for it.
          await (_pageFreed ??= Completer<void>()).future;
          continue;
        }
        if (_parked.isNotEmpty) {
          final kept = _parked.remove(_parked.keys.first)!;
          kept.idle?.cancel();
          await kept.page.dispose();
          continue;
        }
        final idle = _originPages.entries
            .where((e) => e.value.busy == 0)
            .firstOrNull;
        if (idle != null) {
          _closeOrigin(idle.key);
          continue;
        }
        await (_pageFreed ??= Completer<void>()).future;
      }
      _pages++;
    } finally {
      if (urgent) {
        _urgent--;
        _wake();
      }
    }
    try {
      final page = await _openPage().timeout(callLimit);
      return _BoundedPage(page, callLimit, onClosed: _pageClosed);
    } catch (_) {
      _pageClosed();
      rethrow;
    }
  }

  void _pageClosed() {
    _pages--;
    _wake();
  }

  /// Lets [_open]'s waiters look again: a page closed, or one is only kept
  /// warm now and can be given up.
  void _wake() {
    final freed = _pageFreed;
    _pageFreed = null;
    freed?.complete();
  }

  Future<void> _slot() async {
    if (_active < parallel) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiting.add(waiter);
    await waiter.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else {
      _active--;
    }
  }

  /// Closes every page (the app is going away, or tests are done).
  Future<void> dispose() async {
    for (final kept in _parked.values) {
      kept.idle?.cancel();
      await kept.page.dispose();
    }
    _parked.clear();
    for (final origin in [..._originPages.keys]) {
      _closeOrigin(origin);
    }
    for (final pending in [..._openingOrigins.values]) {
      try {
        await (await pending).page.dispose();
      } catch (_) {}
    }
  }

  @visibleForTesting
  int get activeSolves => _active;

  @visibleForTesting
  Set<String> get parkedSites => _parked.keys.toSet();
}

/// Headers a page's `fetch` may not set.
const _forbiddenInPage = {
  'cookie',
  'user-agent',
  'host',
  'content-length',
  'accept-encoding',
  'connection',
  'referer',
  'origin',
};

/// Whether a request sent from inside a page was refused all the same: the
/// site's check, in its headers or its body.
bool _refusedInPage(InPageResponse reply) {
  String? header(String name) => reply.headers.entries
      .where((e) => e.key.toLowerCase() == name)
      .firstOrNull
      ?.value;
  if (triageHeaders(reply.status, header) == Triage.challenge) return true;
  return reply.status >= 400 && triageBody(reply.body) == Triage.challenge;
}

/// A solve's result, with the site's clearance when it cleared, and the host
/// the browser was sent to when it was sent elsewhere.
@immutable
class SolveOutcome {
  const SolveOutcome(this.result, [this.clearance, this.elsewhere]);

  final SolveResult result;
  final SiteClearance? clearance;
  final String? elsewhere;
}

/// A shown check's loops: a check that comes back after a new clearance.
class _LoopGuard {
  /// Loops before the check starts afresh.
  static const limit = 3;

  int loops = 0;
  bool restarted = false;
  bool loopedAfterRestart = false;
}

/// A page whose calls give up after [limit]: a glance that takes longer is
/// one between documents, and a dispose is let go of.
class _BoundedPage implements CheckPage {
  _BoundedPage(this._page, this.limit, {required this.onClosed});

  final CheckPage _page;
  final Duration limit;

  /// Called once, when the page is disposed.
  final void Function() onClosed;
  bool _closed = false;

  @override
  ChallengeBrowser? get browser => _page.browser;

  @override
  Future<void> load(String url, {Map<String, String> headers = const {}}) =>
      _page.load(url, headers: headers).timeout(limit);

  @override
  Stream<BrowserEvent> get events => _page.events;

  @override
  Future<void> setCapture(bool enabled) =>
      _page.setCapture(enabled).timeout(limit);

  @override
  Future<String> evaluate(String script) =>
      _page.evaluate(script).timeout(limit);

  @override
  Future<void> tap(double x, double y) => _page.tap(x, y).timeout(limit);

  @override
  Future<void> deleteCookies(String url, {String? name}) =>
      _page.deleteCookies(url, name: name).timeout(limit);

  @override
  Future<WidgetBox?> widgetBox() =>
      _page.widgetBox().timeout(limit, onTimeout: () => null);

  @override
  Future<PageGlance?> glance() =>
      _page.glance().timeout(limit, onTimeout: () => null);

  @override
  Future<List<StoredCookie>> cookies(String url) =>
      _page.cookies(url).timeout(limit);

  @override
  Future<String> userAgent() => _page.userAgent().timeout(limit);

  /// The page's own fetch waits up to 20 s for its answer.
  @override
  Future<InPageResponse> fetch(InPageRequest request) =>
      _page.fetch(request).timeout(limit * 3);

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    onClosed();
    try {
      await _page.dispose().timeout(limit);
    } catch (_) {
      // A page that won't close is let go of.
    }
  }
}

class _KeptPage {
  _KeptPage(this.page);

  final CheckPage page;
  Timer? idle;

  /// Requests being sent from it.
  int busy = 0;
}
