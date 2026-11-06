import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/foundation.dart';

/// A browser page an extension screen shows: [ChallengePageBrowser] in the app, a fake in tests.
abstract interface class ExtensionPageBrowser {
  /// The page itself, for [ChallengeBrowserView]; null for a fake.
  ChallengeBrowser? get challenge;

  Stream<BrowserEvent> get events;

  /// JavaScript that posts its string argument to [events] as a [ScriptMessage].
  String get postScript;

  Future<void> setUserAgent(String agent);

  Future<void> addDocumentStartScript(String script);

  Future<void> load(String url, {Map<String, String> headers = const {}});

  Future<String> evaluate(String script);

  /// The cookies the page would send to [url].
  Future<List<({String name, String value, String domain})>> cookies(String url);

  /// The page's title as the browser has it: no script runs in the page for it, so it answers while the page waits in
  /// a held dialog, where reading `document.title` would wait with it (Phase 7c).
  Future<String?> title();

  /// Serves [folder] read-only under an address of the page's own, the same every run for [name], and returns that
  /// address's base, ending in `/` (Phase 7c's §6). Throws where the browser can't (Android's reads files itself).
  Future<String> serveFolder(String name, String folder);

  /// Holds each dialog the page opens (alert, confirm, prompt) as a [PageDialog] event, until [answerDialog]: its
  /// answering calls' prompts, and its own dialogs (Phase 7c's §7 and §8).
  Future<void> holdDialogs();

  /// Answers held dialog [id]: [accept] (a confirm's or a prompt's OK) and a prompt's [text].
  Future<void> answerDialog(int id, {required bool accept, String? text});

  Future<void> dispose();
}

/// [ExtensionPageBrowser] over a challenge browser page: the app's own browser engine, on every platform.
class ChallengePageBrowser implements ExtensionPageBrowser {
  ChallengePageBrowser(this.challenge);

  static Future<ExtensionPageBrowser> create() async => ChallengePageBrowser(await ChallengeBrowser.create());

  @override
  final ChallengeBrowser challenge;

  @override
  Stream<BrowserEvent> get events => challenge.events;

  @override
  String get postScript => challenge.postScript;

  @override
  Future<void> setUserAgent(String agent) => challenge.setUserAgent(agent);

  @override
  Future<void> addDocumentStartScript(String script) => challenge.addDocumentStartScript(script);

  @override
  Future<void> load(String url, {Map<String, String> headers = const {}}) => challenge.load(url, headers: headers);

  @override
  Future<String> evaluate(String script) => challenge.evaluate(script);

  @override
  Future<List<({String name, String value, String domain})>> cookies(String url) async => [
    for (final cookie in await challenge.cookies(url)) (name: cookie.name, value: cookie.value, domain: cookie.domain),
  ];

  @override
  Future<String?> title() => challenge.title();

  @override
  Future<String> serveFolder(String name, String folder) => challenge.serveFolder(name, folder);

  @override
  Future<void> holdDialogs() => challenge.holdDialogs(true);

  @override
  Future<void> answerDialog(int id, {required bool accept, String? text}) =>
      challenge.answerDialog(id, accept: accept, text: text);

  @override
  Future<void> dispose() => challenge.dispose();
}

/// One page an extension screen shows on the JVM engine: at node [node] of screen [session].
class ExtensionPage {
  ExtensionPage._(this.rid, this.session, this.node, this.browser, {bool fullScreen = false})
    : _fullScreen = fullScreen;

  /// The engine's name for it: its ops and events carry it.
  final int rid;
  final int session;
  final int node;
  final ExtensionPageBrowser browser;

  /// In a window that asks for the whole screen: its extension's toasts show in it (Phase 7c's §2).
  bool get fullScreen => _fullScreen;
  bool _fullScreen;

  /// The folders its browser serves (Phase 7c's §6): each one's own file address (`file:///…/`), and its served base.
  final List<({String file, String base})> _served = [];

  /// [url], an address its browser reports, as the extension knows it: one under a served base back under its folder's
  /// file address, as Android reports a file page's (Phase 7c's §6); any other as it is.
  String fileUrl(String url) {
    for (final served in _served) {
      if (url.startsWith(served.base)) return '${served.file}${url.substring(served.base.length)}';
    }
    return url;
  }

  /// What its answering calls' prompts start with (Phase 7c's §7): its own and random, so the page's own prompts are
  /// never taken for one.
  final String marker = 'cs3-${_token()}:';

  /// Its answering calls by id: the engine's answer once it comes, which the call's held prompt waits for.
  final Map<String, Completer<Map<String, dynamic>?>> _answers = {};

  Completer<Map<String, dynamic>?> _answer(String id) => _answers.putIfAbsent(id, Completer.new);

  /// Completes when it goes: SkyStream's dialog for it closes then.
  final Completer<void> _gone = Completer<void>();

  /// Its own dialogs being answered now (the extension's chrome client's, or the person's).
  int _dialogs = 0;

  /// Whether a dialog or a call's prompt holds it: what [ExtensionPages.close] lets go of at once.
  bool get _held => _dialogs > 0 || _answers.isNotEmpty;

  /// Set when its close let go of it: nothing it does reaches the engine any more, and what it holds next is answered
  /// at once.
  bool _closing = false;
}

/// What a page tells the engine ([WebReplies.page] in the app), and the engine's answer: an answering call's value, or
/// a page dialog's answer (Phase 7c); nothing for the rest.
typedef PageReport = Future<Map<String, dynamic>> Function(int rid, String type, Map<String, Object?> fields);

/// The pages extension screens show on the JVM engine (desktop and iOS; the spec's §9), by screen and node, for
/// the sheet to show where their nodes are; what each does goes back to the engine (`webPage`). On Android the
/// extension's own WebView shows instead, lent by the cs3_engine plugin, and this stays empty.
class ExtensionPages extends ChangeNotifier {
  ExtensionPages({Future<ExtensionPageBrowser> Function()? create, bool? desktop, Duration? callLimit})
    : _create = create ?? ChallengePageBrowser.create,
      _desktop = desktop ?? (Platform.isMacOS || Platform.isWindows || Platform.isLinux),
      _callLimit = callLimit ?? const Duration(seconds: 30);

  /// The app's; a widget test puts its own here, for the sheet's page views to read.
  static ExtensionPages shared = ExtensionPages();

  final Future<ExtensionPageBrowser> Function() _create;

  /// Whether pages are a desktop's: one in a full-screen window gets its own close button there (Phase 7c's §2).
  final bool _desktop;

  /// How long an answering call's prompt waits for its answer: the page then gets undefined (Phase 7c's §7).
  final Duration _callLimit;

  final _backs = StreamController<int>.broadcast();

  /// The screen (its session) whose full-screen page's own close button was pressed: Back for it (desktops).
  Stream<int> get backs => _backs.stream;

  /// Shows a page's own dialog when its extension's chrome client leaves it to the app (Phase 7c's §8). The app sets it
  /// (SkyStream's dialog over whatever shows), and the dialog closes itself when its page goes ([gone]). With none, the
  /// dialog gets the cancel answer.
  Future<({bool accept, String? text})> Function(PageDialog dialog, Future<void> gone)? dialogs;

  int _showing = 0;

  /// Whether SkyStream shows a page's dialog now: a page that is a window of its own (Windows, Linux) steps aside
  /// meanwhile, or it would cover the dialog.
  bool get showsDialog => _showing > 0;

  final Map<int, ExtensionPage> _pages = {};
  final Map<int, StreamSubscription<BrowserEvent>> _listening = {};
  final Set<(int, int)> _failed = {};

  /// Each page's ops, in the order the engine asked for them, its creation first.
  final Map<int, Future<void>> _ops = {};

  /// Runs [op] after every op already asked of page [rid]: a load, an eval or a close that arrives while the page
  /// is still being made waits for it, rather than finding nothing (and the page, made after, loading on unseen).
  Future<T> _inOrder<T>(int rid, Future<T> Function() op) {
    final result = (_ops[rid] ?? Future<void>.value()).then((_) => op());
    final done = result.then<void>((_) {}, onError: (Object _) {});
    _ops[rid] = done;
    unawaited(
      done.then((_) {
        if (identical(_ops[rid], done)) _ops.remove(rid);
      }),
    );
    return result;
  }

  /// The page at [node] of screen [session], once it's open.
  ExtensionPage? at(int session, int node) =>
      _pages.values.where((page) => page.session == session && page.node == node).firstOrNull;

  /// The page at [node] of [session] couldn't open, or its renderer went: the sheet says it can't show it.
  bool failedAt(int session, int node) => _failed.contains((session, node));

  /// Opens the page [event] asks for (`webRequest{op: page}`), with the extension's user agent, its requests
  /// reported and its JavaScript interfaces in the page, and reports what it does through [report] in order. One
  /// that can't open is reported `closed`.
  Future<void> open(Map<String, dynamic> event, PageReport report) =>
      _inOrder((event['rid'] as num).toInt(), () => _open(event, report));

  Future<void> _open(Map<String, dynamic> event, PageReport report) async {
    final rid = (event['rid'] as num).toInt();
    final session = (event['session'] as num).toInt();
    final node = (event['node'] as num).toInt();
    final ExtensionPageBrowser browser;
    try {
      browser = await _create();
    } catch (_) {
      _failed.add((session, node));
      notifyListeners();
      await report(rid, 'closed', const {});
      return;
    }
    final page = ExtensionPage._(rid, session, node, browser, fullScreen: event['fullScreen'] == true);
    _pages[rid] = page;
    _failed.remove((session, node));
    // One at a time, in order: each may wait on the page's cookies or title.
    var queue = Future<void>.value();
    _listening[rid] = browser.events.listen((event) {
      // A page its close let go of: what it does stays in it, and what holds it is answered at once.
      if (page._closing) {
        if (event is PageDialog) unawaited(_dismiss(page, event));
        return;
      }
      // An answering call's prompt waits for its call's answer, which comes through the queue: not queued behind it.
      if (event is PageDialog && event.message.startsWith(page.marker)) {
        unawaited(_answerCall(page, event));
        return;
      }
      // The page's own dialog waits for its answer (its extension's, or the person's) after the events before it, but
      // holds none after it: a document the extension loads meanwhile is reported as it comes, as on Android.
      if (event is PageDialog) {
        page._dialogs++;
        unawaited(queue.then((_) => _dialog(page, event, report)).whenComplete(() => page._dialogs--));
        return;
      }
      queue = queue.then((_) => _report(page, event, report)).catchError((Object _) {});
    });
    try {
      final agent = event['userAgent'] as String?;
      if (agent != null && agent.isNotEmpty) await browser.setUserAgent(agent);
      await browser.addDocumentStartScript(requestsScript(browser.postScript));
      // Its dialogs wait for their answers: its answering calls' prompts, and its own alerts, confirms and prompts.
      await browser.holdDialogs();
      final interfaces = _interfaces(event['interfaces']);
      final answering = _interfaces(event['answering']);
      if (interfaces.isNotEmpty || answering.isNotEmpty) {
        await browser.addDocumentStartScript(
          interfacesScript(browser.postScript, interfaces, answering: answering, marker: page.marker),
        );
      }
      // In a full-screen window: its extension's toasts show in it, and on a desktop it has its own close button, as
      // nothing of the app's can show over a page that is a window of its own (Phase 7c's §2).
      if (page.fullScreen) {
        await browser.addDocumentStartScript(fullScreenScript(browser.postScript, closeButton: _desktop));
      }
      notifyListeners();
      await browser.load(
        await _address(page, event['url'] as String? ?? 'about:blank', event['serve']),
        headers: _texts(event['headers']),
      );
    } catch (_) {
      await _lost(page, report);
    }
  }

  /// Page [rid] loads [url]: its web view's later loadUrl, under its folder's served address when [serve] (the op's)
  /// says the app serves it (Phase 7c's §6).
  Future<void> navigate(int rid, String url, Map<String, String> headers, {Object? serve}) => _inOrder(rid, () async {
    final page = _pages[rid];
    if (page != null) await page.browser.load(await _address(page, url, serve), headers: headers);
  });

  /// What [page] loads for [url]: under its folder's served address when [serve] says so, else [url], as it is where
  /// the browser can't serve. [serve] is an op's `serve`: the folder's `name`, the `folder`, the `path` below it, and the
  /// folder's own `file` address.
  static Future<String> _address(ExtensionPage page, String url, Object? serve) async {
    if (serve is! Map) return url;
    try {
      final base = await page.browser.serveFolder('${serve['name']}', '${serve['folder']}');
      final file = '${serve['file']}';
      page._served
        ..removeWhere((served) => served.file == file)
        ..add((file: file, base: base));
      return '$base${serve['path']}';
    } catch (_) {
      return url;
    }
  }

  /// Gives [session]'s page at [node] what a full-screen window's page has (its extension's toasts in it, on a desktop
  /// its own ×) when it opened before its window asked for the whole screen; nothing for a page that has them.
  Future<void> fullScreen(int session, int node) async {
    final page = at(session, node);
    if (page == null || page.fullScreen) return;
    page._fullScreen = true;
    final script = fullScreenScript(page.browser.postScript, closeButton: _desktop);
    await _inOrder(page.rid, () async {
      try {
        // For the page's next documents, and the one it shows now.
        await page.browser.addDocumentStartScript(script);
        await page.browser.evaluate(script);
      } catch (_) {}
    });
  }

  /// Runs [script] in page [rid]: its result as JSON text, or "null" when it's gone or didn't answer.
  Future<String> eval(int rid, String script) => _inOrder(rid, () => _eval(rid, script));

  /// Shows an extension's toast [text] in each page of a full-screen window, as Android's shows over its window: true
  /// when one did (the app then shows no toast of its own).
  Future<bool> toast(String text) async {
    var shown = false;
    for (final page in _pages.values.where((page) => page.fullScreen).toList()) {
      final result = await eval(page.rid, 'window.__cs3Toast ? window.__cs3Toast(${jsonEncode(text)}) : false');
      if (result == 'true') shown = true;
    }
    return shown;
  }

  Future<String> _eval(int rid, String script) async {
    final page = _pages[rid];
    if (page == null) return 'null';
    try {
      return await page.browser.evaluate(script);
    } catch (_) {
      return 'null';
    }
  }

  /// Page [rid] goes: the engine is done with it, after the ops asked of it before. A page held in a dialog or a
  /// call's prompt is let go of at once, not in turn, since an op ahead may be waiting on what holds it (an eval runs
  /// no script in a held page): its dialog gets cancel and its calls undefined, what it does with those stays in it,
  /// and what holds it next is answered at once. A page that holds nothing reports on until its turn: a game's last
  /// save, posted by an eval just before its window goes, still reaches the engine.
  Future<void> close(int rid) {
    final page = _pages[rid];
    if (page != null && page._held) {
      page._closing = true;
      _letGo(page);
    }
    return _inOrder(rid, () => _close(rid));
  }

  Future<void> _close(int rid) async {
    final page = _pages.remove(rid);
    if (page == null) return;
    await _listening.remove(rid)?.cancel();
    _letGo(page);
    notifyListeners();
    await page.browser.dispose();
  }

  /// [page]'s calls' prompts stop waiting (they answer undefined), and SkyStream's dialog for it closes: it's going.
  static void _letGo(ExtensionPage page) {
    for (final answer in page._answers.values) {
      if (!answer.isCompleted) answer.complete(null);
    }
    page._answers.clear();
    if (!page._gone.isCompleted) page._gone.complete();
  }

  /// Every page goes: the engine they were for stopped, or another started.
  Future<void> closeAll() async {
    // Pages still being made too: their close waits for them. All at once: none waits for another's turn.
    await Future.wait([
      for (final rid in {..._pages.keys, ..._ops.keys}) close(rid),
    ]);
    _failed.clear();
    notifyListeners();
  }

  /// [page] couldn't open, or its renderer went: the sheet says it can't show it, and the engine hears it closed.
  Future<void> _lost(ExtensionPage page, PageReport report) async {
    _failed.add((page.session, page.node));
    // Not queued: it can run inside the page's own open.
    await _close(page.rid);
    await report(page.rid, 'closed', const {});
  }

  Future<void> _report(ExtensionPage page, BrowserEvent event, PageReport report) async {
    final rid = page.rid;
    switch (event) {
      case PageStarted(:final url):
        final address = page.fileUrl('$url');
        // A main-frame navigation is a request too, as Android hands shouldInterceptRequest one, headers aside.
        await report(rid, 'request', {
          'url': address,
          'method': 'GET',
          'headers': const <String, String>{},
          'mainFrame': true,
        });
        await report(rid, 'started', {'url': address, 'cookies': await _cookies(page, url)});
      case PageFinished(:final url):
        final address = page.fileUrl('$url');
        await report(rid, 'finished', {
          'url': address,
          'title': await _title(page, '$url', address),
          'cookies': await _cookies(page, url),
        });
      case PageError(:final url, :final code, :final text, :final mainFrame):
        final address = url == null ? null : page.fileUrl('$url');
        await report(rid, 'failed', {'url': ?address, 'code': code, 'text': text, 'mainFrame': mainFrame});
      case ScriptMessage(:final message):
        final call = _json(message);
        if (call?['cs3-req'] == 1) {
          await report(rid, 'request', {
            'url': page.fileUrl('${call!['url']}'),
            'method': call['method'] ?? 'GET',
            'headers': call['headers'] ?? const <String, String>{},
            'mainFrame': false,
          });
        } else if (call?['cs3-js'] == 1) {
          final id = call!['id'];
          if (id is String) {
            // An answering call (Phase 7c's §7): the engine runs it after the calls posted before it; its prompt waits.
            final answer = page._answer(id);
            Map<String, dynamic>? value;
            try {
              value = await report(rid, 'call', {'message': message});
            } catch (_) {}
            if (!answer.isCompleted) answer.complete(value);
          } else {
            await report(rid, 'message', {'message': message});
          }
        } else if (call?['cs3-back'] == 1) {
          // The page's own close button (a desktop's full-screen page): Back for its screen.
          _backs.add(page.session);
        }
      case RendererGone():
        await _lost(page, report);
      default:
    }
  }

  /// The page's own alert, confirm or prompt (Phase 7c's §8): its extension's chrome client answers it, or leaves it
  /// to the app; with no client it's cancelled.
  Future<void> _dialog(ExtensionPage page, PageDialog dialog, PageReport report) async {
    Map<String, dynamic>? answer;
    try {
      answer = await report(page.rid, 'dialog', {
        'kind': dialog.kind.name,
        'message': dialog.message,
        'defaultText': dialog.defaultText,
        'url': dialog.url == null ? null : page.fileUrl('${dialog.url}'),
      });
    } catch (_) {}
    final result = answer?['show'] == true
        ? await _show(page, dialog)
        : (
            accept: answer?['accept'] == true,
            text: switch (answer?['text']) {
              final String text => text,
              _ => null,
            },
          );
    try {
      await page.browser.answerDialog(dialog.id, accept: result.accept, text: result.text);
    } catch (_) {
      // The page went meanwhile: its browser answered it as it went.
    }
  }

  /// Answers [dialog] at once for a page its close let go of: a call's prompt undefined, the page's own dialog cancel.
  static Future<void> _dismiss(ExtensionPage page, PageDialog dialog) async {
    final call = dialog.message.startsWith(page.marker);
    try {
      await page.browser.answerDialog(dialog.id, accept: call, text: call ? '{}' : null);
    } catch (_) {
      // The page went meanwhile: its browser answered it as it went.
    }
  }

  /// An answering call's held prompt (Phase 7c's §7), answered once its call's answer comes, or after [_callLimit], as
  /// JSON the page's script reads: `{"v": value}`, `{"e": message}` for a throw, `{}` for undefined.
  Future<void> _answerCall(ExtensionPage page, PageDialog dialog) async {
    final id = dialog.message.substring(page.marker.length);
    final answer = await page._answer(id).future.timeout(_callLimit, onTimeout: () => null);
    page._answers.remove(id);
    final reply = <String, Object?>{
      if (answer != null && answer.containsKey('value')) 'v': answer['value'],
      if (answer?['error'] case final String error) 'e': error,
    };
    try {
      await page.browser.answerDialog(dialog.id, accept: true, text: jsonEncode(reply));
    } catch (_) {
      // The page went meanwhile: its browser answered it as it went.
    }
  }

  /// SkyStream's dialog for [dialog] ([dialogs]): pages that are windows of their own step aside while it shows.
  /// Cancel when nothing can show it, or its page went.
  Future<({bool accept, String? text})> _show(ExtensionPage page, PageDialog dialog) async {
    final show = dialogs;
    if (show == null || page._gone.isCompleted) return (accept: false, text: null);
    _showing++;
    notifyListeners();
    try {
      return await show(dialog, page._gone.future);
    } catch (_) {
      return (accept: false, text: null);
    } finally {
      _showing--;
      notifyListeners();
    }
  }

  static Future<List<Map<String, String>>> _cookies(ExtensionPage page, Uri url) async {
    try {
      return [
        for (final cookie in await page.browser.cookies('$url'))
          {'name': cookie.name, 'value': cookie.value, 'domain': cookie.domain},
      ];
    } catch (_) {
      return const [];
    }
  }

  /// [page]'s title, from its browser rather than a script in the page: the page may be waiting in a held dialog, the
  /// prompt of an answering call whose message is queued after this (Phase 7c). A page with no title of its own gets
  /// the one Android's WebView gives it: its [address] (as the extension knows it) as Chromium shows it
  /// ([displayTitle]). The browsers here give, for such a page, the address it loaded ([url]): WebView2 in that same
  /// form, WebKitGTK null, WebKit "".
  static Future<String?> _title(ExtensionPage page, String url, String address) async {
    String? title;
    try {
      title = await page.browser.title();
    } catch (_) {
      return null;
    }
    final none = title == null || title.isEmpty || title == url || title == address || title == displayTitle(url);
    return none ? displayTitle(address) : title;
  }

  /// [address] as Chromium shows it for a page with no title of its own (`NavigationEntryImpl::GetTitleForDisplay`),
  /// which Android's WebView gives as its title: a file page's name and what follows it (`index.html?game=test`); any
  /// other address without `https://`, `http://`, a user and password, `www.`, or a bare host's `/`, with `%20` read as
  /// a space (`site.test/login?next=1`).
  @visibleForTesting
  static String displayTitle(String address) {
    var title = address;
    final uri = Uri.tryParse(address);
    if (uri != null && (uri.isScheme('http') || uri.isScheme('https')) && uri.host.isNotEmpty) {
      final host = uri.host.startsWith('www.') ? uri.host.substring(4) : uri.host;
      final bare = (uri.path.isEmpty || uri.path == '/') && !uri.hasQuery && !uri.hasFragment;
      title = '$host${uri.hasPort ? ':${uri.port}' : ''}${bare ? '' : address.substring(_pathStart(address))}';
    }
    title = title.replaceAll('%20', ' ');
    if (uri != null && uri.isScheme('file')) {
      final cut = [title.indexOf('?'), title.indexOf('#')].where((at) => at >= 0).fold(title.length, min);
      final slash = title.lastIndexOf('/', cut == title.length ? title.length - 1 : cut);
      if (slash >= 0) title = title.substring(slash + 1);
    }
    return title;
  }

  /// Where [address]'s path starts: after its scheme and its authority.
  static int _pathStart(String address) {
    final authority = address.indexOf('//') + 2;
    final rest = [address.indexOf('/', authority), address.indexOf('?', authority), address.indexOf('#', authority)];
    return rest.where((at) => at >= 0).fold(address.length, min);
  }

  static Map<String, dynamic>? _json(String message) {
    try {
      final value = jsonDecode(message);
      return value is Map<String, dynamic> ? value : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, List<String>> _interfaces(Object? json) => {
    if (json is Map)
      for (final e in json.entries)
        if (e.value is List) '${e.key}': [for (final method in e.value as List) '$method'],
  };

  static Map<String, String> _texts(Object? json) => {
    if (json is Map)
      for (final e in json.entries) '${e.key}': '${e.value}',
  };
}

/// A document-start script that reports each request the page's own scripts make (`fetch` and
/// `XMLHttpRequest`), with the headers they set, through [post] (a [ExtensionPageBrowser.postScript]):
/// `{"cs3-req": 1, url, method, headers}`. Kartoons reads its sign-in's token from such a header (the spec's §9).
String requestsScript(String post) =>
    '''
(function () {
  if (window.__cs3Requests) return;
  window.__cs3Requests = true;
  var post = $post;
  function headersOf(h) {
    var out = {};
    if (!h) return out;
    if (typeof Headers !== 'undefined' && h instanceof Headers) h.forEach(function (v, k) { out[k] = v; });
    else if (Array.isArray(h)) h.forEach(function (p) { out[p[0]] = String(p[1]); });
    else for (var k in h) out[k] = String(h[k]);
    return out;
  }
  function report(url, method, headers) {
    try {
      post(JSON.stringify({'cs3-req': 1, url: new URL(url, location.href).href,
        method: String(method || 'GET').toUpperCase(), headers: headers}));
    } catch (e) {}
  }
  var fetch0 = window.fetch;
  if (fetch0) window.fetch = function (input, init) {
    try {
      var request = typeof input === 'object' && input !== null && 'url' in input ? input : null;
      var headers = headersOf(request && request.headers);
      var own = headersOf(init && init.headers);
      for (var k in own) headers[k] = own[k];
      report(request ? request.url : String(input), (init && init.method) || (request && request.method), headers);
    } catch (e) {}
    return fetch0.apply(this, arguments);
  };
  var proto = XMLHttpRequest.prototype, open0 = proto.open, header0 = proto.setRequestHeader, send0 = proto.send;
  proto.open = function (method, url) {
    this.__cs3 = {method: method, url: String(url), headers: {}};
    return open0.apply(this, arguments);
  };
  proto.setRequestHeader = function (k, v) {
    if (this.__cs3) this.__cs3.headers[k] = String(v);
    return header0.apply(this, arguments);
  };
  proto.send = function () {
    if (this.__cs3) report(this.__cs3.url, this.__cs3.method, this.__cs3.headers);
    return send0.apply(this, arguments);
  };
})();
''';

/// A document-start script that puts the extension's JavaScript interfaces in the page, as Android's
/// addJavascriptInterface does (the spec's §9; Phase 7c's §7): [interfaces] (name to its one-way methods) and
/// [answering] (name to its methods that return a value).
/// - A one-way call posts `{"cs3-js": 1, name, method, args}` through [post], and returns nothing.
/// - An answering call posts the same with its `id`, then holds `prompt(marker + id)` ([marker]: the page's own) until
///   the app answers it with the call's answer, as JSON: `{"v": value}` returns the value, `{"e": message}` throws it,
///   `{}` returns undefined. Its arguments travel in the post: WebView2 cuts a prompt's text at 10,240 characters.
/// The calls use the browser's own prompt, JSON, Array.prototype.slice, Function.prototype.call and Error, taken before
/// the page's own scripts run: a page that replaces them still gets its answers, as from Android's bridge.
String interfacesScript(
  String post,
  Map<String, List<String>> interfaces, {
  Map<String, List<String>> answering = const {},
  String marker = '',
}) =>
    '''
(function () {
  var post = $post;
  // The page's own scripts may replace prompt, and the built-ins a call uses; the calls keep the browser's, bound now.
  var ask = window.prompt.bind(window);
  var stringify = JSON.stringify.bind(JSON), parse = JSON.parse.bind(JSON);
  var list = Function.prototype.call.bind(Array.prototype.slice);
  var Failure = Error;
  var marker = ${jsonEncode(marker)};
  // Ids no other document's calls share: a late answer for one document can't reach another's call.
  var doc = Math.random().toString(36).slice(2), calls = 0;
  var interfaces = ${jsonEncode(interfaces)};
  var answering = ${jsonEncode(answering)};
  var names = Object.keys(interfaces);
  Object.keys(answering).forEach(function (name) { if (names.indexOf(name) < 0) names.push(name); });
  names.forEach(function (name) {
    var target = {};
    (interfaces[name] || []).forEach(function (method) {
      target[method] = function () {
        try {
          post(stringify({'cs3-js': 1, name: name, method: method, args: list(arguments)}));
        } catch (e) {}
      };
    });
    (answering[name] || []).forEach(function (method) {
      target[method] = function () {
        var id = doc + '.' + (++calls);
        try {
          post(stringify({'cs3-js': 1, name: name, method: method, args: list(arguments), id: id}));
        } catch (e) {
          return undefined;
        }
        var answer = {};
        try {
          answer = parse(ask(marker + id) || '{}') || {};
        } catch (e) {}
        if (typeof answer.e === 'string') throw new Failure(answer.e);
        return answer.v;
      };
    });
    window[name] = target;
  });
})();
''';

/// A document-start script for a page in a full-screen window (Phase 7c's §2): `window.__cs3Toast(text)` shows an
/// extension's toast at the page's foot for 2 s, as Android's shows over its window; with [closeButton] (desktops) a ×
/// in the top right corner, shown while the mouse moves and gone 2 s after, posts `{"cs3-back": 1}` through [post], as
/// `window.__cs3Back()` does. Both sit in a closed shadow root, so the page's own styles and scripts leave them alone,
/// and neither takes a tap meant for the page (the × only while it shows).
String fullScreenScript(String post, {required bool closeButton}) =>
    '''
(function () {
  if (window.__cs3Toast) return;
  var post = $post;
  var host = null, root = null, toast = null, hideToast = null;
  function ready() {
    if (!host) {
      host = document.createElement('div');
      host.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none';
      root = host.attachShadow({mode: 'closed'});
    }
    if (!host.isConnected) (document.body || document.documentElement).appendChild(host);
    return root;
  }
  window.__cs3Toast = function (text) {
    var r = ready();
    if (!toast) {
      toast = document.createElement('div');
      toast.style.cssText = 'position:absolute;left:50%;bottom:48px;transform:translateX(-50%);max-width:80%;' +
        'padding:10px 18px;border-radius:20px;background:rgba(0,0,0,.75);color:#fff;font:15px/1.3 sans-serif;' +
        'text-align:center;opacity:0;transition:opacity .2s;pointer-events:none';
      r.appendChild(toast);
    }
    toast.textContent = String(text);
    toast.style.opacity = '1';
    clearTimeout(hideToast);
    hideToast = setTimeout(function () { toast.style.opacity = '0'; }, 2000);
    return true;
  };
${closeButton ? _closeButtonScript : ''}
})();
''';

/// [fullScreenScript]'s × (desktops), inside its function: `post` and `ready` are its own.
const _closeButtonScript = r'''
  window.__cs3Back = function () { try { post(JSON.stringify({'cs3-back': 1})); } catch (e) {} };
  function button() {
    var close = document.createElement('button');
    close.setAttribute('aria-label', 'Close');
    close.textContent = '×';
    close.style.cssText = 'all:initial;position:absolute;top:8px;right:8px;width:36px;height:36px;border-radius:18px;' +
      'background:rgba(0,0,0,.6);color:#fff;font:20px/36px sans-serif;text-align:center;cursor:pointer;' +
      'opacity:0;transition:opacity .2s;pointer-events:none';
    close.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); window.__cs3Back(); });
    ready().appendChild(close);
    var hide = null;
    document.addEventListener('mousemove', function () {
      close.style.opacity = '1';
      close.style.pointerEvents = 'auto';
      clearTimeout(hide);
      hide = setTimeout(function () { close.style.opacity = '0'; close.style.pointerEvents = 'none'; }, 2000);
    }, true);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', button); else button();
''';

/// 16 random lowercase letters and digits.
String _token() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return String.fromCharCodes([for (var i = 0; i < 16; i++) chars.codeUnitAt(random.nextInt(chars.length))]);
}
