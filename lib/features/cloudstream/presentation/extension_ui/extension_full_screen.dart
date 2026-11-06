import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../../core/cloudstream/extension_ui/extension_pages.dart';
import '../../../../core/cloudstream/extension_ui/extension_ui_session.dart';
import '../../../../core/cloudstream/extension_ui/ui_tree.dart';
import '../../../../core/router/app_router.dart';
import '../../../player/presentation/player_platform_service.dart';
import 'extension_page_view.dart';
import 'ui_node_view.dart';

/// What the full-screen view asks of the device while it shows (Phase 7c's §2 and §5); tests stand in for it.
abstract interface class FullScreenDevice {
  /// The system bars hidden, the screen kept on if [keepScreenOn], and [orientations] held (an iPhone's), or the
  /// device's own orientation when null.
  Future<void> enter({required bool keepScreenOn, List<DeviceOrientation>? orientations});

  /// What [enter] asked, given back as the rest of the app wants it.
  Future<void> leave();
}

/// The device itself, through the player's own means: its system-bar mode, its wakelock, its orientation hand-back.
class SystemFullScreenDevice implements FullScreenDevice {
  SystemFullScreenDevice({bool Function()? playerUnder}) : _playerUnder = playerUnder ?? (() => false);

  /// Whether the player is under the view: it keeps the bars hidden, and gives them back itself as it goes.
  final bool Function() _playerUnder;
  final _platform = PlayerPlatformService();
  bool? _wakelockBefore;
  var _barsHidden = false;

  @override
  Future<void> enter({required bool keepScreenOn, List<DeviceOrientation>? orientations}) async {
    if (Platform.isAndroid || Platform.isIOS) {
      _barsHidden = true;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if (keepScreenOn) {
      _wakelockBefore ??= await WakelockPlus.enabled;
      await WakelockPlus.enable();
    }
    if (orientations != null) {
      _platform.pinOrientation(orientations);
    } else {
      _platform.restoreOrientation();
    }
  }

  @override
  Future<void> leave() async {
    _platform.restoreOrientation();
    // A wakelock someone else held (the player's) stays theirs.
    if (_wakelockBefore == false) await WakelockPlus.disable();
    if (_barsHidden && !_playerUnder()) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: SystemUiOverlay.values);
    }
  }
}

/// What an iPhone holds for an Android `SCREEN_ORIENTATION_*` an extension asked for (Phase 7c's §5): its landscape
/// values (landscape, sensor landscape, reverse landscape, user landscape) turn it sideways, its portrait values
/// upright, and the rest leave it to the device.
List<DeviceOrientation>? orientationsFor(int? requested) => switch (requested) {
  0 || 6 || 8 || 11 => const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
  1 || 7 || 9 || 12 => const [DeviceOrientation.portraitUp],
  _ => null,
};

/// The index of the last window that asks for the whole screen, or null: the view shows it, and the windows above it
/// over it.
int? fullScreenIndex(List<UiWindow> windows) {
  for (var i = windows.length - 1; i >= 0; i--) {
    if (windows[i].fullScreen) return i;
  }
  return null;
}

/// The view showing each screen, while it shows: one per screen, whoever asks (the sheet, or a screen's own turn).
final _views = Expando<Future<void>>('extension full-screen views');

/// Shows [session]'s full-screen windows over everything until none is left, or the screen ends (Phase 7c's §2). A
/// second call while it shows waits for the same view.
Future<void> showExtensionFullScreen(
  BuildContext context, {
  required ExtensionUiSession session,
  required String title,
  FullScreenDevice? device,
}) {
  final showing = _views[session];
  if (showing != null) return showing;
  final router = GoRouter.maybeOf(context);
  final shown = Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => ExtensionFullScreen(
        session: session,
        title: title,
        device: device ?? SystemFullScreenDevice(playerUnder: () => router != null && playerRouteIsOnTop(router)),
      ),
    ),
  );
  _views[session] = shown;
  return shown.whenComplete(() {
    _views[session] = null;
  });
}

/// An extension's window that asks for the whole screen (a game, a reader, a player), filling the app's window with no
/// header (Phase 7c's §2). Windows above it show over it as dialogs. Each platform's way out is Back to the top window:
/// the system Back (Android, TV), a swipe in from the left edge (iPhone, iPad), a × that shows while the mouse moves
/// (desktops; inside the page for a page, which a native window would otherwise cover). Two Backs to the same window,
/// and that window still there 3 s after the second, is closed by force. It leaves once no window asks for the whole
/// screen, or the screen ends.
class ExtensionFullScreen extends StatefulWidget {
  const ExtensionFullScreen({
    super.key,
    required this.session,
    required this.title,
    this.device,
    this.iPhone,
    this.desktop,
    this.ios,
    this.android,
  });

  final ExtensionUiSession session;

  /// The extension's name: what screen readers announce.
  final String title;

  /// [SystemFullScreenDevice] unless a test says.
  final FullScreenDevice? device;

  /// Whether this is an iPhone, which turns for the extension: iOS with a shortest side under 600, unless a test says.
  final bool? iPhone;

  /// Whether this is a desktop, where a × shows while the mouse moves: macOS, Windows or Linux, unless a test says.
  final bool? desktop;

  /// Whether this is iOS, where a swipe in from the left edge is Back, unless a test says.
  final bool? ios;

  /// Whether the engine is Android's, whose pages are the extension's own: [Platform.isAndroid] unless a test says.
  final bool? android;

  /// How close two Backs come to count as a pair, and how long after the pair a window still there is closed by force.
  static const escapeAfter = Duration(seconds: 3);

  /// How long the desktop's × stays after the mouse stops.
  static const closeButtonFor = Duration(seconds: 2);

  /// The left edge's strip on iPhone and iPad, at least: the page never gets it.
  static const edgeStrip = 16.0;

  @override
  State<ExtensionFullScreen> createState() => _ExtensionFullScreenState();
}

class _ExtensionFullScreenState extends State<ExtensionFullScreen> with WidgetsBindingObserver {
  late final FullScreenDevice _device = widget.device ?? SystemFullScreenDevice();
  StreamSubscription<int>? _pageBacks;

  /// What the device was last asked for: the window, its orientation and its screen-on.
  String? _entered;

  /// The device's calls, one after another: a leave asked while an enter is on its way comes after it, or the enter's
  /// later steps would undo it (the bars hidden again, the wakelock on, an iPhone pinned).
  Future<void> _deviceCalls = Future<void>.value();

  /// The window the last Back went to, while a second Back within [ExtensionFullScreen.escapeAfter] makes a pair.
  String? _backedRecently;
  Timer? _backWindow;
  Timer? _escape;
  Timer? _closeButton;
  var _showClose = false;
  var _leaving = false;
  double _drag = 0;

  bool get _desktop => widget.desktop ?? (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  bool get _ios => widget.ios ?? (defaultTargetPlatform == TargetPlatform.iOS);

  bool get _android => widget.android ?? Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_changed);
    // A desktop page's own ×: Back for this screen.
    _pageBacks = ExtensionPages.shared.backs.where((session) => session == widget.session.id).listen((_) => _back());
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_changed);
    unawaited(_pageBacks?.cancel());
    _backWindow?.cancel();
    _escape?.cancel();
    _closeButton?.cancel();
    if (_entered != null) _toDevice(_device.leave);
    super.dispose();
  }

  void _toDevice(Future<void> Function() call) {
    _deviceCalls = _deviceCalls.then((_) => call()).catchError((Object _) {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the background (Review Focus 3): the bars, the wakelock and the orientation asked for again; not as the
    // view goes, or in the engine's grace before it ends the screen, when no window asks for them: it gives them back.
    if (state == AppLifecycleState.resumed && _entered != null && !_leaving && _window != null) {
      _entered = null;
      _enter();
    }
  }

  UiWindow? get _window {
    final index = fullScreenIndex(widget.session.windows);
    return index == null ? null : widget.session.windows[index];
  }

  void _changed() {
    if (!mounted) return;
    final session = widget.session;
    // Gone once the screen ends, or once no window asks for the whole screen (what's left shows in the sheet).
    if (session.closed || (session.windows.isNotEmpty && _window == null)) {
      if (_leaving) return;
      setState(() => _leaving = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final route = mounted ? ModalRoute.of(context) : null;
        if (route != null && route.isActive) Navigator.of(context).removeRoute(route);
      });
      return;
    }
    _enter();
    _pagesFullScreen();
    setState(() {});
  }

  /// The JVM's pages in the full-screen window get a full-screen page's script, those opened before their window asked
  /// for the whole screen too: on a desktop their own × is the way out (Phase 7c's §2). Android's are the extension's
  /// own WebViews.
  void _pagesFullScreen() {
    final window = _window;
    if (_android || window == null) return;
    for (final page in _pagesIn(window.root)) {
      unawaited(ExtensionPages.shared.fullScreen(widget.session.id, page.id));
    }
  }

  static Iterable<UiNode> _pagesIn(UiNode node) sync* {
    if (node.kind == UiKind.page) yield node;
    for (final child in node.children) {
      yield* _pagesIn(child);
    }
  }

  /// Asks the device for what the full-screen window wants, again whenever that changes.
  void _enter() {
    final window = _window;
    if (window == null) return;
    final asked = '${window.id}/${window.orientation}/${window.keepScreenOn}';
    if (_entered == asked) return;
    _entered = asked;
    final iPhone =
        widget.iPhone ?? (defaultTargetPlatform == TargetPlatform.iOS && MediaQuery.sizeOf(context).shortestSide < 600);
    final keepScreenOn = window.keepScreenOn;
    final orientations = iPhone ? orientationsFor(window.orientation) : null;
    _toDevice(() => _device.enter(keepScreenOn: keepScreenOn, orientations: orientations));
  }

  /// Back to the top window. A second to the same window within [ExtensionFullScreen.escapeAfter], and that window
  /// still there [ExtensionFullScreen.escapeAfter] later, is closed by force: one that swallows Back.
  void _back() {
    final windows = widget.session.windows;
    if (windows.isEmpty) return;
    final top = windows.last.id;
    final second = _backedRecently == top;
    _backedRecently = top;
    _backWindow?.cancel();
    _backWindow = Timer(ExtensionFullScreen.escapeAfter, () => _backedRecently = null);
    unawaited(widget.session.close());
    if (!second) return;
    _escape?.cancel();
    _escape = Timer(ExtensionFullScreen.escapeAfter, () {
      if (!mounted || widget.session.closed) return;
      final stays = widget.session.windows.where((window) => window.id == top).firstOrNull;
      if (stays != null) unawaited(widget.session.act(stays.root.id, 'close', 'force'));
    });
  }

  void _mouseMoved() {
    _closeButton?.cancel();
    _closeButton = Timer(ExtensionFullScreen.closeButtonFor, () {
      if (mounted) setState(() => _showClose = false);
    });
    if (!_showClose) setState(() => _showClose = true);
  }

  static bool _holdsPage(UiNode node) => node.kind == UiKind.page || node.children.any(_holdsPage);

  static int _pages(UiNode node) =>
      (node.kind == UiKind.page ? 1 : 0) + node.children.fold(0, (n, child) => n + _pages(child));

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final index = fullScreenIndex(session.windows);
    final window = index == null ? null : session.windows[index];
    final above = index == null ? const <UiWindow>[] : session.windows.sublist(index + 1);
    final padding = MediaQuery.paddingOf(context);
    final strip = _ios ? math.max(ExtensionFullScreen.edgeStrip, padding.left) : 0.0;
    final isPage = window != null && _pages(window.root) == 1;
    // SkyStream's × on desktops, but over a page that's the top window: its own serves, and steps aside with it.
    final drawsClose = _desktop && !(isPage && above.isEmpty);
    return PopScope(
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        // A page's own colours fill it; anything else reads on the app's own background.
        backgroundColor: isPage ? Colors.black : null,
        body: Semantics(
          label: widget.title,
          child: MouseRegion(
            onHover: drawsClose ? (_) => _mouseMoved() : null,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (window != null)
                  Padding(
                    padding: EdgeInsets.only(left: strip, right: _ios ? padding.right : 0),
                    child: ExcludeFocus(
                      excluding: above.isNotEmpty,
                      child: isPage
                          ? _Fill(node: window.root, session: session, android: widget.android)
                          : SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: UiNodeView(node: window.root, session: session),
                            ),
                    ),
                  ),
                if (_ios)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: strip,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) => _drag = 0,
                      onHorizontalDragUpdate: (details) => _drag += details.delta.dx,
                      onHorizontalDragEnd: (details) {
                        if (_drag > 40 || (details.primaryVelocity ?? 0) > 300) _back();
                      },
                    ),
                  ),
                for (final dialog in above)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
                      child: Card(
                        child: FocusScope(
                          autofocus: dialog == above.last,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: UiNodeView(node: dialog.root, session: session),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (drawsClose && _showClose)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton.filledTonal(icon: const Icon(Icons.close_rounded), onPressed: _back),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A window with one page: the way down to it takes all the room, everything else its own size (Phase 7c's §2).
class _Fill extends StatelessWidget {
  const _Fill({required this.node, required this.session, this.android});

  final UiNode node;
  final ExtensionUiSession session;
  final bool? android;

  @override
  Widget build(BuildContext context) {
    if (node.kind == UiKind.page) {
      return ExtensionPageView(node: node, session: session, fill: true, autofocus: true, android: android);
    }
    final children = [
      for (final child in node.children)
        if (_ExtensionFullScreenState._holdsPage(child))
          Expanded(
            child: _Fill(node: child, session: session, android: android),
          )
        else
          UiNodeView(node: child, session: session),
    ];
    return node.kind == UiKind.row
        ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
