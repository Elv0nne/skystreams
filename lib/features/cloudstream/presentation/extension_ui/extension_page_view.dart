import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../../core/cloudstream/extension_ui/extension_pages.dart';
import '../../../../core/cloudstream/extension_ui/extension_ui_session.dart';
import '../../../../core/cloudstream/extension_ui/ui_tree.dart';
import '../../../../l10n/generated/app_localizations.dart';

/// The page an extension's window shows (the spec's §9), where its node is: on Android the extension's own WebView,
/// lent by the cs3_engine plugin; elsewhere the page the app opened for it ([ExtensionPages]). Shown only while its
/// window is the top one: on Windows and Linux a page is a window of its own, drawn over anything on top of it.
class ExtensionPageView extends StatelessWidget {
  const ExtensionPageView({
    super.key,
    required this.node,
    required this.session,
    this.pages,
    this.android,
    this.nativeWindow,
    this.fill = false,
    this.autofocus = false,
  });

  final UiNode node;
  final ExtensionUiSession session;

  /// The JVM engine's pages: [ExtensionPages.shared] unless a test gives its own.
  final ExtensionPages? pages;

  /// Whether the engine is Android's, which lends the extension's own WebView: [Platform.isAndroid] unless a test says.
  final bool? android;

  /// Whether the page is a window of its own over the app (Windows, Linux), which no scroll view clips: it shows only
  /// while wholly in view. Whether the app runs on Windows or Linux unless a test says - read off
  /// [defaultTargetPlatform], not the host, so a test sees the same page on every machine it runs on.
  final bool? nativeWindow;

  /// In the full-screen view: the page takes all the room it's given, with no padding (Phase 7c's §2).
  final bool fill;

  /// Takes the keyboard and the D-pad as it shows: the full-screen view's page (Phase 7c's §2).
  final bool autofocus;

  /// The page's height: half the screen's, between 300 and 440 logical pixels, and within [room] (the visible height
  /// of the scroll area it's in) leaving room for its window's own words and buttons. When the room is short, never
  /// more than half of it: the rest scrolls the window by touch, which a page's own drags don't.
  static double heightFor(Size screen, {double? room}) {
    final height = (screen.height * 0.5).clamp(300.0, 440.0);
    if (room == null || !room.isFinite) return height;
    return math.min(height, math.max(room - _reserve, room / 2));
  }

  /// A page window's own words and buttons, about: a heading, a line, a row of buttons, and the paddings.
  static const _reserve = 180.0;

  /// The page scrolls itself: in the sheet's scroll view its drags are its own.
  static final _ownGestures = <Factory<OneSequenceGestureRecognizer>>{
    const Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
  };

  @override
  Widget build(BuildContext context) {
    final Widget page;
    if (!_onTop) {
      page = const SizedBox.expand(key: ValueKey('extension-page-placeholder'));
    } else if (android ?? Platform.isAndroid) {
      page = _LentPage(node: node.id, session: session, autofocus: autofocus);
    } else {
      final pages = this.pages ?? ExtensionPages.shared;
      page = ListenableBuilder(listenable: pages, builder: (context, _) => _jvmPage(context, pages));
    }
    if (fill) return page;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: heightFor(MediaQuery.sizeOf(context), room: ExtensionPageRoom.of(context)),
        child: page,
      ),
    );
  }

  bool get _onTop {
    final windows = session.windows;
    return windows.isNotEmpty && _holds(windows.last.root, node.id);
  }

  static bool _holds(UiNode root, int id) => root.id == id || root.children.any((child) => _holds(child, id));

  Widget _jvmPage(BuildContext context, ExtensionPages pages) {
    if (pages.failedAt(session.id, node.id)) {
      return ListTile(
        leading: const Icon(Icons.info_outline),
        title: Text(AppLocalizations.of(context)!.extensionSheetCantShow),
      );
    }
    final page = pages.at(session.id, node.id);
    if (page == null) return const Center(child: CircularProgressIndicator());
    final key = ValueKey('extension-page-${page.rid}');
    final browser = page.browser.challenge;
    if (nativeWindow ??
        (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux)) {
      // SkyStream's dialog for a page (Phase 7c's §8) shows in Flutter's view, which a page that is a window of its
      // own would cover: every page steps aside while one shows.
      if (pages.showsDialog) {
        return ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: const SizedBox.expand());
      }
      return _WhollyInView(
        child: browser == null
            ? KeyedSubtree(
                key: key,
                child: const ColoredBox(color: Colors.white),
              )
            : ChallengeBrowserView(key: key, browser: browser, autofocus: autofocus, gestureRecognizers: _ownGestures),
      );
    }
    if (browser == null) {
      return KeyedSubtree(
        key: key,
        child: const ColoredBox(color: Colors.white),
      );
    }
    return ChallengeBrowserView(key: key, browser: browser, autofocus: autofocus, gestureRecognizers: _ownGestures);
  }
}

/// Shows [child] (a page that is a window of its own) only while it's wholly inside the scroll area it's in, and a
/// placeholder otherwise: a native window isn't clipped, and would cover the sheet's header or hang past its edge.
class _WhollyInView extends StatefulWidget {
  const _WhollyInView({required this.child});

  final Widget child;

  @override
  State<_WhollyInView> createState() => _WhollyInViewState();
}

class _WhollyInViewState extends State<_WhollyInView> {
  ScrollPosition? _position;
  bool _inView = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _position) {
      _position?.removeListener(_check);
      _position = position?..addListener(_check);
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_check);
    super.dispose();
  }

  /// After each layout and scroll: whether this box lies wholly within its scroll area's (or, with none, the view's).
  void _check() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final area = Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    final bounds = area != null && area.hasSize
        ? area.localToGlobal(Offset.zero) & area.size
        : Offset.zero & MediaQuery.sizeOf(context);
    final inView = bounds.inflate(0.5).contains(rect.topLeft) && bounds.inflate(0.5).contains(rect.bottomRight);
    if (inView != _inView) setState(() => _inView = inView);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    return _inView
        ? widget.child
        : ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: const SizedBox.expand());
  }
}

/// The visible height of the scroll area a page shows in (the sheet's body, or a window on top's), for its height.
class ExtensionPageRoom extends InheritedWidget {
  const ExtensionPageRoom({super.key, required this.height, required super.child});

  final double height;

  static double? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ExtensionPageRoom>()?.height;

  @override
  bool updateShouldNotify(ExtensionPageRoom oldWidget) => oldWidget.height != height;
}

/// Android: the extension's own WebView, lent to this platform view by the cs3_engine plugin, which puts it back in
/// its window when this goes. Keyboard and D-pad focus treat it as one control, as [ChallengeBrowserView]'s do.
class _LentPage extends StatefulWidget {
  const _LentPage({required this.node, required this.session, this.autofocus = false});

  final int node;
  final ExtensionUiSession session;

  /// The full-screen view's page: it takes the D-pad and the keyboard once its view is made.
  final bool autofocus;

  @override
  State<_LentPage> createState() => _LentPageState();
}

class _LentPageState extends State<_LentPage> {
  static const _viewType = 'cs3_engine/page';

  /// Not a stop of its own: it hears focus arriving anywhere inside.
  late final FocusNode _around = FocusNode(canRequestFocus: false, skipTraversal: true);
  StreamSubscription<({int node, String direction})>? _exits;

  /// Which way focus was travelling, from the last key: a page entered backwards starts at its last control.
  bool _forward = true;

  /// The page has the keyboard: Flutter's shortcuts leave its keys alone.
  bool _inPage = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_noteDirection);
    _exits = widget.session.pageExits.where((exit) => exit.node == widget.node).listen((exit) {
      _inPage = false;
      _leave(exit.direction);
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_noteDirection);
    unawaited(_exits?.cancel());
    _around.dispose();
    super.dispose();
  }

  bool _noteDirection(KeyEvent event) {
    if (event is KeyDownEvent) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.tab) {
        _forward = !HardwareKeyboard.instance.isShiftPressed;
      } else if (key == LogicalKeyboardKey.arrowUp || key == LogicalKeyboardKey.arrowLeft) {
        _forward = false;
      } else if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowRight) {
        _forward = true;
      }
    }
    return false;
  }

  void _onFocusChange(bool focused) {
    if (!focused) {
      if (_inPage) widget.session.blurPage(widget.node);
      _inPage = false;
      return;
    }
    _inPage = true;
    widget.session.focusPage(widget.node, forward: _forward);
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) =>
      !_inPage || event.logicalKey == LogicalKeyboardKey.escape
      ? KeyEventResult.ignored
      : KeyEventResult.skipRemainingHandlers;

  void _leave(String direction) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || !mounted) return;
    switch (direction) {
      case 'backward':
        node.previousFocus();
      case 'up':
        node.focusInDirection(TraversalDirection.up);
      case 'down':
        node.focusInDirection(TraversalDirection.down);
      case 'left':
        node.focusInDirection(TraversalDirection.left);
      case 'right':
        node.focusInDirection(TraversalDirection.right);
      default:
        node.nextFocus();
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _around,
    onFocusChange: _onFocusChange,
    onKeyEvent: _onKeyEvent,
    child: PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: ExtensionPageView._ownGestures,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      // Hybrid composition: the page is a real view in the window, so the D-pad, accessibility services and text
      // input reach it as they would any Android view.
      onCreatePlatformView: (params) =>
          PlatformViewsService.initExpensiveAndroidView(
              id: params.id,
              viewType: _viewType,
              layoutDirection: Directionality.of(context),
              // The full-screen view's page keeps the D-pad and the keyboard: Back is its way out.
              creationParams: {'session': widget.session.id, 'node': widget.node, 'keepFocus': widget.autofocus},
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () => params.onFocusChanged(true),
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..addOnPlatformViewCreatedListener((_) {
              // The full-screen view's page takes the D-pad and the keyboard at once: focus goes in once the view is in
              // the tree (the frame after it's created), the way a person's would.
              if (!widget.autofocus) return;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _around.descendants.firstOrNull?.requestFocus();
              });
            })
            ..create(),
    ),
  );
}
