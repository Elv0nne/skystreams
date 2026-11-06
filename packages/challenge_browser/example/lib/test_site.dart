import 'dart:convert';
import 'dart:io';

/// A small site on 127.0.0.1 for exercising a page: two servers, so there are two origins.
///
/// | Path | |
/// |---|---|
/// | `/` | Sets `plain=1` and `secret=2; HttpOnly`. Has a link, an input and a button, for focus order |
/// | `/echo` | Echoes the method, the body and the `Cookie` header, as text |
/// | `/language` | A page titled with the language it was asked for (`Accept-Language`) |
/// | `/media` | Fetches `/video/master.m3u8` from script and sets a video's source |
/// | `/check` | A stand-in for a challenge: a checkbox in a frame from the other origin. Ticking it sets `clearance=ok; HttpOnly` and loads `/` |
/// | `/forbidden` | A page served with 403, as Cloudflare serves its check |
/// | `/turnstile?dir=ltr\|rtl` | Cloudflare's widget, where its interstitial puts it in a 1024×768 viewport: a 912×68 box at 56, 304 holding a `cf-turnstile-response` field and a frame from the other origin. The frame's 24×24 checkbox is 13 px in from its start edge, so a tap at 81, 338 (or 943, 338 right-to-left) ticks it. It counts only trusted clicks; then the field reads `tok` and the title `Ticked`. `window.boxReady` turns true once the frame has loaded |
class TestSite {
  TestSite._(this._main, this._other);

  final HttpServer _main;
  final HttpServer _other;

  static Future<TestSite> start() async {
    final main = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // dart:io refuses framing by default; the check's box is framed from the other origin.
    other.defaultResponseHeaders.remove('x-frame-options', 'SAMEORIGIN');
    final site = TestSite._(main, other);
    main.listen(site._serveMain);
    other.listen(site._serveOther);
    return site;
  }

  String get origin => 'http://127.0.0.1:${_main.port}';
  String get otherOrigin => 'http://127.0.0.1:${_other.port}';

  String url(String path) => '$origin$path';

  Future<void> close() async {
    await _main.close(force: true);
    await _other.close(force: true);
  }

  Future<void> _serveMain(HttpRequest request) async {
    final response = request.response;
    switch (request.uri.path) {
      case '/':
        response.cookies
          // dart:io makes cookies HttpOnly unless told otherwise.
          ..add(
            Cookie('plain', '1')
              ..path = '/'
              ..httpOnly = false,
          )
          ..add(
            Cookie('secret', '2')
              ..path = '/'
              ..httpOnly = true,
          );
        _html(
          response,
          'Home',
          '''
<p><a id="first" href="/check">Check</a></p>
<p><input id="field" placeholder="Field"></p>
<p><button id="last" onclick="this.textContent='Pressed'">Button</button></p>''',
        );
      case '/echo':
        final body = await utf8.decodeStream(request);
        response.headers.contentType = ContentType.text;
        response.write(
          '${request.method} $body\ncookie: ${request.headers.value('cookie') ?? ''}',
        );
      case '/language':
        _html(
          response,
          const HtmlEscape().convert(
            request.headers.value('accept-language') ?? '',
          ),
          '',
        );
      case '/media':
        _html(response, 'Media', '''
<video id="video" muted></video>
<script>
  fetch("/video/master.m3u8").then(function(r){ return r.text(); }).then(function(){
    document.getElementById("video").src = "/video/clip.mp4";
  });
</script>''');
      case '/video/master.m3u8':
        response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
        response.write('#EXTM3U\n#EXT-X-ENDLIST\n');
      case '/check':
        _html(response, 'Check', '''
<p>A quick check before the site loads.</p>
<iframe id="box" src="$otherOrigin/box?parent=${Uri.encodeComponent(origin)}" width="320" height="90"></iframe>
<script>
  window.addEventListener("message", function(e){
    if (e.origin !== "$otherOrigin" || e.data !== "ticked") return;
    fetch("/clear", {method: "POST"}).then(function(){ location.href = "/"; });
  });
</script>''');
      case '/redirect':
        // A sign-in finishing straight away: the provider sends the browser to the app's redirect.
        response.statusCode = HttpStatus.found;
        response.headers.set(
          HttpHeaders.locationHeader,
          request.uri.queryParameters['to']!,
        );
      case '/authorize':
        // A sign-in page: its form posts, and the answer redirects (as MyAnimeList's and AniList's do).
        final to = Uri.encodeQueryComponent(request.uri.queryParameters['to']!);
        _html(response, 'Sign in', '''
<form id="login" method="post" action="/login?to=$to"><input name="user" value="person"></form>
<script>document.getElementById("login").submit();</script>''');
      case '/login':
        await request.drain<void>();
        response.statusCode = HttpStatus.found;
        response.headers.set(
          HttpHeaders.locationHeader,
          request.uri.queryParameters['to']!,
        );
      case '/turnstile':
        final dir = request.uri.queryParameters['dir'] == 'rtl' ? 'rtl' : 'ltr';
        final box =
            '$otherOrigin/turnstile-box?dir=$dir&parent=${Uri.encodeComponent(origin)}';
        _html(response, 'Widget', '''
<style>
  body { margin: 0; }
  #widget { position: absolute; left: 56px; top: 304px; width: 912px; height: 68px; }
  #widget iframe { border: 0; width: 100%; height: 100%; display: block; }
</style>
<div id="widget" dir="$dir"><input type="hidden" name="cf-turnstile-response" value=""><iframe src="$box"></iframe></div>
<script>
  window.addEventListener("message", function(e){
    if (e.origin !== "$otherOrigin") return;
    if (e.data === "ready") window.boxReady = true;
    if (e.data === "ticked") {
      document.querySelector('input[name="cf-turnstile-response"]').value = "tok";
      document.title = "Ticked";
    }
  });
</script>''');
      case '/forbidden':
        response.statusCode = HttpStatus.forbidden;
        _html(response, 'Just a moment...', '<p>Checking your browser.</p>');
      case '/clear':
        response.cookies.add(
          Cookie('clearance', 'ok')
            ..path = '/'
            ..httpOnly = true,
        );
        response.write('ok');
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  /// Requests that reached the other origin's `/callback`: a stopped navigation sends none.
  int callbackHits = 0;

  Future<void> _serveOther(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path == '/callback') {
      callbackHits++;
      _html(response, 'Callback', '<p>Signed in.</p>');
    } else if (request.uri.path == '/turnstile-box') {
      final parent = request.uri.queryParameters['parent'] ?? '*';
      final dir = request.uri.queryParameters['dir'] == 'rtl' ? 'rtl' : 'ltr';
      final side = dir == 'rtl' ? 'right' : 'left';
      _html(response, 'Box', '''
<style>
  body { margin: 0; height: 68px; position: relative; }
  #tick { position: absolute; top: 22px; $side: 13px; width: 24px; height: 24px; margin: 0; }
</style>
<input id="tick" type="checkbox">
<script>
  var tick = document.getElementById("tick");
  // A person's click only: a script's click() is not trusted.
  tick.addEventListener("click", function(e){
    if (e.isTrusted) parent.postMessage("ticked", ${jsonEncode(parent)});
  });
  window.addEventListener("message", function(e){ if (e.data === "synthetic") tick.click(); });
  parent.postMessage("ready", ${jsonEncode(parent)});
</script>''', dir: dir);
    } else if (request.uri.path == '/box') {
      final parent = request.uri.queryParameters['parent'] ?? '*';
      _html(response, 'Box', '''
<label><input id="tick" type="checkbox"> I am a person</label>
<script>
  document.getElementById("tick").addEventListener("change", function(){
    if (this.checked) parent.postMessage("ticked", ${jsonEncode(parent)});
  });
</script>''');
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  static void _html(
    HttpResponse response,
    String title,
    String body, {
    String? dir,
  }) {
    response.headers.contentType = ContentType.html;
    response.write(
      '<!doctype html><html${dir == null ? '' : ' dir="$dir"'}><head><meta charset="utf-8"><title>$title</title>'
      '<meta name="viewport" content="width=device-width, initial-scale=1"></head><body>$body</body></html>',
    );
  }
}
