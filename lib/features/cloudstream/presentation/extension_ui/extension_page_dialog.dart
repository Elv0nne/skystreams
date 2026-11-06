import 'dart:async';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/focus/text_field_keys.dart';

/// A page's own alert, confirm or prompt, which its extension's chrome client left to the app (Phase 7c's §8), shown
/// as Android's WebView shows one: its message, a prompt's field with its default text, OK, and Cancel but for an alert.
/// Back, Esc or a tap outside cancels it, and it closes by itself, cancelled, when [gone] completes (its page went).
Future<({bool accept, String? text})> showExtensionPageDialog(
  BuildContext context,
  PageDialog dialog, {
  Future<void>? gone,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<({bool accept, String? text})>(
    context: context,
    builder: (_) => _PageDialog(dialog: dialog),
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  final answer = Completer<({bool accept, String? text})>();
  void finish(({bool accept, String? text})? result) {
    if (!answer.isCompleted) answer.complete(result ?? (accept: false, text: null));
  }

  // Its buttons, Back, Esc, a tap outside; or removed when its page went, which no pop reports.
  unawaited(navigator.push(route).then(finish));
  unawaited(route.completed.then((_) => finish(null)));
  unawaited(
    gone?.then((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    }),
  );
  return answer.future;
}

class _PageDialog extends StatefulWidget {
  const _PageDialog({required this.dialog});

  final PageDialog dialog;

  @override
  State<_PageDialog> createState() => _PageDialogState();
}

class _PageDialogState extends State<_PageDialog> {
  /// A prompt's field, with its default text.
  TextEditingController? _field;

  /// A remote's way out of a prompt's field and back into its keyboard - see [remoteTextFieldKeys].
  final FocusNode _fieldFocus = FocusNode(onKeyEvent: remoteTextFieldKeys);

  @override
  void initState() {
    super.initState();
    if (widget.dialog.kind == DialogKind.prompt) {
      _field = TextEditingController(text: widget.dialog.defaultText ?? '');
    }
  }

  @override
  void dispose() {
    _field?.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _answer(bool accept) => Navigator.of(context).pop((accept: accept, text: accept ? _field?.text : null));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final field = _field;
    return AlertDialog(
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.dialog.message),
          if (field != null) TextField(controller: field, focusNode: _fieldFocus, autofocus: true, onSubmitted: (_) => _answer(true)),
        ],
      ),
      actions: [
        if (widget.dialog.kind != DialogKind.alert)
          TextButton(onPressed: () => _answer(false), child: Text(l10n.cancel)),
        TextButton(autofocus: field == null, onPressed: () => _answer(true), child: Text(l10n.ok)),
      ],
    );
  }
}
