/// Compares the extension screens of two corpus runs: integration_test/cloudstream/settings_corpus_test.dart's
/// `CS3-UI {json}` lines, Android's (the reference) and another platform's. Per extension, by what
/// SkyStream's sheet draws, its visible leaves in order (kind, words up to 40 characters, details: a
/// dropdown's options, a slider's maximum, a field's hint, disabled; state: checked, a dropdown's choice, a
/// slider's value; tappable):
/// - same: equal, with their state or without it (a toggle or a choice a run changed);
/// - close: without state, at least 80% alike (twice the longest common run of leaves over both lengths);
/// - different; or missing, when the other platform shows nothing.
/// Extensions Android opens nothing for aren't compared. Exits 1 when an extension is neither the same
/// nor close, unless allowed.
///
/// ```
/// dart run packages/cs3_engine/tool/compare_trees.dart ANDROID.jsonl OTHER.log [--allow AniyomiProvider,...]
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// One leaf as the sheet draws it: [detail] is what it is beyond its words, [state] what a run may have changed.
typedef Leaf = ({String kind, String words, String detail, String? state, bool tappable});

/// The kinds the sheet draws as controls or words; containers are walked, decoration (images, progress,
/// other) left out.
const _leafKinds = {
  'text',
  'checkbox',
  'switch',
  'radio',
  'button',
  'iconButton',
  'field',
  'dropdown',
  'slider',
  'page',
};

/// [windows]' leaves, the bottom window's first; with [state], what a run may have changed too.
List<Leaf> leaves(List<Object?> windows, {bool state = true}) {
  final out = <Leaf>[];
  for (final window in windows) {
    if (window is Map && window['root'] is Map) _walk(window['root'] as Map, out, false, state);
  }
  return out;
}

void _walk(Map node, List<Leaf> out, bool inTap, bool state) {
  final kind = node['kind'] as String?;
  final tappable = node['tappable'] == true;
  if (_leafKinds.contains(kind)) {
    final text = (node['text'] as String?)?.trim() ?? '';
    final words = text.isNotEmpty ? text : ((node['label'] as String?)?.trim() ?? '');
    if (kind == 'text' && words.isEmpty) return;
    out.add((
      kind: kind!,
      words: _short(words),
      detail: _detail(node),
      state: state ? _state(node) : null,
      tappable: tappable || inTap,
    ));
    return;
  }
  for (final child in (node['children'] as List?) ?? const []) {
    if (child is Map) _walk(child, out, inTap || tappable, state);
  }
}

String _short(String words) => words.length > 40 ? words.substring(0, 40) : words;

/// What a leaf is beyond its words: a dropdown's options, a slider's maximum, a field's hint, disabled.
String _detail(Map node) => [
  if (node['options'] case final List options) 'options ${options.map((o) => _short('$o'.trim())).join('|')}',
  if (node['max'] case final Object max) 'max $max',
  if (node['hint'] case final String hint when hint.trim().isNotEmpty) 'hint ${_short(hint.trim())}',
  if (node['enabled'] == false) 'disabled',
].join('; ');

/// What a run may have changed: checked, a dropdown's choice, a slider's value.
String? _state(Map node) {
  final parts = [
    if (node['checked'] case final bool checked) checked ? 'on' : 'off',
    if (node['selected'] case final Object selected) 'selected $selected',
    if (node['value'] case final Object value) 'value $value',
  ];
  return parts.isEmpty ? null : parts.join('; ');
}

/// Twice the longest common subsequence of [a] and [b] over their lengths: 1 when they're equal.
double likeness(List<Leaf> a, List<Leaf> b) {
  if (a.isEmpty && b.isEmpty) return 1;
  final common = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      common[i][j] = a[i] == b[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1]);
    }
  }
  return 2 * common[0][0] / (a.length + b.length);
}

enum Verdict { same, close, different, missing }

bool _equal(List<Leaf> a, List<Leaf> b) => a.length == b.length && likeness(a, b) == 1;

/// How [other]'s screen compares with [android]'s.
Verdict verdict(List<Object?> android, List<Object?>? other) {
  if (other == null || leaves(other).isEmpty) return Verdict.missing;
  final bare = leaves(android, state: false);
  final otherBare = leaves(other, state: false);
  if (_equal(leaves(android), leaves(other)) || _equal(bare, otherBare)) return Verdict.same;
  return likeness(bare, otherBare) >= 0.8 ? Verdict.close : Verdict.different;
}

/// The reports among [lines] (a log's: anything may come before the marker), in order.
List<Map<String, Object?>> reports(Iterable<String> lines) => [
  for (final line in lines)
    if (line.indexOf('CS3-UI {') case final at when at >= 0)
      jsonDecode(line.substring(at + 'CS3-UI '.length)) as Map<String, Object?>,
];

/// One row per extension Android opened: its verdict, and both sides' leaf counts. A name that comes
/// twice is paired by order.
List<({String extension, Verdict verdict, int android, int other})> compare(
  List<Map<String, Object?>> android,
  List<Map<String, Object?>> other,
) {
  final theirs = <String, List<Map<String, Object?>>>{};
  for (final report in other) {
    (theirs[report['extension'] as String] ??= []).add(report);
  }
  final rows = <({String extension, Verdict verdict, int android, int other})>[];
  for (final report in android) {
    final name = report['extension'] as String;
    final pool = theirs[name];
    final mine = pool == null || pool.isEmpty ? null : pool.removeAt(0);
    final tree = report['tree'] as List?;
    if (tree == null || leaves(tree).isEmpty) continue;
    final otherTree = mine?['tree'] as List?;
    rows.add((
      extension: name,
      verdict: verdict(tree, otherTree),
      android: leaves(tree).length,
      other: otherTree == null ? 0 : leaves(otherTree).length,
    ));
  }
  return rows;
}

List<String> _lines(String path) => utf8.decode(File(path).readAsBytesSync(), allowMalformed: true).split('\n');

void main(List<String> args) {
  final allowAt = args.indexOf('--allow');
  final allowed = allowAt >= 0 && allowAt + 1 < args.length
      ? args[allowAt + 1].split(',').map((s) => s.trim()).toSet()
      : <String>{};
  final files = [
    for (var i = 0; i < args.length; i++)
      if (i != allowAt && (allowAt < 0 || i != allowAt + 1)) args[i],
  ];
  if (files.length != 2) {
    stderr.writeln('usage: compare_trees.dart ANDROID OTHER [--allow Name,...]');
    exit(2);
  }
  final rows = compare(reports(_lines(files[0])), reports(_lines(files[1])));
  stdout.writeln({for (final v in Verdict.values) v.name: rows.where((r) => r.verdict == v).length});
  var failed = false;
  for (final row in rows) {
    if (row.verdict == Verdict.same) continue;
    final fine = row.verdict == Verdict.close || allowed.contains(row.extension);
    if (!fine) failed = true;
    stdout.writeln(
      '${fine ? '  ' : 'x '}${row.verdict.name.padRight(9)} ${row.extension.padRight(24)} android ${row.android} other ${row.other}',
    );
  }
  exit(failed ? 1 : 0);
}
