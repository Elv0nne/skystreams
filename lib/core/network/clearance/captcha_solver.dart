import 'dart:async';
import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';

import '../../logger/app_logger.dart';
import 'clearance_solver.dart';
import 'widget_tap.dart';

/// Which captcha a site key is for.
enum CaptchaKind { turnstile, hcaptcha, recaptcha }

/// Turnstile's: `0x4…`, or Cloudflare's test keys (`1x…`, `2x…`, `3x…`).
final _turnstileKey = RegExp(r'^(0x4[0-9A-Za-z_-]+|[123]x0{20}[0-9A-F]{2})$');
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _recaptchaKey = RegExp(r'^6L[0-9A-Za-z_-]{38}$');

/// [siteKey]'s captcha, by the keys' shapes: Turnstile's start `0x4` (its
/// test keys, `1x`–`3x`), hCaptcha's are UUIDs, and reCAPTCHA's are 40
/// characters starting `6L`. Null for any other.
CaptchaKind? captchaKindOf(String siteKey) {
  if (_turnstileKey.hasMatch(siteKey)) return CaptchaKind.turnstile;
  if (_uuid.hasMatch(siteKey)) return CaptchaKind.hcaptcha;
  if (_recaptchaKey.hasMatch(siteKey)) return CaptchaKind.recaptcha;
  return null;
}

/// Why no token came: [reason] is what the plugin is told.
class CaptchaException implements Exception {
  const CaptchaException(this.reason);

  final String reason;

  @override
  String toString() => 'CaptchaException: $reason';
}

/// Gets captcha tokens for plugins: their `solveCaptcha(siteKey, url)`.
abstract interface class Captchas {
  /// A token for [siteKey]'s captcha on [url]. With [personWaiting] (a title
  /// or its streams opening), a captcha the browser can't pass by itself is
  /// shown to the person. [source] is the plugin asking, for the site's row
  /// when a person is needed and none is there. Throws [CaptchaException].
  Future<String> solve({
    required String siteKey,
    required String url,
    required bool personWaiting,
    String? source,
  });
}

/// What a page needs to render and read one kind's widget.
class _Api {
  const _Api({
    required this.loader,
    required this.global,
    required this.widget,
    required this.response,
  });

  /// Its script, rendering explicitly and calling `__skyCaptchaLoaded`.
  final String loader;

  /// The global the script defines, with `render(element, options)`.
  final String global;

  /// A widget a page puts in its own markup.
  final String widget;

  /// The name of the field its token goes in.
  final String response;
}

_Api _apiOf(CaptchaKind kind) => switch (kind) {
  CaptchaKind.turnstile => const _Api(
    loader:
        'https://challenges.cloudflare.com/turnstile/v0/api.js'
        '?render=explicit&onload=__skyCaptchaLoaded',
    global: 'turnstile',
    widget: '.cf-turnstile',
    response: 'cf-turnstile-response',
  ),
  CaptchaKind.hcaptcha => const _Api(
    loader:
        'https://js.hcaptcha.com/1/api.js'
        '?render=explicit&onload=__skyCaptchaLoaded',
    global: 'hcaptcha',
    widget: '.h-captcha',
    response: 'h-captcha-response',
  ),
  // Not reCAPTCHA v3's badge, nor an invisible widget: no person can
  // answer those.
  CaptchaKind.recaptcha => const _Api(
    loader:
        'https://www.google.com/recaptcha/api.js'
        '?render=explicit&onload=__skyCaptchaLoaded',
    global: 'grecaptcha',
    widget: '.g-recaptcha:not([data-size="invisible"])',
    response: 'g-recaptcha-response',
  ),
};

/// Gets captcha tokens in hidden pages ([ClearanceSolver.borrowPage]).
///
/// Turnstile: the page's widget, or one rendered for the key, passes by
/// itself or after the solver's taps (section 1 of the Phase 4 design). With
/// a person waiting, one that still gives no token is shown to them, as are
/// hCaptcha and reCAPTCHA, which nothing passes by itself. With nobody
/// waiting, those fail, and their site's row asks for Verify.
class CaptchaSolver implements Captchas {
  CaptchaSolver(
    this._solver, {
    this.tokenWait = const Duration(seconds: 4),
    this.giveUpAfter = const Duration(seconds: 30),
    this.pollEvery = const Duration(milliseconds: 500),
  });

  final ClearanceSolver _solver;

  /// How long a Turnstile widget gets to answer by itself before its first
  /// tap: most do within a few seconds.
  final Duration tokenWait;

  /// A token that hasn't come by then won't, unless a person is shown it.
  final Duration giveUpAfter;
  final Duration pollEvery;

  @override
  Future<String> solve({
    required String siteKey,
    required String url,
    required bool personWaiting,
    String? source,
  }) async {
    final kind = captchaKindOf(siteKey);
    if (kind == null) {
      throw CaptchaException(
        'Not a Turnstile, hCaptcha or reCAPTCHA site key: "$siteKey"',
      );
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.isScheme('http') && !uri.isScheme('https') ||
        uri.host.isEmpty) {
      throw CaptchaException('Not a web address: "$url"');
    }
    final site = _solver.siteKeys.siteOf(uri.host);
    final askable = personWaiting && !_solver.store.isQuiet(site);
    if (kind != CaptchaKind.turnstile && !askable) {
      _solver.notePersonNeeded(site, url, source: source);
      throw CaptchaException(
        "$site's ${kind.name} needs a person: it's solved when a title "
        'or its streams open',
      );
    }
    final CheckPage page;
    try {
      page = await _solver.borrowPage();
    } catch (e) {
      throw CaptchaException('No page to solve it on: $e');
    }
    try {
      final deadline = DateTime.now().add(giveUpAfter);
      final api = _apiOf(kind);
      await page.load(url);
      await _settle(page, deadline);
      await _render(page, api, siteKey, deadline);
      if (kind != CaptchaKind.turnstile) {
        return await _byPerson(page, site, api);
      }
      final token = await _turnstile(page, api, askable, deadline);
      if (token != null) return token;
      if (askable) return await _byPerson(page, site, api);
      _solver.notePersonNeeded(site, url, source: source);
      throw CaptchaException('No Turnstile token from $site');
    } finally {
      await page.dispose();
    }
  }

  /// Waits for [page] to show its site, past any bot check of its own.
  Future<void> _settle(CheckPage page, DateTime deadline) async {
    while (true) {
      await Future<void>.delayed(pollEvery);
      final glance = await page.glance();
      if (glance != null && glance.onSite) {
        if (glance.blocked) {
          throw const CaptchaException('The site blocks the browser');
        }
        if (!glance.checking && glance.ready != 'loading') return;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw const CaptchaException(
          "The page didn't load, or its bot check didn't clear",
        );
      }
    }
  }

  /// Renders a widget for [siteKey], unless the page has its own.
  Future<void> _render(
    CheckPage page,
    _Api api,
    String siteKey,
    DateTime deadline,
  ) async {
    final has = await _read(
      page,
      "!!document.querySelector('${api.widget}, "
      "[name=\"${api.response}\"]')",
    );
    if (has == true) return;
    await _read(page, _renderScript(api, siteKey));
    while (true) {
      await Future<void>.delayed(pollEvery);
      final status = await _read(page, 'window.__skyCaptcha || null');
      if (status == 'rendered') return;
      if (status == 'failed' || DateTime.now().isAfter(deadline)) {
        // reCAPTCHA v3's keys, a mistyped key, or a page that refuses the
        // captcha's script.
        throw const CaptchaException('No widget renders for this key here');
      }
    }
  }

  /// Turnstile's token by itself, or after the solver's taps; null when none
  /// came: by then, with [askable], for the person to be asked, and by
  /// [deadline] otherwise.
  Future<String?> _turnstile(
    CheckPage page,
    _Api api,
    bool askable,
    DateTime deadline,
  ) async {
    final canTap = _solver.canTap;
    final tapEvery = _solver.tapEvery;
    final maxTaps = _solver.maxTaps;
    final tries = canTap ? tokenWait + tapEvery * maxTaps : tokenWait;
    final started = DateTime.now();
    var taps = 0;
    while (true) {
      await Future<void>.delayed(pollEvery);
      final token = await _token(page, api);
      if (token != null) return token;
      final elapsed = DateTime.now().difference(started);
      if (canTap && taps < maxTaps && elapsed >= tokenWait + tapEvery * taps) {
        if (await _tap(page)) taps++;
      }
      if (askable && elapsed >= tries) return null;
      if (DateTime.now().isAfter(deadline)) return null;
    }
  }

  /// Taps Turnstile's checkbox, where its widget is: read in an isolated
  /// world, or else by a script in the page, which an ordinary page's widget
  /// doesn't notice (the spike read Android's that way, 3 of 3). Whether it
  /// tapped.
  Future<bool> _tap(CheckPage page) async {
    final box = _solver.isolatedWorlds
        ? await page.widgetBox()
        : WidgetBox.fromJson(await _read(page, widgetBoxScript));
    if (box == null || box.answered) return false;
    final at = tapPoint(box);
    try {
      await page.tap(at.x, at.y);
      return true;
    } catch (e) {
      talker.debug('[Captcha] tap failed: $e');
      return false;
    }
  }

  /// Shows [page] to the person, in the check sheet: the token they earn.
  Future<String> _byPerson(CheckPage page, String site, _Api api) async {
    var watching = true;
    String? earned;
    final filled = () async {
      while (watching) {
        await Future<void>.delayed(pollEvery);
        if (!watching) return;
        final token = await _token(page, api);
        if (token != null) {
          earned = token;
          return;
        }
      }
    }();
    try {
      final left = await _solver.showSheet(
        page: page,
        site: site,
        cleared: filled,
      );
      if (left == null) {
        throw const CaptchaException('Nobody can be asked to solve it now');
      }
      if (left == ChallengeSheetResult.quiet) {
        _solver.store.setQuiet(site, true);
      }
      final token = earned ?? await _token(page, api);
      if (token == null) throw const CaptchaException('It was not solved');
      return token;
    } finally {
      watching = false;
    }
  }

  /// The token in [api]'s field, if it has one yet.
  Future<String?> _token(CheckPage page, _Api api) async {
    final value = await _read(page, '''
(function(){
  var fields = document.getElementsByName(${jsonEncode(api.response)});
  for (var i = 0; i < fields.length; i++) {
    var field = fields[i];
    if (field.value && !field.closest('.grecaptcha-badge')) return field.value;
  }
  return null;
})()''');
    return value is String && value.isNotEmpty ? value : null;
  }

  /// [script]'s result, or null when the page can't run it (it's between
  /// documents).
  Future<Object?> _read(CheckPage page, String script) async {
    try {
      return jsonDecode(await page.evaluate(script));
    } catch (_) {
      return null;
    }
  }
}

/// Renders [api]'s widget for [siteKey] at the page's top left, loading its
/// script unless the page has it; `window.__skyCaptcha` says how it went.
String _renderScript(_Api api, String siteKey) =>
    '''
(function(){
  if (window.__skyCaptcha) return window.__skyCaptcha;
  window.__skyCaptcha = 'loading';
  var box = document.createElement('div');
  box.style.cssText = 'position:fixed;left:16px;top:16px;z-index:2147483647';
  (document.body || document.documentElement).appendChild(box);
  function failed() { window.__skyCaptcha = 'failed'; }
  function render() {
    try {
      window.${api.global}.render(box, {
        sitekey: ${jsonEncode(siteKey)}, 'error-callback': failed
      });
      if (window.__skyCaptcha === 'loading') window.__skyCaptcha = 'rendered';
    } catch (e) { failed(); }
  }
  var loaded = window.${api.global};
  if (loaded && loaded.render) { render(); return window.__skyCaptcha; }
  window.__skyCaptchaLoaded = render;
  var script = document.createElement('script');
  script.src = ${jsonEncode(api.loader)};
  script.async = true;
  script.onerror = failed;
  (document.head || document.documentElement).appendChild(script);
  return window.__skyCaptcha;
})()''';
