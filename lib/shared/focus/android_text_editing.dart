/// Telling Android when a Flutter text field has focus.
///
/// Televisions built for low memory - Chromecast with Google TV among them -
/// give a keyboard a session only for a view that calls itself a text editor,
/// and Flutter's never does (flutter/flutter#177360). The keyboard still
/// opens, but the remote's D-pad never reaches it, so nothing can be typed.
/// On those devices the app's activity keeps a stand-in that does say so
/// (TextEditorProxy.kt), and this tells it when to.
///
/// On other televisions and phones the activity answers that it is not
/// needed, and nothing more is said. Other platforms are never asked.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

@visibleForTesting
const androidTextEditingChannel = MethodChannel(
  'dev.akash.skystream/text_input',
);

/// Starts reporting, where the device needs it. Returns what stops it again,
/// or null when nothing was started.
Future<VoidCallback?> installAndroidTextEditing() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  final bool needed;
  try {
    needed =
        await androidTextEditingChannel.invokeMethod<bool>('needed') ?? false;
  } on Object {
    return null;
  }
  if (!needed) return null;

  var editing = false;
  void report() {
    final now = _textFieldHoldsFocus();
    if (now == editing) return;
    editing = now;
    unawaited(
      androidTextEditingChannel
          .invokeMethod<void>('editing', now)
          .catchError((Object _) {}),
    );
  }

  FocusManager.instance.addListener(report);
  report();
  return () => FocusManager.instance.removeListener(report);
}

/// Whether the focus is in a field a keyboard types into: an [EditableText]
/// that owns the focus, is not read-only and wants a keyboard - the rule of
/// flutter/flutter#193074. A [SelectableText] is a read-only [EditableText].
///
/// [EditableText] builds the `Focus` that owns its node below itself, so it
/// is found by walking up.
bool _textFieldHoldsFocus() {
  final focus = FocusManager.instance.primaryFocus;
  final field = focus?.context?.findAncestorWidgetOfExactType<EditableText>();
  return field != null &&
      field.focusNode == focus &&
      !field.readOnly &&
      field.keyboardType != TextInputType.none;
}
