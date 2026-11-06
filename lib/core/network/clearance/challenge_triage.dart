/// Who runs a site's bot check, from what a page shows.
enum CheckVendor {
  /// Cloudflare's challenge: the only one with a checkbox SkyStream taps.
  cloudflare,
  ddosGuard,

  /// Anubis' proof of work, which clears by itself.
  anubis,

  /// AWS WAF's challenge (IMDb's), which clears by itself.
  awsWaf,

  /// Vercel's Security Checkpoint, which clears by itself in the browser
  /// only: its cookie is no use outside it.
  vercel,

  /// HostAdmin's proof of work, which clears by itself.
  hostAdmin,

  /// A check SkyStream knows only by its title ("Checking your browser").
  other,
}

/// What a response says about a site's bot check.
enum Triage {
  /// No check: the site answered.
  none,

  /// A check a browser can clear: Cloudflare's challenge, or DDoS-Guard's.
  challenge,

  /// A block page: no check clears it (Cloudflare's "Sorry, you have been
  /// blocked", a firewall rule, a country ban).
  block,

  /// A Cloudflare 403 or 503 whose headers don't tell a challenge from a
  /// block or the site's own error: the body decides ([triageBody]).
  unsure,
}

/// Whether a cookie named [name] is a bot check's own: what Cloudflare's or
/// DDoS-Guard's check leaves. A site's other cookies in the app's browser (a
/// person's sign-in, say) are not a check's.
bool isCheckCookie(String name) =>
    name == 'cf_clearance' ||
    name == '_cfuvid' ||
    name.startsWith('__cf') ||
    name.startsWith('cf_chl') ||
    name.startsWith('cf_ob') ||
    name.startsWith('__ddg') ||
    name == 'aws-waf-token' ||
    name == '_vcrcs' ||
    name.contains('anubis-auth') ||
    name.startsWith('ha-waf-');

/// Classifies a response from its status and headers alone, which is all a
/// streamed response offers before its body is read.
///
/// [header] returns a header's value, or null.
Triage triageHeaders(int status, String? Function(String name) header) {
  if (header('cf-mitigated')?.toLowerCase() == 'challenge') {
    return Triage.challenge;
  }
  // AWS WAF (IMDb's, a 202) and Vercel (a 429) say so in headers of their own.
  if (header('x-amzn-waf-action')?.toLowerCase() == 'challenge' ||
      header('x-vercel-mitigated')?.toLowerCase() == 'challenge') {
    return Triage.challenge;
  }
  final server = header('server')?.toLowerCase() ?? '';
  if (server.contains('ddos-guard') && (status == 403 || status == 503)) {
    return Triage.unsure;
  }
  if (!server.contains('cloudflare')) return Triage.none;
  if (status == 403 || status == 503 || status == 429) return Triage.unsure;
  return Triage.none;
}

/// Settles an [Triage.unsure] response from the start of its body.
///
/// Block pages go first: Cloudflare puts its bot-detection script
/// (`/cdn-cgi/challenge-platform/scripts/jsd/`) in block pages and ordinary
/// ones alike, so only the challenge's own script (`.../h/`) counts.
Triage triageBody(String body) {
  if (body.contains('Attention Required! | Cloudflare') ||
      body.contains('Sorry, you have been blocked') ||
      body.contains('cf-error-details')) {
    return Triage.block;
  }
  if (body.contains('_cf_chl_opt') ||
      body.contains('/cdn-cgi/challenge-platform/h/') ||
      body.contains('<title>Just a moment...</title>') ||
      (body.contains('ddos-guard') && body.contains('check.ddos-guard.net'))) {
    return Triage.challenge;
  }
  return Triage.none;
}

/// A 200 page that is a check all the same: Anubis' (its assets live under
/// `/.within.website/`) or HostAdmin's ("Verification..." with its own
/// `ha-waf-` cookie). [header] returns a header's value, or null.
///
/// Only bodies already read: a check like these is a small page.
Triage triagePage(
  int status,
  String? Function(String name) header,
  String body,
) {
  if (status != 200) return Triage.none;
  final type = header('content-type')?.toLowerCase();
  if (type != null && !type.contains('html')) return Triage.none;
  if (body.contains('/.within.website/')) return Triage.challenge;
  if (body.contains('<title>Verification...</title>') &&
      (header('set-cookie') ?? '').contains('ha-waf-')) {
    return Triage.challenge;
  }
  return Triage.none;
}

/// Cloudflare's interstitial titles ("Just a moment...", translated by the
/// browser's language).
final cloudflareTitle = RegExp(
  r'^(just a moment|un instant|einen moment|un momento|um momento|'
  r'een ogenblik|chwileczkę|один момент|bir dakika|しばらくお待ちください|'
  r'请稍候|請稍候|잠시만 기다리십시오|performing security verification)',
  caseSensitive: false,
);

final _ddosGuardTitle = RegExp(r'ddos-guard', caseSensitive: false);
final _anubisTitle = RegExp(
  r"^(making sure you('|’|&#39;)re not a bot|проверяем, что вы не бот)",
  caseSensitive: false,
);
final _vercelTitle = RegExp(
  r'^vercel security checkpoint',
  caseSensitive: false,
);
final _hostAdminTitle = RegExp(r'^verification\.\.\.$', caseSensitive: false);
final _otherTitle = RegExp(
  r'^(checking your browser|security check)',
  caseSensitive: false,
);

/// The vendor whose check a page's [title] is, if any.
CheckVendor? vendorOfTitle(String title) {
  if (cloudflareTitle.hasMatch(title)) return CheckVendor.cloudflare;
  if (_ddosGuardTitle.hasMatch(title)) return CheckVendor.ddosGuard;
  if (_anubisTitle.hasMatch(title)) return CheckVendor.anubis;
  if (_vercelTitle.hasMatch(title)) return CheckVendor.vercel;
  if (_hostAdminTitle.hasMatch(title)) return CheckVendor.hostAdmin;
  if (_otherTitle.hasMatch(title)) return CheckVendor.other;
  return null;
}

/// Interstitial titles while a check runs, any vendor's.
final checkTitle = RegExp(
  '${cloudflareTitle.pattern}|${_ddosGuardTitle.pattern}|'
  '${_anubisTitle.pattern}|${_vercelTitle.pattern}|'
  '${_hostAdminTitle.pattern}|${_otherTitle.pattern}',
  caseSensitive: false,
);

/// Cloudflare's block page title.
final blockTitle = RegExp(r'^attention required', caseSensitive: false);
