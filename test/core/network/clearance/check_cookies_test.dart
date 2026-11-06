import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/challenge_triage.dart';

/// A bot check's own cookies, told from the site's.
void main() {
  test(
    "AWS WAF's, Vercel's, Anubis's and HostAdmin's cookies are a check's",
    () {
      for (final name in [
        'aws-waf-token',
        '_vcrcs',
        'techaro.lol-anubis-auth-347ddb4a',
        'within.website-x-cmd-anubis-auth',
        'ha-waf-ticket',
        'ha-waf-hash',
      ]) {
        expect(isCheckCookie(name), isTrue, reason: name);
      }
    },
  );

  test('Cloudflare\'s and DDoS-Guard\'s cookies are a check\'s', () {
    for (final name in [
      'cf_clearance',
      '__cf_bm',
      '__cflb',
      '__cfruid',
      '_cfuvid',
      'cf_chl_rc_m',
      'cf_ob_info',
      '__ddg1_',
      '__ddgid_',
      '__ddgmark_',
    ]) {
      expect(isCheckCookie(name), isTrue, reason: name);
    }
  });

  test('a site\'s own cookies are not', () {
    for (final name in [
      'sessionid',
      'PHPSESSID',
      'MALSESSIONID',
      'cf_session',
      'token',
    ]) {
      expect(isCheckCookie(name), isFalse, reason: name);
    }
  });
}
