/// A site behind a stand-in for Cloudflare's bot check, on 127.0.0.1, for the device tests of
/// Nuvio scrapers' and Stremio add-ons' checks: the app's browser clears it as it clears
/// Cloudflare's, with no live site involved.
///
/// - Every path but the ones below answers a request without the clearance cookie with
///   Cloudflare's challenge (403, `cf-mitigated: challenge`, "Just a moment..."). The page's
///   script fetches `/solve`, which sets `cf_clearance`, bound to the browser's agent as
///   Cloudflare's is, and goes back.
/// - With the cookie, and the agent it was issued to: `/` is a page, `/api/streams` a
///   Nuvio-style stream list, `/addon/...` a Stremio add-on.
/// - `/plain/...`: the same, but refused with a bare 403 a client can't tell from a check
///   (for scrapers that call `Cloudflare.solve` themselves).
/// - `/blocked/...`: Cloudflare's block page, which no check clears.
/// - `/nuvio/manifest.json` and its scrapers' code are open.
/// - With [FakeCloudflare.tapToClear], the challenge doesn't pass by itself: it shows Turnstile's
///   widget where Cloudflare's interstitial puts it in a 1024×768 viewport (a 912×68 box at 56, 304,
///   with a `cf-turnstile-response` field and a frame), whose checkbox, 13 px in from its start edge,
///   counts only a trusted click. A right-to-left Accept-Language mirrors it, as Cloudflare does.
library;

import 'dart:convert';
import 'dart:io';

class FakeCloudflare {
  FakeCloudflare._(this._server);

  final HttpServer _server;

  /// Rotated by [rotate]: cookies issued before stop clearing.
  var _secret = 0;

  /// Challenges served, and checks passed (`/solve`).
  var challenges = 0;
  var solves = 0;

  /// How long the challenge page takes to pass, as Cloudflare's does on a slow device.
  var checkTakes = const Duration(milliseconds: 500);

  /// The challenge passes only when its checkbox is ticked by a trusted click.
  var tapToClear = false;

  /// With [tapToClear], the widget is laid out as on a phone (across the page, near its top) and
  /// its checkbox sits at its far end, where no automatic tap lands: only a person ticks it (a
  /// D-pad's OK, a tap), on any screen.
  var tapMisses = false;

  static Future<FakeCloudflare> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final site = FakeCloudflare._(server);
    server.listen(site._serve);
    return site;
  }

  String get origin => 'http://127.0.0.1:${_server.port}';

  /// The next requests meet a new check: cookies issued so far stop clearing.
  void rotate() => _secret++;

  Future<void> close() => _server.close(force: true);

  String _tokenFor(String agent) =>
      '${_secret}x${agent.hashCode.toRadixString(16)}';

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    final agent = request.headers.value('user-agent') ?? '';
    final token = request.cookies
        .where((c) => c.name == 'cf_clearance')
        .firstOrNull
        ?.value;
    final cleared = token != null && token == _tokenFor(agent);
    try {
      if (path == '/solve') {
        solves++;
        response.cookies.add(
          Cookie('cf_clearance', _tokenFor(agent))
            ..path = '/'
            ..httpOnly = false,
        );
        response.statusCode = 302;
        response.headers.set(
          'location',
          request.uri.queryParameters['to'] ?? '/',
        );
        return;
      }
      if (path == '/widget-box') {
        final rtl = request.uri.queryParameters['dir'] == 'rtl';
        response.headers.contentType = ContentType.html;
        response.write(
          _widgetBox(
            rtl: rtl,
            to: request.uri.queryParameters['to'] ?? '/',
            atEnd: tapMisses,
          ),
        );
        return;
      }
      if (path == '/nuvio/manifest.json') {
        return _json(response, _nuvioManifest);
      }
      if (path.startsWith('/nuvio/')) {
        response.headers.contentType = ContentType('application', 'javascript');
        response.write(_scraper(path.substring('/nuvio/'.length)));
        return;
      }
      if (path.startsWith('/blocked/')) {
        response.statusCode = 403;
        response.headers.set('server', 'cloudflare');
        response.headers.contentType = ContentType.html;
        response.write(
          '<html><head><title>Attention Required! | Cloudflare</title></head>'
          '<body>Sorry, you have been blocked</body></html>',
        );
        return;
      }
      final plain = path.startsWith('/plain/');
      if (!cleared) {
        if (plain && !_acceptsHtml(request)) {
          // Refused, with nothing that says it's a check.
          response.statusCode = 403;
          response.write('denied');
          return;
        }
        challenges++;
        response.statusCode = 403;
        response.headers.set('cf-mitigated', 'challenge');
        response.headers.set('server', 'cloudflare');
        response.headers.contentType = ContentType.html;
        response.write(
          tapToClear
              ? _widgetPage(
                  rtl: _rightToLeft(request),
                  phone: tapMisses,
                  to: '${request.uri.path}${request.uri.hasQuery ? '?${request.uri.query}' : ''}',
                )
              : _challengePage(checkTakes),
        );
        return;
      }
      final rest = plain ? path.substring('/plain'.length) : path;
      if (rest == '/api/streams') {
        return _json(response, {
          'streams': [
            {
              'name': 'Fake',
              'title': 'Fake 1080p',
              'url': '$origin/video.mp4',
              'quality': '1080p',
            },
          ],
        });
      }
      if (rest == '/addon/manifest.json') {
        return _json(response, {
          'id': 'test.fakecf',
          'name': 'Fake CF',
          'version': '1.0.0',
          'resources': ['stream'],
          'types': ['movie'],
          'catalogs': <Object>[],
        });
      }
      if (rest.startsWith('/addon/stream/')) {
        return _json(response, {
          'streams': [
            {
              'name': 'Fake CF',
              'title': 'Fake 1080p',
              'url': '$origin/video.mp4',
            },
          ],
        });
      }
      response.headers.contentType = ContentType.html;
      response.write(
        '<html><head><title>Fake site</title></head><body>ok</body></html>',
      );
    } finally {
      await response.close();
    }
  }

  static bool _rightToLeft(HttpRequest request) => RegExp(
    r'^(ar|fa|he|iw)\b',
    caseSensitive: false,
  ).hasMatch(request.headers.value('accept-language') ?? '');

  /// Cloudflare's interstitial with the widget waiting for its checkbox, at the place Cloudflare
  /// puts it in a 1024×768 viewport.
  static String _widgetPage({
    required bool rtl,
    required String to,
    bool phone = false,
  }) {
    final dir = rtl ? 'rtl' : 'ltr';
    final box = '/widget-box?dir=$dir&to=${Uri.encodeQueryComponent(to)}';
    final place = phone
        ? 'left: 16px; right: 16px; top: 120px; max-width: 912px;'
        : 'left: 56px; top: 304px; width: 912px;';
    return '<html dir="$dir"><head><title>Just a moment...</title><style>'
        'body { margin: 0; }'
        '#widget { position: absolute; $place height: 68px; }'
        '#widget iframe { border: 0; width: 100%; height: 100%; display: block; }'
        '</style></head><body>'
        '<div id="widget"><input type="hidden" name="cf-turnstile-response" value="">'
        '<iframe src="${const HtmlEscape().convert(box)}"></iframe></div>'
        '<script>window._cf_chl_opt = {};</script></body></html>';
  }

  /// The widget's frame: its checkbox, 13 px from its start edge (its end edge when [atEnd]),
  /// passes the check on a trusted click only.
  static String _widgetBox({
    required bool rtl,
    required String to,
    bool atEnd = false,
  }) =>
      '<html><head><style>'
      'body { margin: 0; height: 68px; position: relative; }'
      '#tick { position: absolute; top: 22px; ${rtl != atEnd ? 'right' : 'left'}: 13px; width: 24px;'
      ' height: 24px; margin: 0; }'
      '</style></head><body><input id="tick" type="checkbox"><script>'
      'document.getElementById("tick").addEventListener("click", function (e) {'
      ' if (e.isTrusted) top.location.href = "/solve?to=" + encodeURIComponent(${jsonEncode(to)});'
      '});</script></body></html>';

  static bool _acceptsHtml(HttpRequest request) =>
      (request.headers.value('accept') ?? '').contains('text/html');

  void _json(HttpResponse response, Object body) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  }

  /// Cloudflare's interstitial, reduced to what matters: its title, its marker, and a script
  /// that passes the check by itself, as Cloudflare's usually does.
  static String _challengePage(Duration takes) =>
      '<html><head><title>Just a moment...</title></head><body>'
      '<script>window._cf_chl_opt = {};'
      'setTimeout(function () {'
      ' location.href = "/solve?to=" + encodeURIComponent(location.pathname + location.search);'
      '}, ${takes.inMilliseconds});</script></body></html>';

  Map<String, Object> get _nuvioManifest => {
    'name': 'Fake CF scrapers',
    'version': '1.0.0',
    'scrapers': [
      {
        'id': 'fakecf-auto',
        'name': 'Fake CF (automatic)',
        'version': '1.0.0',
        'filename': 'auto.js',
        'supportedTypes': ['movie', 'tv'],
        'enabled': true,
      },
      {
        'id': 'fakecf-solve',
        'name': 'Fake CF (Cloudflare.solve)',
        'version': '1.0.0',
        'filename': 'solve.js',
        'supportedTypes': ['movie', 'tv'],
        'enabled': true,
      },
      {
        'id': 'fakecf-timer',
        'name': 'Fake CF (own timeout)',
        'version': '1.0.0',
        'filename': 'timer.js',
        'supportedTypes': ['movie', 'tv'],
        'enabled': true,
      },
    ],
  };

  /// `auto.js` fetches the stream list and leaves the check to the app; `solve.js` meets a bare
  /// 403, asks `Cloudflare.solve`, and retries with what it gives, as yoruix's animekai does;
  /// `timer.js` gives its fetch 5 s of its own, as Streamline's scrapers give theirs 12-20 s.
  String _scraper(String name) => switch (name) {
    'auto.js' =>
      'var BASE = ${jsonEncode(origin)};\n'
          'async function getStreams(tmdbId, type) {\n'
          '  var r = await fetch(BASE + "/api/streams?id=" + tmdbId, {\n'
          '    headers: { "Accept": "application/json" } });\n'
          '  if (!r.ok) return [];\n'
          '  var j = await r.json();\n'
          '  return j.streams || [];\n'
          '}\n'
          'module.exports = { getStreams: getStreams };\n',
    'solve.js' =>
      'var BASE = ${jsonEncode(origin)};\n'
          'async function getStreams(tmdbId, type) {\n'
          '  var url = BASE + "/plain/api/streams?id=" + tmdbId;\n'
          '  var r = await fetch(url, { headers: { "Accept": "application/json" } });\n'
          '  if (r.status === 403 && typeof Cloudflare !== "undefined" && Cloudflare.solve) {\n'
          '    var solved = await Cloudflare.solve(url);\n'
          '    r = await fetch(url, { headers: {\n'
          '      "Accept": "application/json",\n'
          '      "Cookie": solved["Cookie"],\n'
          '      "User-Agent": solved["User-Agent"] } });\n'
          '  }\n'
          '  if (!r.ok) return [];\n'
          '  var j = await r.json();\n'
          '  return j.streams || [];\n'
          '}\n'
          'module.exports = { getStreams: getStreams };\n',
    'timer.js' =>
      'var BASE = ${jsonEncode(origin)};\n'
          'function withTimeout(promise, ms) {\n'
          '  return Promise.race([promise, new Promise(function (resolve) {\n'
          '    setTimeout(function () { resolve(null); }, ms); })]);\n'
          '}\n'
          'async function getStreams(tmdbId, type) {\n'
          '  var r = await withTimeout(fetch(BASE + "/api/streams?id=" + tmdbId, {\n'
          '    headers: { "Accept": "application/json" } }), 5000);\n'
          '  if (!r || !r.ok) return [];\n'
          '  var j = await r.json();\n'
          '  return j.streams || [];\n'
          '}\n'
          'module.exports = { getStreams: getStreams };\n',
    _ => '',
  };
}
