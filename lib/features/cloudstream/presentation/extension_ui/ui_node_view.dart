import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/cloudstream/extension_ui/extension_ui_session.dart';
import '../../../../core/cloudstream/extension_ui/ui_tree.dart';
import '../../../../shared/focus/text_field_keys.dart';
import 'extension_page_view.dart';

/// Draws an extension window's tree with SkyStream's own widgets and theme, never the extension's look,
/// and sends what the person does back to the extension through [session].
class UiNodeView extends StatelessWidget {
  const UiNodeView({super.key, required this.node, required this.session});

  final UiNode node;
  final ExtensionUiSession session;

  @override
  Widget build(BuildContext context) => _node(context, node);

  void _click(UiNode n) => unawaited(session.act(n.id, 'click'));

  Widget _node(BuildContext context, UiNode n) {
    if (n.isContainer) return _container(context, n);
    return switch (n.kind) {
      UiKind.text => _text(context, n),
      UiKind.button => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: FilledButton.tonal(onPressed: n.enabled ? () => _click(n) : null, child: Text(n.words ?? '')),
      ),
      UiKind.iconButton => _iconButton(n),
      UiKind.checkbox || UiKind.switchToggle || UiKind.radio => switch (n.words) {
        final words? => _toggle(n, title: words, subtitle: null),
        // No words of its own (they sit elsewhere in its row): the control alone.
        null => _control(n),
      },
      UiKind.field => UiField(key: _fieldKey(session, n.id), node: n, session: session),
      UiKind.dropdown => _dropdown(n),
      UiKind.slider => UiSlider(key: ValueKey('slider-${n.id}'), node: n, session: session),
      UiKind.progress => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(value: (n.max ?? 0) > 0 ? (n.value ?? 0) / n.max! : null),
      ),
      UiKind.image => n.tappable ? _iconButton(n) : const SizedBox.shrink(),
      UiKind.page => ExtensionPageView(key: _pageKey(session, n.id), node: n, session: session),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _container(BuildContext context, UiNode n) {
    final toggle = toggleRow(n);
    if (toggle != null) return _toggle(toggle.toggle, title: toggle.title, subtitle: toggle.subtitle);
    final tile = tappableTile(n);
    if (tile != null) {
      return ListTile(
        title: Text(tile.title),
        subtitle: tile.subtitle == null ? null : Text(tile.subtitle!),
        trailing: const Icon(Icons.chevron_right_rounded),
        enabled: n.enabled,
        onTap: () => _click(n),
      );
    }
    if (tappableImage(n) case final words?) return _iconButton(n, words: words);
    if (n.kind == UiKind.row) return _row(context, n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: _column(context, n.children),
    );
  }

  /// A row's children side by side: buttons wrap, weighted children share the width by weight.
  Widget _row(BuildContext context, UiNode n) {
    if (n.children.every((c) => c.kind == UiKind.button || c.kind == UiKind.iconButton)) {
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.end,
        children: [for (final child in n.children) _node(context, child)],
      );
    }
    // As Android lays it out, near enough: beside weighted children, a button, icon or picture keeps its
    // own size (a close button squeezed to nothing otherwise), and anything else gets a bounded share as
    // if its weight were 1 (tiles, fields and nested rows need a width to lay out in).
    final weighted = n.children.any((c) => c.weight != null);
    return Row(
      children: [
        for (final child in n.children)
          if (child.weight case final weight?)
            Expanded(flex: (weight * 100).round().clamp(1, 1000000), child: _node(context, child))
          else if (weighted && _sizesItself(child))
            _node(context, child)
          else
            Flexible(flex: weighted ? 100 : 1, child: _node(context, child)),
      ],
    );
  }

  /// A column's children in order; a plain text right before a field becomes the field's label.
  List<Widget> _column(BuildContext context, List<UiNode> nodes) {
    final out = <Widget>[];
    for (var i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final next = i + 1 < nodes.length ? nodes[i + 1] : null;
      if (next != null &&
          next.kind == UiKind.field &&
          n.kind == UiKind.text &&
          !n.tappable &&
          !n.heading &&
          n.words != null) {
        out.add(UiField(key: _fieldKey(session, next.id), node: next, session: session, label: n.words));
        i++;
        continue;
      }
      out.add(_node(context, n));
    }
    return out;
  }

  Widget _text(BuildContext context, UiNode n) {
    final words = n.text?.trim() ?? '';
    if (words.isEmpty) return const SizedBox.shrink();
    if (n.tappable) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(onPressed: n.enabled ? () => _click(n) : null, child: Text(words)),
      );
    }
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(words, style: n.heading ? theme.titleMedium : theme.bodyMedium),
    );
  }

  /// A button with an icon when [words] (the node's own by default) name one, else its words.
  Widget _iconButton(UiNode n, {String? words}) {
    final label = words ?? n.words;
    final onPressed = n.enabled ? () => _click(n) : null;
    final icon = iconFor(label);
    if (icon != null) return IconButton(tooltip: label, icon: Icon(icon), onPressed: onPressed);
    return TextButton(onPressed: onPressed, child: Text(label ?? '…'));
  }

  /// Kinds that are as wide as their content, needing no width from the row.
  static bool _sizesItself(UiNode n) =>
      n.kind == UiKind.button ||
      n.kind == UiKind.iconButton ||
      n.kind == UiKind.image ||
      (n.isToggle && n.words == null);

  /// A checkbox, switch or radio with its words: one row, a tap anywhere taps the toggle.
  Widget _toggle(UiNode toggle, {required String title, required String? subtitle}) {
    final onTap = toggle.enabled ? () => _click(toggle) : null;
    final control = switch (toggle.kind) {
      UiKind.switchToggle => Switch(value: toggle.checked, onChanged: onTap == null ? null : (_) => onTap()),
      UiKind.radio => Icon(toggle.checked ? Icons.radio_button_checked : Icons.radio_button_unchecked),
      _ => Checkbox(value: toggle.checked, onChanged: onTap == null ? null : (_) => onTap()),
    };
    final isSwitch = toggle.kind == UiKind.switchToggle;
    return ListTile(
      key: ValueKey('toggle-${toggle.id}'),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      leading: isSwitch ? null : control,
      trailing: isSwitch ? control : null,
      enabled: toggle.enabled,
      onTap: onTap,
    );
  }

  /// A checkbox, switch or radio without words: the control alone, as wide as itself.
  Widget _control(UiNode toggle) {
    final onTap = toggle.enabled ? () => _click(toggle) : null;
    return switch (toggle.kind) {
      UiKind.switchToggle => Switch(value: toggle.checked, onChanged: onTap == null ? null : (_) => onTap()),
      UiKind.radio => IconButton(
        icon: Icon(toggle.checked ? Icons.radio_button_checked : Icons.radio_button_unchecked),
        onPressed: onTap,
      ),
      _ => Checkbox(value: toggle.checked, onChanged: onTap == null ? null : (_) => onTap()),
    };
  }

  /// A dropdown as SkyStream's own settings draw one: a remote moves past it, and opens it with OK.
  Widget _dropdown(UiNode n) {
    final selected = n.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DropdownButtonFormField<int>(
        // Keyed by the selection: the extension can change it.
        key: ValueKey('dropdown-${n.id}-$selected'),
        initialValue: selected != null && selected >= 0 && selected < n.options.length ? selected : null,
        isExpanded: true,
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
        items: [
          for (var i = 0; i < n.options.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(n.options[i], overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: !n.enabled
            ? null
            : (index) {
                if (index != null && index != selected) unawaited(session.act(n.id, 'select', index));
              },
      ),
    );
  }
}

/// A toggle with one or two texts and nothing else (a checkbox and its label): one row. Null otherwise.
({UiNode toggle, String title, String? subtitle})? toggleRow(UiNode n) {
  if (n.kind != UiKind.row && n.kind != UiKind.column) return null;
  // A column holding only words counts as those words: a title and subtitle beside the toggle.
  final parts = [
    for (final c in n.children)
      if (c.kind == UiKind.column && c.children.isNotEmpty && c.children.every((t) => t.kind == UiKind.text))
        ...c.children
      else
        c,
  ];
  final toggles = [
    for (final c in parts)
      if (c.isToggle) c,
  ];
  final texts = [
    for (final c in parts)
      if (c.kind == UiKind.text && c.words != null) c,
  ];
  if (toggles.length != 1 || texts.isEmpty || texts.length > 2 || toggles.length + texts.length != parts.length) {
    return null;
  }
  final toggle = toggles.single;
  final own = toggle.words;
  return (
    toggle: toggle,
    title: own ?? texts.first.words!,
    subtitle: own != null ? texts.first.words : (texts.length > 1 ? texts[1].words : null),
  );
}

/// A tappable group of texts and pictures (a card): a list tile, its first text the title and its second
/// the subtitle. Null when it holds a control, or no text.
({String title, String? subtitle})? tappableTile(UiNode n) {
  if (!n.tappable || (n.kind != UiKind.row && n.kind != UiKind.column)) return null;
  final texts = <String>[];
  bool readable(UiNode c) {
    if (c.isContainer) return c.children.every(readable);
    if (c.kind == UiKind.text) {
      if (c.words case final words?) texts.add(words);
      return true;
    }
    return c.kind == UiKind.image || c.kind == UiKind.other;
  }

  if (!n.children.every(readable) || texts.isEmpty) return null;
  return (title: texts.first, subtitle: texts.length > 1 ? texts[1] : null);
}

/// A tappable group holding only pictures, one of them labelled (phisher98's "Save and Reload"): its
/// label, to show it as an icon button. Null otherwise.
String? tappableImage(UiNode n) {
  if (!n.tappable || !n.isContainer) return null;
  String? label;
  bool pictures(UiNode c) {
    if (c.isContainer) return c.children.every(pictures);
    if (c.kind != UiKind.image) return false;
    label ??= c.words;
    return true;
  }

  return n.children.isNotEmpty && n.children.every(pictures) ? label : null;
}

/// The Material icon an icon button's words name, if any: by whole words ("Feedback" isn't "back").
IconData? iconFor(String? words) {
  final found = {for (final m in RegExp('[a-z]+').allMatches(words?.toLowerCase() ?? '')) m[0]!};
  for (final (key, icon) in _icons) {
    if (found.contains(key) || found.contains('${key}s')) return icon;
  }
  return null;
}

const _icons = [
  ('save', Icons.save_outlined),
  ('close', Icons.close_rounded),
  ('dismiss', Icons.close_rounded),
  ('refresh', Icons.refresh_rounded),
  ('reload', Icons.refresh_rounded),
  ('delete', Icons.delete_outline),
  ('remove', Icons.delete_outline),
  ('clear', Icons.clear_all_rounded),
  ('add', Icons.add_rounded),
  ('edit', Icons.edit_outlined),
  ('search', Icons.search_rounded),
  ('setting', Icons.settings_outlined),
  ('info', Icons.info_outline),
  ('help', Icons.help_outline),
  ('back', Icons.arrow_back_rounded),
  ('done', Icons.check_rounded),
  ('copy', Icons.copy_rounded),
  ('share', Icons.share_outlined),
];

/// Each field's key, per session: a field the extension moves elsewhere in its window (an error appearing
/// beside it) keeps its focus and what's typed.
final _fieldKeys = Expando<Map<int, GlobalKey>>();

GlobalKey _fieldKey(ExtensionUiSession session, int id) =>
    (_fieldKeys[session] ??= {})[id] ??= GlobalKey(debugLabel: 'field $id');

final _pageKeys = Expando<Map<int, GlobalKey>>();

/// A page node's view keeps its state (and on Android its platform view) as the trees around it change.
GlobalKey _pageKey(ExtensionUiSession session, int id) =>
    (_pageKeys[session] ??= {})[id] ??= GlobalKey(debugLabel: 'page $id');

/// A text field the extension's field mirrors. Typing reaches the extension once the person pauses, and
/// the keyboard's action key submits. The extension's text shows when the person isn't in the field; in
/// it, only the extension's own changes do (a Reset), not its echo of what was typed.
class UiField extends StatefulWidget {
  const UiField({super.key, required this.node, required this.session, this.label});

  final UiNode node;
  final ExtensionUiSession session;
  final String? label;

  @override
  State<UiField> createState() => _UiFieldState();
}

class _UiFieldState extends State<UiField> {
  late final _controller = TextEditingController(text: widget.node.text ?? '');

  /// A remote's way out of a one-line field (see [remoteTextFieldKeys]); a multi-line one keeps its arrows.
  late final _focus = FocusNode(
    onKeyEvent: (node, event) =>
        widget.node.input == 'multiline' ? KeyEventResult.ignored : remoteTextFieldKeys(node, event),
  );

  /// What the person typed lately: the extension echoing one of them isn't a change of its own.
  final _typed = <String>[];

  @override
  void didUpdateWidget(UiField old) {
    super.didUpdateWidget(old);
    final text = widget.node.text ?? '';
    if (text == _controller.text) return;
    final own = text != (old.node.text ?? '') && !_typed.contains(text);
    if (_focus.hasFocus && !own) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.node;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        enabled: n.enabled,
        obscureText: n.input == 'password',
        keyboardType: switch (n.input) {
          'number' => TextInputType.number,
          'email' => TextInputType.emailAddress,
          'url' => TextInputType.url,
          'multiline' => TextInputType.multiline,
          _ => TextInputType.text,
        },
        maxLines: n.input == 'multiline' ? 4 : 1,
        decoration: InputDecoration(labelText: widget.label, hintText: n.hint, border: const OutlineInputBorder()),
        onChanged: (text) {
          _typed.add(text);
          if (_typed.length > 20) _typed.removeAt(0);
          widget.session.type(n.id, text);
        },
        onSubmitted: (_) => unawaited(widget.session.act(n.id, 'submit')),
      ),
    );
  }
}

/// A slider the extension's slider mirrors: what the person lets go at reaches the extension.
class UiSlider extends StatefulWidget {
  const UiSlider({super.key, required this.node, required this.session});

  final UiNode node;
  final ExtensionUiSession session;

  @override
  State<UiSlider> createState() => _UiSliderState();
}

class _UiSliderState extends State<UiSlider> {
  double? _dragging;

  /// Up and down leave the slider, as they leave every other control on a remote; left and right move it.
  final _focus = FocusNode(onKeyEvent: _remoteKeys);

  static KeyEventResult _remoteKeys(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
    node.focusInDirection(key == LogicalKeyboardKey.arrowDown ? TraversalDirection.down : TraversalDirection.up);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.node;
    final max = (n.max ?? 100).toDouble() <= 0 ? 1.0 : (n.max ?? 100).toDouble();
    final value = (_dragging ?? (n.value ?? 0).toDouble()).clamp(0.0, max);
    return Slider(
      focusNode: _focus,
      value: value,
      max: max,
      divisions: max <= 1000 ? max.round() : null,
      label: '${value.round()}',
      onChanged: n.enabled ? (v) => setState(() => _dragging = v) : null,
      onChangeEnd: n.enabled
          ? (v) {
              setState(() => _dragging = null);
              unawaited(widget.session.act(n.id, 'slide', v.round()));
            }
          : null,
    );
  }
}
