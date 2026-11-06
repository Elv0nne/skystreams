/// One focus affordance for the whole application, and one rule for when it is
/// allowed on screen.
///
/// Two separate questions live here, and the app used to answer both of them
/// twenty-one different ways.
///
/// WHEN. A focus indicator is for the person driving the app without a
/// pointer - a television remote, a keyboard, a game controller. Drawn for
/// someone who just tapped the screen or clicked the mouse it is noise, and
/// worse, it is noise that *stays*: the last thing touched keeps a ring around
/// it for the rest of the session. Every platform has settled on the same
/// answer, which the web spells `:focus-visible` - show the indicator when the
/// last input was a key, hide it the moment a pointer goes down.
/// [FocusVisibilityScope] is that rule, installed once at the root of the app;
/// [FocusVisibility.of] is how a widget asks, and [FocusVisibility.visible]
/// how a theme's style resolver - which has no context - does.
///
/// Having focus is not the same as showing it. Focus moves under a thumb too:
/// a button autofocused for the remote, a route handing focus back to the
/// control that opened it, a text field tapped inside a card. None of that is
/// a reason to draw a ring for someone who is touching the screen, so nothing
/// in the app draws one from `hasFocus` alone - every indicator asks here.
///
/// Flutter's own [FocusManager.highlightMode] is close but not the same thing:
/// it distinguishes touch from "traditional", and a mouse is traditional. So a
/// desktop window with an autofocused button - the details page's Play button,
/// for one - lights up before the viewer has touched a key. That is the
/// complaint this file exists to answer, so the scope tracks the last input
/// itself and falls back to the highlight mode only where no scope is
/// installed (a widget test pumping one widget on its own).
///
/// WHAT. A **neutral ring**, two logical pixels, drawn outside the shape it
/// belongs to, plus a soft black shadow to lift it off whatever is behind.
/// Cards add a small scale. That is the Netflix and Prime Video convention and
/// it is the convention for a reason: an accent-coloured ring competes with
/// the artwork it surrounds, and a coloured glow wide enough to read from a
/// sofa is a coloured glow wide enough to look broken on a phone. The app used
/// to paint `colorScheme.primary` at three or four places at once - a 2-3 dp
/// accent border, an 18-24 % accent wash over the poster, and a 24 dp accent
/// blur behind it. This is one border and one shadow.
///
/// The ring is [ColorScheme.onSurface] rather than a literal white so the
/// light theme gets a dark ring instead of an invisible one.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Publishes whether focus indicators belong on screen right now.
///
/// Install one near the root of the app. Without it [FocusVisibility.of] falls
/// back to [FocusManager.highlightMode], which is the right answer for a test
/// that pumps a single widget and never builds the root.
///
/// The rule is the one browsers apply to `:focus-visible` and Android to its
/// touch mode: a press of a pointer - a finger, a mouse, a trackpad - hides
/// every indicator, and a key that moves or activates focus shows them. Keys
/// that do neither are not someone steering by focus, and must not light the
/// screen up: a phone's volume rocker, a media key, a shortcut held with
/// Ctrl, Alt or Cmd, a letter typed into a field.
class FocusVisibilityScope extends StatefulWidget {
  const FocusVisibilityScope({
    required this.child,
    this.television = false,
    super.key,
  });

  /// A television has no touch to hide focus from: focus shows from the first
  /// frame, as Android TV asks of every app, and only a pointer - an air
  /// mouse - hides it, until the next key.
  final bool television;

  final Widget child;

  @override
  State<FocusVisibilityScope> createState() => _FocusVisibilityScopeState();
}

class _FocusVisibilityScopeState extends State<FocusVisibilityScope> {
  /// Hidden until a key says otherwise, except on a television.
  late final ValueNotifier<bool> _visible = ValueNotifier<bool>(
    widget.television,
  );

  @override
  void initState() {
    super.initState();
    FocusVisibility._active = _visible;
    // From the first frame, not from the first input: Flutter's own default
    // on a desktop is `traditional`, which lit up every autofocused Material
    // control on a Mac before anyone had touched a key.
    _applyStrategy();
    // A global pointer route rather than a [Listener] in the tree: a Listener
    // only sees what reaches it, and a pointer swallowed by a platform view or
    // by a child that claims the gesture would never clear the ring.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointer);
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void didUpdateWidget(FocusVisibilityScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The device profile resolves a few frames after launch, so a television
    // can be learnt late. After the frame: the flip rebuilds what is focused,
    // which is not for the middle of this build.
    if (widget.television && !oldWidget.television) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _set(true);
      });
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handlePointer);
    HardwareKeyboard.instance.removeHandler(_handleKey);
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    if (identical(FocusVisibility._active, _visible)) {
      FocusVisibility._active = null;
    }
    _visible.dispose();
    super.dispose();
  }

  void _handlePointer(PointerEvent event) {
    // Only a press. Moving a mouse over the window does not mean the viewer has
    // stopped driving it from the keyboard, and neither does a scroll wheel -
    // the same rule every browser applies to `:focus-visible`.
    if (event is PointerDownEvent) _set(false);
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent && _steers(event)) _set(true);
    // Never handled: this is an observer, and returning true here would eat
    // every key in the application.
    return false;
  }

  /// Whether [event] is someone driving the app by focus: a key that moves it
  /// or activates what has it, pressed without Ctrl, Alt or Cmd - the
  /// modifiers that make a key a shortcut, as `:focus-visible` has them.
  static bool _steers(KeyDownEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    return _kSteeringKeys.contains(event.logicalKey);
  }

  /// A remote's D-pad arrives as the arrows and Select; a keyboard adds Tab,
  /// Enter, Space and the page keys; a game controller its face buttons.
  /// Everything else - volume, media, Back, Escape, letters - leaves the
  /// indicators as they were.
  static final Set<LogicalKeyboardKey> _kSteeringKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.gameButtonX,
    LogicalKeyboardKey.gameButtonY,
    LogicalKeyboardKey.gameButtonSelect,
    LogicalKeyboardKey.gameButtonStart,
  };

  void _set(bool value) {
    if (_visible.value == value) return;
    _visible.value = value;
    _applyStrategy();
    _rebuildFocusedButton();
  }

  /// Flutter's own Material controls answer to [FocusManager.highlightMode]
  /// rather than to this, so without it the app would run two rules at once:
  /// a focused [ElevatedButton] would wear this file's ring while the
  /// [InkWell] under it stayed dark. Pointing the framework's strategy at the
  /// same signal makes them one rule.
  ///
  /// It is also the more trustworthy signal on a television. Flutter decides
  /// `traditional` from key events, but it discards any Android key event
  /// whose device id is -1 as a soft-keyboard press - which is what an
  /// injected event and some network remotes look like - and stays in `touch`
  /// forever, with every Material focus highlight suppressed. [HardwareKeyboard]
  /// has no such filter.
  void _applyStrategy() {
    FocusManager.instance.highlightStrategy = _visible.value
        ? FocusHighlightStrategy.alwaysTraditional
        : FocusHighlightStrategy.alwaysTouch;
  }

  /// A Material button draws its ring from its own style ([AppFocus.buttonSide]),
  /// and a switch its focus icon from the theme's, each resolved when it
  /// rebuilds - and nothing rebuilds them when the answer here changes while
  /// they keep focus, so a ring would stay up under the next tap. Only the
  /// focused control can be wearing one, so that is the one rebuilt.
  void _rebuildFocusedButton() {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused is! Element || !focused.mounted) return;
    focused.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is! ButtonStyleButton && widget is! Switch) return true;
      element.markNeedsBuild();
      return false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FocusVisibility._(notifier: _visible, child: widget.child);
  }
}

/// The inherited half of [FocusVisibilityScope].
class FocusVisibility extends InheritedNotifier<ValueNotifier<bool>> {
  const FocusVisibility._({
    required ValueNotifier<bool> notifier,
    required super.child,
  }) : super(notifier: notifier);

  /// The installed scope's answer, for [visible].
  static ValueListenable<bool>? _active;

  /// Whether a focus indicator should be painted, rebuilding [context] when
  /// the answer changes.
  ///
  /// Falls back to Flutter's own highlight mode where no scope is installed,
  /// which keeps a widget pumped on its own behaving the way Material's
  /// built-in focus highlights do.
  static bool of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<FocusVisibility>();
    if (scope == null) {
      return FocusManager.instance.highlightMode != FocusHighlightMode.touch;
    }
    return scope.notifier?.value ?? false;
  }

  /// The same answer without a context, for a theme's style resolvers, which
  /// are handed a set of states and nothing else. It does not rebuild
  /// anything by itself: the scope rebuilds the one focused button whenever
  /// it changes.
  static bool get visible =>
      _active?.value ??
      FocusManager.instance.highlightMode != FocusHighlightMode.touch;
}

/// Whether [hasFocus] should be *shown* as focus in [context].
///
/// The whole conversion from "this node has focus" to "draw a ring" is this
/// one call, so a widget that already keeps a `_isFocused` field needs one line
/// changed rather than a new wrapper around its subtree.
bool showFocusIndicator(BuildContext context, bool hasFocus) =>
    hasFocus && FocusVisibility.of(context);

/// The tokens every focus indicator in the app is drawn from.
///
/// Held here rather than in the theme because two of them - the ring width and
/// the shadow - are geometry that callers fold into decorations they already
/// build, and a [ThemeExtension] would make every one of those call sites a
/// lookup for no gain.
abstract final class AppFocus {
  /// Ring thickness. Two logical pixels reads from a sofa at the 960 dp a
  /// television lays out in and is unremarkable on a phone.
  static const double ringWidth = 2;

  /// How long the ring takes to appear. Short enough to feel attached to the
  /// key press; long enough not to strobe when a D-pad is held down.
  static const Duration duration = Duration(milliseconds: 120);

  /// The ring colour: the theme's own foreground, so it is near-white on the
  /// dark theme and near-black on the light one, and never competes with the
  /// artwork the way an accent does.
  static Color ringColor(BuildContext context) =>
      ringColorOf(Theme.of(context).colorScheme);

  /// [ringColor] for a scheme rather than a context, which is what the theme
  /// itself has to work from.
  static Color ringColorOf(ColorScheme scheme) => scheme.onSurface;

  /// The focus ring as Material's button styles want it.
  ///
  /// Drawn OUTSIDE the button's shape. A filled button is already accent
  /// coloured, so a ring inside it would be a near-white line on a light blue
  /// pill - technically present and useless from a sofa. Outside, the same
  /// line sits on the page's own background and reads at ten feet.
  ///
  /// [unfocused] is what the button wears the rest of the time, and it has to
  /// be passed for [OutlinedButton]: a resolver is a single property, so one
  /// that answered null would take the outline off every unfocused outlined
  /// button in the app.
  ///
  /// Material reports [WidgetState.focused] whenever the button *has* focus,
  /// not only when focus should show - an autofocused button under a thumb is
  /// focused - so the ring also asks [FocusVisibility.visible].
  static WidgetStateProperty<BorderSide?> buttonSide(
    ColorScheme scheme, {
    BorderSide? unfocused,
  }) {
    return WidgetStateProperty.resolveWith<BorderSide?>((states) {
      if (!states.contains(WidgetState.focused) || !FocusVisibility.visible) {
        return unfocused;
      }
      return BorderSide(
        color: ringColorOf(scheme),
        width: ringWidth,
        strokeAlign: BorderSide.strokeAlignOutside,
      );
    });
  }

  /// The focus wash for the Material surfaces that take an overlay rather than
  /// a border - tabs, list rows, ink responses.
  ///
  /// Material resolves [WidgetState.focused] only when its own highlight rules
  /// say a focus highlight belongs on screen, which is why these do not need
  /// [FocusVisibility]: a touch never lands here.
  static WidgetStateProperty<Color?> overlay(ColorScheme scheme) {
    return WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.pressed)) {
        return ringColorOf(scheme).withValues(alpha: 0.12);
      }
      if (states.contains(WidgetState.focused)) {
        return ringColorOf(scheme).withValues(alpha: 0.16);
      }
      if (states.contains(WidgetState.hovered)) {
        return ringColorOf(scheme).withValues(alpha: 0.08);
      }
      return null;
    });
  }

  /// The ring, or null when [focused] is false.
  ///
  /// [outside] puts the stroke entirely beyond the shape's edge, which is what
  /// anything with content up to its own border wants - a poster loses two
  /// pixels off each side otherwise, and visibly shrinks as it gains focus.
  static Border? border(
    BuildContext context, {
    required bool focused,
    bool outside = false,
    double width = ringWidth,
    Color? color,
  }) {
    if (!focused) return null;
    return Border.all(
      color: color ?? ringColor(context),
      width: width,
      strokeAlign: outside
          ? BorderSide.strokeAlignOutside
          : BorderSide.strokeAlignInside,
    );
  }

  /// The same ring as a [BorderSide], for the Material button styles that take
  /// one rather than a [Border].
  ///
  /// Outside the shape by default, for the reason given on [buttonSide].
  static BorderSide side(
    BuildContext context, {
    required bool focused,
    bool outside = true,
  }) => focused
      ? BorderSide(
          color: ringColor(context),
          width: ringWidth,
          strokeAlign: outside
              ? BorderSide.strokeAlignOutside
              : BorderSide.strokeAlignInside,
        )
      : BorderSide.none;

  /// The lift under a focused element: a plain black shadow, not a coloured
  /// glow. It separates the ring from whatever is behind it without adding a
  /// second colour to the screen, and over this app's black surfaces it costs
  /// nothing because there is nothing for it to darken.
  ///
  /// Centred rather than offset downwards: these sit in horizontal rails that
  /// clip their viewports at a few logical pixels of padding, and a shadow
  /// with a drop would be cut off along one edge and not the other.
  static List<BoxShadow>? shadows({required bool focused}) => focused
      ? const <BoxShadow>[BoxShadow(color: Color(0x73000000), blurRadius: 12)]
      : null;

  /// A wash over a focused row, for list rows and panel rows where a ring
  /// around a full-width strip would be heavy. Deliberately the theme's
  /// foreground at a low alpha rather than the accent: the same neutral
  /// language as the ring.
  static Color rowTint(BuildContext context, {required bool focused}) => focused
      ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.14)
      : Colors.transparent;
}

/// Wraps [child] in the app's focus ring.
///
/// For the call sites that have no decoration of their own to fold the ring
/// into. Everything else takes [AppFocus.border] and [AppFocus.shadows] and
/// keeps the [Container] it already had, so the shape of the element tree does
/// not change with focus.
class FocusRing extends StatelessWidget {
  const FocusRing({
    required this.focused,
    required this.child,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
    this.outside = true,
    this.shadow = true,
    super.key,
  });

  /// Whether the wrapped subtree holds focus. Visibility is decided here, so
  /// pass the raw focus state.
  final bool focused;

  final BorderRadius? borderRadius;
  final BoxShape shape;

  /// Whether the stroke sits outside the child's bounds. See [AppFocus.border].
  final bool outside;

  final bool shadow;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final show = showFocusIndicator(context, focused);
    return AnimatedContainer(
      duration: AppFocus.duration,
      decoration: BoxDecoration(
        shape: shape,
        borderRadius: shape == BoxShape.circle ? null : borderRadius,
        border: AppFocus.border(context, focused: show, outside: outside),
        boxShadow: shadow ? AppFocus.shadows(focused: show) : null,
      ),
      child: child,
    );
  }
}
