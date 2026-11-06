import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'events.dart';
import 'messages.g.dart';

/// One page in the platform's own browser engine: Android System WebView, WKWebView (iOS, macOS),
/// WebView2 (Windows) or WebKitGTK (Linux). It is hidden until a `ChallengeBrowserView` shows it.
///
/// Create one for a job and [dispose] it as soon as the job is done: nothing is pre-warmed or
/// cached, so no browser runs while SkyStream is idle.
class ChallengeBrowser {
  ChallengeBrowser._(this.id, this._channel);

  static final PageHostApi _host = PageHostApi();
  static final Map<int, ChallengeBrowser> _pages = {};
  static bool _listening = false;

  /// Creates a page. It loads nothing until [load].
  static Future<ChallengeBrowser> create() async {
    if (!_listening) {
      PageFlutterApi.setUp(_Events());
      _listening = true;
    }
    // A fresh name per page: a fixed one would let a site recognise the plugin.
    final channel = _randomName();
    final id = await _host.create(channel);
    return _pages[id] = ChallengeBrowser._(id, channel);
  }

  final int id;
  final String _channel;
  final StreamController<BrowserEvent> _events = StreamController.broadcast();
  final Map<int, Completer<InPageResponse>> _fetches = {};
  int _nextFetch = 0;
  bool _captureObserved = false;
  bool _capturing = false;
  bool _disposed = false;

  /// Windows: the isolated world's execution context for the current document; null until made, and
  /// again after the page starts another.
  Future<int>? _isolatedContext;

  static Future<BrowserCapabilities>? _capabilities;

  /// What this platform's backend can do: asked once.
  static Future<BrowserCapabilities> capabilities() => _capabilities ??= _host.capabilities().then(
    (c) => BrowserCapabilities._(canTap: c.canTap, isolatedWorlds: c.isolatedWorlds),
  );

  @visibleForTesting
  static void debugResetCapabilities() => _capabilities = null;

  /// The engine's version where the app needs it: Android System WebView's version name; empty
  /// elsewhere.
  static Future<String> engineVersion() => _host.engineVersion();

  /// What the page reports, in order. Closed on [dispose].
  Stream<BrowserEvent> get events => _events.stream;

  bool get isDisposed => _disposed;

  /// Loads [url] with [headers] for its first request.
  ///
  /// Pages are in English on Windows and Linux, whose browsers take a language for every request.
  /// Android's and Apple's take one only per request, and a language sent with the first request
  /// alone made Cloudflare check again after every clearance (the page's own requests carry the
  /// device's), so there pages keep the device's language.
  Future<void> load(String url, {Map<String, String> headers = const {}}) => _host.load(id, url, headers);

  /// Runs [script] in the main frame and returns its result as JSON text: `"null"` for undefined.
  ///
  /// Throws a [TimeoutException] after [timeout]: an engine can fail to answer at all (Android's
  /// `evaluateJavascript` callback sometimes never fires while a page is busy or changing).
  Future<String> evaluate(String script, {Duration timeout = const Duration(seconds: 10)}) =>
      _host.evaluate(id, script).timeout(timeout);

  /// A tap or click at [x], [y] in CSS pixels from the page's top left, sent as the platform's own
  /// input: what a person's finger or mouse would send. The page needn't be shown or focused.
  /// Unsupported where [BrowserCapabilities.canTap] is false (iOS).
  Future<void> tap(double x, double y) => _host.tap(id, x, y);

  /// Runs [script] where the page's own scripts can't see it or what it changes, and returns its result
  /// as JSON text, as [evaluate] does. The DOM is shared; globals are not.
  ///
  /// Throws an [UnsupportedError] where [BrowserCapabilities.isolatedWorlds] is false (Android), and a
  /// [TimeoutException] after [timeout].
  Future<String> evaluateIsolated(String script, {Duration timeout = const Duration(seconds: 10)}) async {
    if (!(await capabilities()).isolatedWorlds) {
      throw UnsupportedError('This engine has no isolated world');
    }
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return _host.evaluateIsolated(id, script).timeout(timeout);
    }
    return _evaluateOverDevTools(script).timeout(timeout);
  }

  /// WebView2's isolated world, over its DevTools protocol: one per document.
  Future<String> _evaluateOverDevTools(String script) async {
    final context = _isolatedContext ??= _createIsolatedWorld();
    final int contextId;
    try {
      contextId = await context;
    } catch (_) {
      if (identical(_isolatedContext, context)) _isolatedContext = null;
      rethrow;
    }
    final reply = await _devTools('Runtime.evaluate', {
      'expression': script,
      'contextId': contextId,
      'returnByValue': true,
    });
    if (reply['exceptionDetails'] case final Map<String, dynamic> details) {
      throw StateError('Script failed: ${details['text'] ?? details}');
    }
    final result = reply['result'];
    return jsonEncode(result is Map<String, dynamic> ? result['value'] : null);
  }

  Future<int> _createIsolatedWorld() async {
    final tree = await _devTools('Page.getFrameTree', const {});
    final frameId = ((tree['frameTree'] as Map<String, dynamic>)['frame'] as Map<String, dynamic>)['id'] as String;
    final world = await _devTools('Page.createIsolatedWorld', {'frameId': frameId, 'worldName': 'skystream'});
    return world['executionContextId'] as int;
  }

  Future<Map<String, dynamic>> _devTools(String method, Map<String, Object?> params) async =>
      jsonDecode(await _host.devTools(id, method, jsonEncode(params))) as Map<String, dynamic>;

  /// Runs [script] in every frame of every later document, before the document's own scripts.
  Future<void> addDocumentStartScript(String script) => _host.addDocumentStartScript(id, script);

  /// JavaScript that posts its string argument to this page's [ScriptMessage] events:
  /// `${browser.postScript}('hello')`.
  String get postScript => switch (defaultTargetPlatform) {
    // WebViewCompat.addWebMessageListener puts an object of that name in every frame.
    TargetPlatform.android => 'function(m){$_channel.postMessage(m)}',
    // WebView2 has one channel per page.
    TargetPlatform.windows => 'function(m){window.chrome.webview.postMessage(m)}',
    // WKWebView and WebKitGTK name their script message handlers.
    _ => 'function(m){window.webkit.messageHandlers.$_channel.postMessage(m)}',
  };

  /// The cookies the engine would send to [url], HttpOnly ones included.
  Future<List<BrowserCookie>> cookies(String url) async => [
    for (final cookie in await _host.cookies(id, url)) BrowserCookie._(cookie),
  ];

  /// Stops the main frame from going to any URL that starts with one of [prefixes], redirects
  /// included, and reports each as a [NavigationStopped] event instead: how a sign-in catches its
  /// redirect before the page loads it. Replaces the previous prefixes; an empty list stops none.
  ///
  /// The match is plain text on the whole URL, fragment included, as the engine normalizes it (a
  /// path after the host: `http://localhost/#token`). End each prefix after the host with `/`, so
  /// `http://localhost/` can't match `http://localhost.example.com/`, and check the stopped URL's
  /// origin again before trusting it.
  Future<void> setNavigationStops(List<String> prefixes) => _host.setNavigationStops(id, prefixes);

  /// Deletes [url]'s cookie [name], or all of its cookies when [name] is null.
  Future<void> deleteCookies(String url, {String? name}) => _host.deleteCookies(id, url, name);

  /// The page's user agent: the engine's own, unless [setUserAgent] changed it.
  Future<String> get userAgent => _host.userAgent(id);

  /// Gives the page [agent] as its user agent: an extension's own page only. SkyStream's clearances never use it: a
  /// clearance holds only with the agent that earned it.
  Future<void> setUserAgent(String agent) => _host.setUserAgent(id, agent);

  /// Serves [folder], an absolute path, read-only under an address of this page's own, and returns that address's
  /// base, ending in `/`: `cbfolder://[name]/` on Apple platforms and Linux, `https://[name].example/` on Windows.
  /// [name] (lowercase letters, digits and hyphens) gives the same address every run, so what a page keeps there stays
  /// its own; nothing outside [folder] is served, nor to another page, and nothing is written. Unsupported on Android,
  /// whose WebView reads files itself (an extension's own pages, Phase 7c).
  Future<String> serveFolder(String name, String folder) => _host.serveFolder(id, name, folder);

  /// Holds each dialog the page opens (alert, confirm, prompt) while [hold], as a [PageDialog] event, until
  /// [answerDialog]: its scripts wait meanwhile, and the app keeps running; a page leaving asks no one. While not held,
  /// each engine does as it does: WKWebView answers at once, WebView2 and WebKitGTK show their own. Call it before
  /// [load]: WebView2 takes it as a document loads. Unsupported on Android, whose extension pages are the extension's
  /// own WebView (Phase 7c).
  Future<void> holdDialogs(bool hold) => _host.holdDialogs(id, hold);

  /// Answers held dialog [dialog] ([PageDialog.id]): an alert closes, a confirm answers [accept], a prompt [text] when
  /// [accept] and null otherwise. A dialog the page no longer waits for is ignored.
  Future<void> answerDialog(int dialog, {required bool accept, String? text}) =>
      _host.answerDialog(id, dialog, accept, text);

  /// The page's title as its engine has it, read without running anything in the page: it answers while the page waits
  /// in a held dialog, where [evaluate]'s `document.title` would wait with it (Phase 7c). Null before a document has
  /// one; WebView2 and Android's WebView name an untitled page by its address.
  Future<String?> title() => _host.title(id);

  /// Sends [request] from inside the page, with the page's cookies, network stack and TLS: the same
  /// origin as the page only. Text bodies only.
  Future<InPageResponse> fetchInPage(InPageRequest request, {Duration timeout = const Duration(seconds: 20)}) async {
    final token = _nextFetch++;
    final reply = _fetches[token] = Completer<InPageResponse>();
    // Disposing can fail it while the script is still being sent, before anyone awaits it.
    reply.future.ignore();
    try {
      // The deadline covers sending the script too.
      return await () async {
        await evaluate(_fetchScript(token, request), timeout: timeout);
        return reply.future;
      }().timeout(timeout);
    } finally {
      _fetches.remove(token);
    }
  }

  /// Reports the requests the page makes as [CapturedRequest] events while [enabled]. Only observes:
  /// nothing is blocked or changed.
  ///
  /// Android, Windows and Linux see every request. WebKit on iOS and macOS can't, so there the page's
  /// Resource Timing entries and media and frame sources are watched instead: whatever the page's own
  /// scripts can see, with no method.
  Future<void> setCapture(bool enabled) async {
    _capturing = enabled;
    if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS) {
      if (enabled && !_captureObserved) {
        _captureObserved = true;
        final observer = _captureScript(postScript);
        await addDocumentStartScript(observer);
        await evaluate(observer);
      }
      return;
    }
    await _host.setCapture(id, enabled);
  }

  /// Hides the page, ends it and releases its engine. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pages.remove(id);
    for (final fetch in _fetches.values) {
      fetch.completeError(StateError('The page was disposed'));
    }
    _fetches.clear();
    await _events.close();
    await _host.dispose(id);
  }

  void _receive(PageEvent event) {
    if (_disposed) return;
    // A new document: Windows' isolated world went with the old one.
    if (event.kind == PageEventKind.pageStarted) _isolatedContext = null;
    final BrowserEvent? out = switch (event.kind) {
      PageEventKind.pageStarted => PageStarted(Uri.parse(event.url ?? '')),
      PageEventKind.pageFinished => PageFinished(Uri.parse(event.url ?? '')),
      PageEventKind.pageError => PageError(
        url: Uri.tryParse(event.url ?? ''),
        code: event.code ?? 0,
        text: event.errorText ?? '',
        mainFrame: event.mainFrame ?? true,
      ),
      PageEventKind.progress => PageProgress(event.progress ?? 0),
      PageEventKind.rendererGone => RendererGone(crashed: event.crashed ?? false),
      PageEventKind.scriptMessage => _scriptMessage(event.message ?? ''),
      PageEventKind.captured => _capturing ? CapturedRequest(Uri.parse(event.url ?? ''), method: event.method) : null,
      PageEventKind.focusExit => FocusExit(event.direction ?? FocusDirection.forward),
      PageEventKind.focused => const PageFocused(),
      PageEventKind.blurred => const PageBlurred(),
      PageEventKind.navigationStopped => NavigationStopped(Uri.parse(event.url ?? '')),
      PageEventKind.dialog => PageDialog(
        id: event.dialogId ?? 0,
        kind: event.dialogKind ?? DialogKind.alert,
        message: event.message ?? '',
        defaultText: event.defaultText,
        url: event.url == null ? null : Uri.tryParse(event.url!),
      ),
    };
    if (out != null) _events.add(out);
  }

  /// The plugin's own messages (in-page replies and Apple's capture) are consumed here; the rest
  /// belong to the caller.
  BrowserEvent? _scriptMessage(String message) {
    if (!message.startsWith('{') || !message.contains('"$_marker"')) return ScriptMessage(message);
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(message) as Map<String, dynamic>;
    } on FormatException {
      return ScriptMessage(message);
    }
    switch (data[_marker]) {
      case 'fetch':
        final reply = _fetches[data['id']];
        if (reply == null || reply.isCompleted) return null;
        if (data['error'] != null) {
          reply.completeError(InPageFetchException(data['error'] as String));
        } else {
          reply.complete(
            InPageResponse(
              status: data['status'] as int,
              url: Uri.parse(data['url'] as String),
              headers: (data['headers'] as Map).cast<String, String>(),
              body: data['body'] as String,
            ),
          );
        }
        return null;
      case 'capture':
        return _capturing ? CapturedRequest(Uri.parse(data['url'] as String)) : null;
      default:
        return ScriptMessage(message);
    }
  }

  String _fetchScript(int token, InPageRequest request) {
    final init = jsonEncode({
      'method': request.method,
      'headers': request.headers,
      'body': request.body,
      'credentials': 'include',
      'redirect': 'follow',
    });
    return '''
(function(){
  var post = $postScript;
  function reply(o){ o["$_marker"] = "fetch"; o.id = $token; post(JSON.stringify(o)); }
  fetch(${jsonEncode(request.url)}, $init).then(function(r){
    var headers = {};
    r.headers.forEach(function(v, k){ headers[k] = v; });
    return r.text().then(function(body){ reply({status: r.status, url: r.url, headers: headers, body: body}); });
  }).catch(function(e){ reply({error: String(e)}); });
  return true;
})()''';
  }

  static String _randomName() {
    const letters = 'abcdefghijklmnopqrstuvwxyz';
    final random = Random.secure();
    return '_${List.generate(12, (_) => letters[random.nextInt(letters.length)]).join()}';
  }
}

/// What this platform's backend can do ([ChallengeBrowser.capabilities]).
@immutable
class BrowserCapabilities {
  const BrowserCapabilities._({required this.canTap, required this.isolatedWorlds});

  /// [ChallengeBrowser.tap] sends input: everywhere but iOS.
  final bool canTap;

  /// [ChallengeBrowser.evaluateIsolated] works: everywhere but Android.
  final bool isolatedWorlds;
}

/// Marks the plugin's own script messages.
const _marker = '__cbm';

/// Watches what the page's scripts can see of its requests: Resource Timing entries, and the
/// sources of media and frames as they are set. For WebKit on Apple platforms, which reports no
/// requests to the app.
String _captureScript(String post) =>
    '''
(function(){
  if (window.__cbmCapture) return;
  window.__cbmCapture = true;
  var post = $post, seen = {};
  function report(url){
    if (!url || seen[url] || !/^https?:/.test(url)) return;
    seen[url] = true;
    post(JSON.stringify({"$_marker": "capture", url: url}));
  }
  try {
    new PerformanceObserver(function(list){ list.getEntries().forEach(function(e){ report(e.name); }); })
      .observe({type: "resource", buffered: true});
  } catch (e) {}
  function scan(node){
    if (!node || !node.querySelectorAll) return;
    if (node.src) report(node.src);
    node.querySelectorAll("video, audio, source, iframe").forEach(function(e){ report(e.src); });
  }
  new MutationObserver(function(changes){
    changes.forEach(function(c){
      if (c.type === "attributes") report(c.target.src);
      c.addedNodes && c.addedNodes.forEach(scan);
    });
  }).observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ["src"]});
  if (document.documentElement) scan(document.documentElement);
})()''';

/// Routes events from the platform to their page.
class _Events implements PageFlutterApi {
  @override
  void onEvent(int pageId, PageEvent event) => ChallengeBrowser._pages[pageId]?._receive(event);
}

/// A cookie as the engine stores it.
@immutable
class BrowserCookie {
  BrowserCookie._(PageCookie cookie)
    : name = cookie.name,
      value = cookie.value,
      domain = cookie.domain,
      path = cookie.path,
      expires = cookie.expiresMs == null ? null : DateTime.fromMillisecondsSinceEpoch(cookie.expiresMs!),
      httpOnly = cookie.httpOnly,
      secure = cookie.secure;

  final String name;
  final String value;
  final String domain;
  final String path;

  /// Null for a session cookie.
  final DateTime? expires;
  final bool httpOnly;
  final bool secure;

  @override
  String toString() => '$name=$value (domain $domain, path $path${httpOnly ? ', HttpOnly' : ''})';
}

/// A request for [ChallengeBrowser.fetchInPage].
@immutable
class InPageRequest {
  const InPageRequest(this.url, {this.method = 'GET', this.headers = const {}, this.body});

  final String url;
  final String method;
  final Map<String, String> headers;
  final String? body;
}

@immutable
class InPageResponse {
  const InPageResponse({required this.status, required this.url, required this.headers, required this.body});

  final int status;

  /// Where the request ended up, after redirects.
  final Uri url;
  final Map<String, String> headers;
  final String body;
}

/// The page's `fetch` failed: a network error, or a cross-origin request the page may not make.
class InPageFetchException implements Exception {
  const InPageFetchException(this.message);

  final String message;

  @override
  String toString() => 'InPageFetchException: $message';
}
