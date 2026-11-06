// The contract between Dart and each platform's backend. Regenerate after a change:
//   dart run pigeon --input pigeons/messages.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartPackageName: 'challenge_browser',
    kotlinOut: 'android/src/main/kotlin/dev/akash/challenge_browser/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.akash.challenge_browser'),
    swiftOut: 'darwin/challenge_browser/Sources/challenge_browser/Messages.g.swift',
    cppHeaderOut: 'windows/messages.g.h',
    cppSourceOut: 'windows/messages.g.cpp',
    cppOptions: CppOptions(namespace: 'challenge_browser'),
    gobjectHeaderOut: 'linux/messages.g.h',
    gobjectSourceOut: 'linux/messages.g.cc',
    gobjectOptions: GObjectOptions(),
  ),
)
enum PageEventKind {
  /// The main frame started loading [PageEvent.url].
  pageStarted,

  /// The main frame finished loading [PageEvent.url].
  pageFinished,

  /// A load failed: [PageEvent.url], [PageEvent.code], [PageEvent.errorText], [PageEvent.mainFrame].
  pageError,

  /// Loading progress, 0 to 1, in [PageEvent.progress].
  progress,

  /// The page's renderer process ended; [PageEvent.crashed] tells a crash from the system
  /// reclaiming memory. The page is unusable afterwards.
  rendererGone,

  /// A script in the page posted [PageEvent.message] to the page's channel.
  scriptMessage,

  /// The page requested [PageEvent.url] with [PageEvent.method], while capture is on.
  captured,

  /// Keyboard or D-pad focus is leaving the page, towards [PageEvent.direction].
  focusExit,

  /// The page took keyboard focus by itself, from a click. Sent where Flutter's engine doesn't tell
  /// the framework: macOS, and the desktop overlays on Windows and Linux.
  focused,

  /// The page lost keyboard focus: to a click elsewhere, or the app losing focus. Sent on macOS,
  /// Windows and Linux, where keys then reach Flutter again.
  blurred,

  /// The main frame was about to go to [PageEvent.url], which starts with one of the page's stop
  /// prefixes (`setNavigationStops`), and was stopped instead.
  navigationStopped,

  /// The page opened a dialog, held while its dialogs are held ([PageHostApi.holdDialogs]): [PageEvent.dialogId],
  /// [PageEvent.dialogKind], [PageEvent.message], [PageEvent.defaultText] (a prompt's), and [PageEvent.url], the
  /// frame's. Answer it with [PageHostApi.answerDialog].
  dialog,
}

enum FocusDirection { forward, backward, up, down, left, right }

enum DialogKind { alert, confirm, prompt }

class PageEvent {
  PageEvent({required this.kind});

  PageEventKind kind;
  String? url;
  int? code;
  String? errorText;
  bool? mainFrame;
  double? progress;
  bool? crashed;
  String? message;
  String? method;
  FocusDirection? direction;
  int? dialogId;
  DialogKind? dialogKind;
  String? defaultText;
}

class PageCookie {
  PageCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.httpOnly,
    required this.secure,
  });

  String name;
  String value;
  String domain;
  String path;

  /// Milliseconds since the epoch; null for a session cookie.
  int? expiresMs;
  bool httpOnly;
  bool secure;
}

/// What this platform's backend can do.
class PageCapabilities {
  PageCapabilities({required this.canTap, required this.isolatedWorlds});

  /// [PageHostApi.tap] sends input: not on iOS, which has no allowed way to.
  bool canTap;

  /// [PageHostApi.evaluateIsolated] runs where the page's scripts can't see it (on Windows, through
  /// [PageHostApi.devTools]). Android's WebView has no such world.
  bool isolatedWorlds;
}

/// Where a page shows inside the app window, in logical pixels from the Flutter view's top left.
/// Windows and Linux only: elsewhere a platform view places the page.
class PageFrame {
  PageFrame({required this.left, required this.top, required this.width, required this.height});

  double left;
  double top;
  double width;
  double height;
}

@HostApi()
abstract class PageHostApi {
  /// Creates a hidden page and returns its id. Scripts reach Dart through [scriptChannel]: see
  /// `ChallengeBrowser` for how each engine names it.
  @async
  int create(String scriptChannel);

  void load(int pageId, String url, Map<String, String> headers);

  /// Runs [script] in the main frame and returns the result as JSON ("null" for undefined).
  @async
  String evaluate(int pageId, String script);

  /// Runs [script] in every frame of every later document, before the document's own scripts.
  void addDocumentStartScript(int pageId, String script);

  @async
  List<PageCookie> cookies(int pageId, String url);

  /// Deletes [url]'s cookie [name], or all of its cookies when [name] is null.
  @async
  void deleteCookies(int pageId, String url, String? name);

  @async
  String userAgent(int pageId);

  /// Sets the page's user agent. Only an extension's own pages (Phase 7 part 5): SkyStream's clearances keep the
  /// engine's own, which earned them.
  void setUserAgent(int pageId, String userAgent);

  /// Reports each request the page makes as a `captured` event while [enabled]. Engines that can't
  /// see requests natively (WebKit on Apple platforms) ignore this; Dart observes from the page.
  void setCapture(int pageId, bool enabled);

  /// Shows the page over [frame] inside the app window, or hides it again when [frame] is null.
  /// Windows and Linux only.
  void setFrame(int pageId, PageFrame? frame);

  /// Moves keyboard focus into the page: to its first focusable element when [forward], else its last.
  void focus(int pageId, bool forward);

  /// Moves keyboard focus out of the page, back to Flutter's view, if the page has it.
  void blur(int pageId);

  /// Stops the main frame from going to any URL that starts with one of [prefixes], redirects
  /// included, and reports each as a `navigationStopped` event. Replaces the previous prefixes; an
  /// empty list stops none. The match is on the whole URL, fragment included, as plain text.
  void setNavigationStops(int pageId, List<String> prefixes);

  @async
  void dispose(int pageId);

  /// A tap or click at [x], [y] in CSS pixels from the page's top left, sent as the platform's own
  /// input. The page needn't be shown or focused.
  @async
  void tap(int pageId, double x, double y);

  /// Runs [script] where the page's own scripts can't see it, and returns its result as JSON, as
  /// [evaluate] does: a content world on Apple platforms, a script world on Linux. Unsupported on
  /// Android, and on Windows, where Dart builds the world over [devTools].
  @async
  String evaluateIsolated(int pageId, String script);

  PageCapabilities capabilities();

  /// The engine's version, where the app needs it: Android System WebView's version name; empty
  /// elsewhere.
  String engineVersion();

  /// Windows only: a WebView2 DevTools call, [paramsJson] in, its result JSON out, as is.
  @async
  String devTools(int pageId, String method, String paramsJson);

  /// Serves [folder], an absolute path, read-only under an address of the page's own, and returns that address's base,
  /// ending in `/`: `cbfolder://[name]/` on Apple platforms and Linux, `https://[name].example/` on Windows. [name]
  /// (lowercase letters, digits and hyphens) gives the same address every run, so what a page keeps there (its storage)
  /// stays its own; only [folder] and what's below it is served, and only to this page. Serving [name] again replaces
  /// its folder. Unsupported on Android, whose WebView reads files itself.
  String serveFolder(int pageId, String name, String folder);

  /// Holds each dialog the page opens while [hold] (alert, confirm, prompt) and reports it as a `dialog` event, until
  /// [answerDialog]; a page leaving asks no one meanwhile. While not held (the default), each engine does as it does:
  /// WKWebView answers at once, WebView2 and WebKitGTK show their own. Set it before [load]: WebView2 takes it as a
  /// document loads. Unsupported on Android.
  void holdDialogs(int pageId, bool hold);

  /// Answers held dialog [dialogId]: an alert closes, a confirm answers [accept], a prompt [text] when [accept] and null
  /// otherwise. A dialog the page no longer waits for is ignored. Unsupported on Android.
  void answerDialog(int pageId, int dialogId, bool accept, String? text);

  /// The page's title as its engine has it, read without running anything in the page: it answers while the page waits
  /// in a held dialog, where `document.title` would wait with it. Null before a document has one; WebView2 and
  /// Android's WebView name an untitled page by its address, as Android's `WebView.getTitle` does.
  String? title(int pageId);
}

@FlutterApi()
abstract class PageFlutterApi {
  void onEvent(int pageId, PageEvent event);
}
