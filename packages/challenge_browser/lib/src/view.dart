import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'browser.dart';
import 'events.dart';
import 'messages.g.dart';

const _viewType = 'dev.akash.challenge_browser/page';

/// Shows [browser]'s page in the widget tree, as it is: shown pages aren't reloaded, so a person
/// continues whatever the page was doing.
///
/// Keyboard and D-pad focus treat the page as one control: Tab, Shift+Tab and the arrow keys move
/// into it like any other, and back out of it when they reach its edge.
///
/// Android, iOS and macOS show the page as a platform view. Windows and Linux have none, so the
/// page's own window is placed over this widget's rectangle: draw nothing over it there.
class ChallengeBrowserView extends StatefulWidget {
  const ChallengeBrowserView({
    super.key,
    required this.browser,
    this.autofocus = false,
    this.dpadInTabOrder = false,
    this.gestureRecognizers = const <Factory<OneSequenceGestureRecognizer>>{},
  });

  final ChallengeBrowser browser;

  /// Moves focus into the page once it shows: on a TV, the D-pad then starts inside the page.
  final bool autofocus;

  /// Android: the D-pad moves through the page's controls in their focus order, as Tab and
  /// Shift+Tab do, instead of to the nearest control in its direction. Movement by position skips
  /// controls inside a closed shadow root, such as Cloudflare's checkbox; it suits pages laid out as
  /// grids, and games that read the arrow keys themselves.
  final bool dpadInTabOrder;

  /// The gestures the page takes for itself, as a platform view's: none by default. Inside a scroll view, an
  /// [EagerGestureRecognizer] lets the page scroll itself.
  final Set<Factory<OneSequenceGestureRecognizer>> gestureRecognizers;

  @override
  State<ChallengeBrowserView> createState() => _ChallengeBrowserViewState();
}

class _ChallengeBrowserViewState extends State<ChallengeBrowserView> {
  static final PageHostApi _host = PageHostApi();

  late final FocusNode _desktopFocus = FocusNode(debugLabel: 'ChallengeBrowserView');

  /// Not a stop of its own: it hears focus arriving anywhere inside, platform view or not.
  late final FocusNode _around = FocusNode(canRequestFocus: false, skipTraversal: true);
  StreamSubscription<BrowserEvent>? _events;

  /// Which way focus was travelling: set from the last key, so a page entered with Shift+Tab or
  /// D-pad up starts at its last control.
  bool _forward = true;

  /// When the page last took focus by itself, from a touch or click: Flutter's focus follows it
  /// there, and mustn't move the page's own focus back to its first control.
  DateTime _pageFocusedAt = DateTime(0);

  /// The page has the keyboard. Flutter then gets only the keys the page passes on, or none.
  bool _inPage = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_noteDirection);
    _listen();
    if (widget.autofocus) WidgetsBinding.instance.addPostFrameCallback((_) => _autofocus(60));
  }

  @override
  void didUpdateWidget(ChallengeBrowserView old) {
    super.didUpdateWidget(old);
    if (old.browser != widget.browser) _listen();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_noteDirection);
    _events?.cancel();
    _desktopFocus.dispose();
    _around.dispose();
    super.dispose();
  }

  /// Moves Flutter's focus onto the page, and with it the page's own: the same way Tab would, after
  /// any platform view has its focus node, which it makes once its native view exists. Tries for up
  /// to [frames] frames.
  void _autofocus(int frames) {
    if (!mounted || widget.browser.isDisposed) return;
    final node = _around.descendants.where((node) => node.canRequestFocus).firstOrNull;
    if (node != null) return node.requestFocus();
    if (frames > 0) WidgetsBinding.instance.addPostFrameCallback((_) => _autofocus(frames - 1));
  }

  void _listen() {
    _events?.cancel();
    _events = widget.browser.events.listen((event) {
      switch (event) {
        case FocusExit(:final direction):
          _inPage = false;
          _leave(direction);
        case PageFocused():
          _inPage = true;
          _follow();
        case PageBlurred():
          _inPage = false;
        default:
      }
    });
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
    if (widget.browser.isDisposed) return;
    if (!focused) {
      // Flutter's focus moved elsewhere, by a click on another control or by the app: so do the keys.
      if (_inPage) _host.blur(widget.browser.id);
      _inPage = false;
      return;
    }
    _inPage = true;
    // A touch or click already put focus in the page, where the person wants it.
    if (DateTime.now().difference(_pageFocusedAt) < const Duration(milliseconds: 500)) return;
    _host.focus(widget.browser.id, _forward);
  }

  /// The page took focus from a click that Flutter didn't see: Flutter's focus moves onto the page,
  /// so Tab carries on from there.
  void _follow() {
    if (_around.hasFocus) return;
    _pageFocusedAt = DateTime.now();
    _around.descendants.where((node) => node.canRequestFocus).firstOrNull?.requestFocus();
  }

  /// Keys go to the page while it has the keyboard. Flutter sees them first on Android, and the keys a
  /// page passes on elsewhere; its Tab, arrow, Enter and Space shortcuts would otherwise act instead
  /// of the page's own controls. The page reports where focus leaves it ([FocusExit]). Escape stays
  /// with Flutter, to close what shows the page.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) =>
      !_inPage || event.logicalKey == LogicalKeyboardKey.escape
      ? KeyEventResult.ignored
      : KeyEventResult.skipRemainingHandlers;

  /// The page has no more controls in [direction]: Flutter's focus moves on from here.
  void _leave(FocusDirection direction) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || !mounted) return;
    switch (direction) {
      case FocusDirection.forward:
        node.nextFocus();
      case FocusDirection.backward:
        node.previousFocus();
      case FocusDirection.up:
        node.focusInDirection(TraversalDirection.up);
      case FocusDirection.down:
        node.focusInDirection(TraversalDirection.down);
      case FocusDirection.left:
        node.focusInDirection(TraversalDirection.left);
      case FocusDirection.right:
        node.focusInDirection(TraversalDirection.right);
    }
  }

  @override
  Widget build(BuildContext context) {
    final params = <String, Object?>{'pageId': widget.browser.id};
    final Widget page = switch (defaultTargetPlatform) {
      TargetPlatform.android => PlatformViewLink(
        viewType: _viewType,
        surfaceFactory: (context, controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: widget.gestureRecognizers,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        ),
        // Hybrid composition: the page is a real view in the window, so the D-pad, accessibility
        // services and text input reach it as they would any Android view.
        onCreatePlatformView: (params) =>
            PlatformViewsService.initExpensiveAndroidView(
                id: params.id,
                viewType: _viewType,
                layoutDirection: Directionality.of(context),
                creationParams: {'pageId': widget.browser.id, 'dpadInTabOrder': widget.dpadInTabOrder},
                creationParamsCodec: const StandardMessageCodec(),
                onFocus: () => params.onFocusChanged(true),
              )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create(),
      ),
      TargetPlatform.iOS => UiKitView(
        viewType: _viewType,
        gestureRecognizers: widget.gestureRecognizers,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      TargetPlatform.macOS => AppKitView(
        viewType: _viewType,
        gestureRecognizers: widget.gestureRecognizers,
        creationParams: params,
        creationParamsCodec: const StandardMessageCodec(),
      ),
      _ => Focus(
        focusNode: _desktopFocus,
        child: _PageFrame(browser: widget.browser),
      ),
    };
    return Focus(
      focusNode: _around,
      onFocusChange: _onFocusChange,
      onKeyEvent: _onKeyEvent,
      child: Listener(onPointerDown: (_) => _pageFocusedAt = DateTime.now(), child: page),
    );
  }
}

/// Windows and Linux: places the page's own window over this widget's rectangle, and hides it when
/// the widget goes.
class _PageFrame extends LeafRenderObjectWidget {
  const _PageFrame({required this.browser});

  final ChallengeBrowser browser;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPageFrame(browser);

  @override
  void updateRenderObject(BuildContext context, _RenderPageFrame renderObject) => renderObject.browser = browser;
}

class _RenderPageFrame extends RenderBox {
  _RenderPageFrame(this._browser);

  static final PageHostApi _host = PageHostApi();

  ChallengeBrowser _browser;
  Rect? _sent;
  bool _scheduled = false;

  set browser(ChallengeBrowser value) {
    if (value == _browser) return;
    _hide();
    _browser = value;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void paint(PaintingContext context, Offset offset) {
    // Painting nothing: the page's window covers this rectangle. Where it is in the view only
    // settles during paint, so it is sent after the frame.
    final rect = localToGlobal(Offset.zero) & size;
    if (rect == _sent || _scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!attached || _browser.isDisposed) return;
      final now = localToGlobal(Offset.zero) & size;
      if (now == _sent) return;
      _sent = now;
      _host.setFrame(_browser.id, PageFrame(left: now.left, top: now.top, width: now.width, height: now.height));
    });
  }

  @override
  void detach() {
    _hide();
    super.detach();
  }

  void _hide() {
    if (_sent == null) return;
    _sent = null;
    if (!_browser.isDisposed) _host.setFrame(_browser.id, null);
  }
}
