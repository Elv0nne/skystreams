/// A remote's way in and out of a single-line text field.
///
/// A text field swallows the arrow keys: Flutter's directional focus stands
/// down while one has focus, so the up and down that move focus everywhere
/// else do nothing there. On a television, with the keyboard put away, that
/// left a remote with no way out of the field - and, in a dialog, no way to
/// its Save.
///
/// While a keyboard is up the arrows are the keyboard's: Android TV's walks
/// its letter grid with all four, and taking them would move focus out of the
/// field and close it mid-word. So the up and down that leave the field are
/// taken only while it is down, and Select - OK on a remote - brings it back,
/// the way a television's own text boxes open theirs - as does the A of a
/// game controller paired with one. Every other key is left to the field.
///
/// Only Android's keyboards take the arrows, though - see
/// [deferToSoftKeyboard].
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A [FocusNode.onKeyEvent] for a single-line text field's own node.
KeyEventResult remoteTextFieldKeys(FocusNode node, KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
    return KeyEventResult.ignored;
  }
  if (deferToSoftKeyboard(node)) return KeyEventResult.ignored;

  final key = event.logicalKey;
  if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
    node.focusInDirection(
      key == LogicalKeyboardKey.arrowDown
          ? TraversalDirection.down
          : TraversalDirection.up,
    );
    return KeyEventResult.handled;
  }
  return reopenTextFieldKeyboard(node, event);
}

/// Whether the keys belong to an on-screen keyboard covering the focused text
/// field, so the field must leave them alone.
///
/// Only on Android, where a television's keyboard walks its letter grid with
/// the D-pad. No other platform's keyboard uses the arrows - and an iPad with
/// a hardware keyboard reports its shortcuts bar as a docked keyboard, which
/// would leave the arrows doing nothing.
///
/// Read the view, not a nested MediaQuery: dialogs and scaffolds can consume
/// the keyboard inset before it reaches their children. A keyboard that floats
/// over the app reports no inset at all - Gboard for TV does - but it keeps
/// the D-pad to itself while it is up, so a false here costs nothing.
bool deferToSoftKeyboard(FocusNode node) {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  final context = node.context;
  return context != null && context.mounted && _keyboardUp(context);
}

/// Brings back the keyboard of the field [node] belongs to, put away with
/// Back: Select is OK on a remote, and a game controller's A does the same.
///
/// Enter is left to the field, which submits with it; while a keyboard is up
/// every key is the keyboard's.
KeyEventResult reopenTextFieldKeyboard(FocusNode node, KeyEvent event) {
  if (event is! KeyDownEvent ||
      (event.logicalKey != LogicalKeyboardKey.select &&
          event.logicalKey != LogicalKeyboardKey.gameButtonA)) {
    return KeyEventResult.ignored;
  }
  final context = node.context;
  if (context == null || !context.mounted || _keyboardUp(context)) {
    return KeyEventResult.ignored;
  }
  final editable = context.findAncestorStateOfType<EditableTextState>();
  if (editable == null) return KeyEventResult.ignored;
  editable.requestKeyboard();
  return KeyEventResult.handled;
}

/// Whether a soft keyboard covers part of the window.
///
/// Read off the window rather than [MediaQuery]: a dialog and a [Scaffold]
/// each take the keyboard's inset out of what they hand their children, so a
/// field inside either always sees none.
bool _keyboardUp(BuildContext context) =>
    (View.maybeOf(context)?.viewInsets.bottom ?? 0) > 0;
