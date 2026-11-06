/// An extension's window as the engine describes it in a `ui` event (the spec's "The protocol"):
/// meaning only, for SkyStream to draw with its own widgets and theme.
library;

enum UiKind {
  column,
  row,
  text,
  button,
  iconButton,
  checkbox,
  switchToggle,
  radio,
  field,
  dropdown,
  slider,
  progress,
  image,
  list,
  page,
  other,
}

UiKind _kind(Object? name) => switch (name) {
  'column' => UiKind.column,
  'row' => UiKind.row,
  'text' => UiKind.text,
  'button' => UiKind.button,
  'iconButton' => UiKind.iconButton,
  'checkbox' => UiKind.checkbox,
  'switch' => UiKind.switchToggle,
  'radio' => UiKind.radio,
  'field' => UiKind.field,
  'dropdown' => UiKind.dropdown,
  'slider' => UiKind.slider,
  'progress' => UiKind.progress,
  'image' => UiKind.image,
  'list' => UiKind.list,
  'page' => UiKind.page,
  _ => UiKind.other,
};

/// One view of an extension's window.
class UiNode {
  const UiNode({
    required this.id,
    required this.kind,
    this.text,
    this.hint,
    this.label,
    this.heading = false,
    this.checked = false,
    this.enabled = true,
    this.tappable = false,
    this.input = 'text',
    this.options = const [],
    this.selected,
    this.value,
    this.max,
    this.items,
    this.icon,
    this.weight,
    this.children = const [],
  });

  factory UiNode.fromJson(Map<String, dynamic> json) => UiNode(
    id: (json['id'] as num).toInt(),
    kind: _kind(json['kind']),
    text: json['text'] as String?,
    hint: json['hint'] as String?,
    label: json['label'] as String?,
    heading: json['heading'] == true,
    checked: json['checked'] == true,
    enabled: json['enabled'] != false,
    tappable: json['tappable'] == true,
    input: json['input'] as String? ?? 'text',
    options: [for (final option in (json['options'] as List?) ?? const []) '$option'],
    selected: (json['selected'] as num?)?.toInt(),
    value: json['value'] as num?,
    max: json['max'] as num?,
    items: (json['items'] as num?)?.toInt(),
    icon: json['icon'] as String?,
    weight: (json['weight'] as num?)?.toDouble(),
    children: [
      for (final child in (json['children'] as List?) ?? const [])
        if (child is Map) UiNode.fromJson(Map<String, dynamic>.from(child)),
    ],
  );

  /// The engine's number for the view: actions name it.
  final int id;
  final UiKind kind;
  final String? text;
  final String? hint;

  /// The view's content description.
  final String? label;
  final bool heading;
  final bool checked;
  final bool enabled;
  final bool tappable;

  /// For fields: `text`, `number`, `password`, `email`, `url` or `multiline`.
  final String input;
  final List<String> options;
  final int? selected;
  final num? value;
  final num? max;

  /// For lists: how many items it has. [children] are the items.
  final int? items;
  final String? icon;
  final double? weight;
  final List<UiNode> children;

  bool get isToggle => kind == UiKind.checkbox || kind == UiKind.switchToggle || kind == UiKind.radio;

  bool get isContainer => kind == UiKind.column || kind == UiKind.row || kind == UiKind.list;

  /// Its text, or else its content description; null when it has neither.
  String? get words {
    final own = text?.trim() ?? '';
    if (own.isNotEmpty) return own;
    final described = label?.trim() ?? '';
    return described.isEmpty ? null : described;
  }
}

/// One window an extension shows: a sheet, dialog, alert, page or popup.
class UiWindow {
  const UiWindow({
    required this.id,
    required this.kind,
    required this.root,
    this.title,
    this.cancelable = true,
    this.hidden,
    this.fullScreen = false,
    this.keepScreenOn = false,
    this.orientation,
  });

  factory UiWindow.fromJson(Map<String, dynamic> json) => UiWindow(
    id: json['id'] as String,
    kind: json['kind'] as String? ?? 'dialog',
    title: json['title'] as String?,
    cancelable: json['cancelable'] != false,
    hidden: json['hidden'] as bool?,
    fullScreen: json['fullScreen'] == true,
    keepScreenOn: json['keepScreenOn'] == true,
    orientation: (json['orientation'] as num?)?.toInt(),
    root: UiNode.fromJson(Map<String, dynamic>.from(json['root'] as Map)),
  );

  final String id;
  final String kind;
  final String? title;

  /// Whether Back or the sheet's close button may close it.
  final bool cancelable;

  /// On Android, whether the extension's own window is invisible and untouchable (it must be).
  final bool? hidden;

  /// Whether it asks for the whole screen: the full-screen view shows it (Phase 7c's §2).
  final bool fullScreen;

  /// Whether it asks that the screen stays on.
  final bool keepScreenOn;

  /// The orientation its extension asked for, as Android's `SCREEN_ORIENTATION_*` (the JVM; an iPhone turns for it).
  final int? orientation;
  final UiNode root;
}
