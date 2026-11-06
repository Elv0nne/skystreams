import 'dart:convert';
import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Loads each site in a hidden page and records what its bot check did: nothing, cleared by itself,
/// or waits for a person. For each Cloudflare clearance, also tries the cookie outside the page,
/// with dart:io (what Dio uses): as it is, without it, under another agent, and on another site.
/// Prints one `SITE {json}` line per site.
///
/// It reaches real sites, so it runs only when asked: `--dart-define=LIVE=true`.
/// `--dart-define=SITES=https://a/,https://b/` replaces the list below; `--dart-define=SHOW=true` shows
/// each page in the window instead of keeping it hidden.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live sites', skip: !const bool.fromEnvironment('LIVE'), (tester) async {
    const fromDefine = String.fromEnvironment('SITES');
    final sites = fromDefine.isEmpty ? _sites : fromDefine.split(',');
    debugPrint('SITES-START ${sites.length} overrides=${HttpOverrides.current}');
    (String, String)? previous;
    for (final url in sites) {
      final result = await _check(tester, url, previous);
      if (result['clearance'] case final String clearance) previous = (url, clearance);
      debugPrint('SITE ${jsonEncode(result)}');
    }
    debugPrint('SITES-END');
  }, timeout: const Timeout(Duration(minutes: 45)));
}

const _sites = [
  // CloudStream extensions whose sites challenged a plain client.
  'https://gat.animerco.org/',
  'https://1jour1film0426c.site/',
  'https://french-anime.com/',
  'https://movielinkbd.shop/',
  'https://movielinkbd.tv/',
  'https://web31018x.faselhdx.bid/',
  'https://moflix-stream.xyz/',
  'https://w1.anime4up.rest/',
  'https://animesdrive.online/',
  // Public sites behind Cloudflare's challenge.
  'https://www.scrapingcourse.com/cloudflare-challenge',
  'https://nopecha.com/demo/cloudflare',
  'https://gitlab.com/users/sign_in',
  'https://www.indeed.com/',
  'https://chatgpt.com/',
  'https://www.crunchyroll.com/',
  'https://www.patreon.com/login',
  // Turnstile widgets in a page.
  'https://demo.turnstile.workers.dev/',
  'https://seleniumbase.io/apps/turnstile',
  'https://2captcha.com/demo/cloudflare-turnstile',
  'https://nowsecure.nl/',
  // Other vendors.
  'https://www.google.com/recaptcha/api2/demo',
  'https://accounts.hcaptcha.com/demo',
  'https://antoinevastel.com/bots/datadome',
  'https://www.g2.com/',
];

/// While a check runs, only what can't disturb it. Cloudflare's challenge watches its page: a script
/// that looks up its elements or its token field makes it issue a clearance it won't honour, then
/// retry in a loop. The title, the address and the cookies (read natively) are safe.
const _glance = '''
(function(){
  if (!window.__cbF) { window.__cbF = Date.now(); window.__cbFrames = 0;
    (function f(){ window.__cbFrames++; requestAnimationFrame(f); })(); }
  return [document.title, location.href, document.readyState,
    Math.round(window.__cbFrames * 1000 / Math.max(1, Date.now() - window.__cbF))];
})()''';

/// Once the check is over, cleared or given up on: what the page holds.
const _inspect = '''
(function(){
  function q(s){ return document.querySelector(s); }
  function v(s){ var e = q(s); return e ? (e.value || '') : null; }
  var body = document.body ? document.body.innerText || '' : '';
  return {
    blockedText: /sorry, you have been blocked/i.test(body),
    datadome: !!q('iframe[src*="captcha-delivery.com"]'),
    turnstile: !!q('.cf-turnstile, iframe[src*="challenges.cloudflare.com"], [name="cf-turnstile-response"]'),
    turnstileToken: (v('[name="cf-turnstile-response"]') || '').length,
    recaptcha: !!q('.g-recaptcha, iframe[src*="/recaptcha/"]'),
    recaptchaToken: (v('textarea[name="g-recaptcha-response"]') || '').length,
    hcaptcha: !!q('.h-captcha, iframe[src*="hcaptcha.com"]'),
    hcaptchaToken: (v('textarea[name="h-captcha-response"]') || '').length,
    text: body.replace(/\\s+/g, ' ').slice(0, 90)
  };
})()''';

/// Interstitial titles: Cloudflare's challenge, DDoS-Guard, and similar.
final _checkTitle = RegExp(r'^just a moment|ddos-guard|^security check|^checking your browser', caseSensitive: false);
final _blockTitle = RegExp(r'^attention required', caseSensitive: false);

Future<Map<String, Object?>> _check(WidgetTester tester, String url, (String, String)? previous) async {
  final out = <String, Object?>{'url': url};
  final browser = await ChallengeBrowser.create();
  const show = bool.fromEnvironment('SHOW');
  if (show) {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChallengeBrowserView(browser: browser)),
      ),
    );
  }
  final started = DateTime.now();
  double seconds() => DateTime.now().difference(started).inMilliseconds / 1000;
  var finished = false;
  var loads = 0;
  String? error;
  final events = browser.events.listen((event) {
    if (event is PageStarted) loads++;
    if (event is PageFinished) finished = true;
    if (event is PageError && event.mainFrame) error = '${event.code} ${event.text}';
  });
  try {
    await browser.load(url);
    var title = '', ready = '';
    int? fps;
    var names = <String>[];
    double? challengeAt, clearedAt, finishedAt;
    // Interstitials get 30 s to clear; other pages 15 s after they finish, for a widget to issue its
    // token by itself.
    while (seconds() < 30) {
      await tester.pump(const Duration(milliseconds: 500));
      try {
        final glance = jsonDecode(await browser.evaluate(_glance)) as List;
        title = glance[0] as String;
        ready = glance[2] as String;
        fps = glance[3] as int;
      } catch (_) {
        continue; // between documents
      }
      names = [for (final c in await browser.cookies(url)) c.name];
      final challenged = _checkTitle.hasMatch(title);
      if (challenged) challengeAt ??= seconds();
      if (challengeAt != null && !challenged && ready == 'complete') clearedAt ??= seconds();
      if (finished) finishedAt ??= seconds();
      if (error != null && challengeAt == null) break;
      if (clearedAt != null && seconds() - clearedAt > 1.5) break;
      if (_blockTitle.hasMatch(title) && seconds() > 5) break;
      if (challengeAt == null && finishedAt != null && seconds() - finishedAt > 15) break;
    }
    final state = jsonDecode(await browser.evaluate(_inspect)) as Map<String, dynamic>;
    final cookies = await browser.cookies(url);
    final clearance = cookies.where((c) => c.name == 'cf_clearance').firstOrNull;
    final widget = state['turnstile'] == true || state['recaptcha'] == true || state['hcaptcha'] == true;
    final token = (state['turnstileToken'] as int) + (state['recaptchaToken'] as int) + (state['hcaptchaToken'] as int);
    out['outcome'] = error != null && challengeAt == null
        ? 'error'
        : _blockTitle.hasMatch(title) || state['blockedText'] == true
        ? 'blocked'
        : _checkTitle.hasMatch(title) || state['datadome'] == true
        ? 'waiting'
        : clearedAt != null
        ? 'cleared'
        : widget && token > 0
        ? 'token'
        : widget
        ? 'widget-no-token'
        : 'no-check';
    out.addAll({
      'challengeAt': challengeAt,
      'clearedAt': clearedAt,
      'loads': loads,
      'error': error,
      'title': title.length > 70 ? title.substring(0, 70) : title,
      'text': state['text'],
      'fps': fps,
      'shown': show,
      'cookies': [for (final c in cookies) c.name],
      'retries': names.where((n) => n.startsWith('cf_chl_rc')).toList(),
      if (clearance != null) ...{
        'clearanceDomain': clearance.domain,
        'clearanceMinutes': clearance.expires?.difference(DateTime.now()).inMinutes,
      },
    });
    final agent = await browser.userAgent;
    out['agent'] = agent;
    if (clearance != null) {
      final cookieHeader = [for (final c in cookies) '${c.name}=${c.value}'].join('; ');
      out['clearance'] = 'cf_clearance=${clearance.value}';
      out['cookieHeader'] = cookieHeader;
      final other = agent.contains('Windows')
          ? 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15'
          : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';
      // Another site's clearance goes first, before this site has seen a good request from outside.
      out['replay'] = {
        'noCookie': await _fetch(url, agent: agent),
        if (previous != null) 'previousSiteCookie': await _fetch(url, agent: agent, cookie: previous.$2),
        'withCookie': await _fetch(url, agent: agent, cookie: cookieHeader),
        'clearanceOnly': await _fetch(url, agent: agent, cookie: 'cf_clearance=${clearance.value}'),
        'otherAgent': await _fetch(url, agent: other, cookie: cookieHeader),
        'noCookieAgain': await _fetch(url, agent: agent),
        'inPage': await _inPage(browser, url),
      };
    }
  } finally {
    await events.cancel();
    if (show) await tester.pumpWidget(const SizedBox());
    await browser.dispose();
  }
  out['seconds'] = seconds();
  return out;
}

/// A request from outside the page: status, and whether Cloudflare answered with a challenge.
Future<String> _fetch(String url, {required String agent, String? cookie}) async {
  final client = HttpClient()..userAgent = agent;
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers
      ..set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8')
      ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    if (cookie != null) request.headers.set(HttpHeaders.cookieHeader, cookie);
    final response = await request.close().timeout(const Duration(seconds: 20));
    final body = await response.transform(const Utf8Decoder(allowMalformed: true)).join();
    final challenged = response.headers.value('cf-mitigated') == 'challenge' || body.contains('_cf_chl_opt');
    return '${response.statusCode}${challenged ? ' challenge' : ''}';
  } catch (e) {
    return 'failed ${e.runtimeType}';
  } finally {
    client.close(force: true);
  }
}

Future<String> _inPage(ChallengeBrowser browser, String url) async {
  try {
    final reply = await browser.fetchInPage(InPageRequest(url));
    return '${reply.status}${reply.body.contains('_cf_chl_opt') ? ' challenge' : ''}';
  } catch (e) {
    return 'failed $e';
  }
}
