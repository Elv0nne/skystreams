import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/compare_trees.dart';

Map<String, Object?> _window(Map<String, Object?> root) => {
  'id': 'w1',
  'kind': 'sheet',
  'cancelable': true,
  'root': root,
};

Map<String, Object?> _text(String words) => {'id': 1, 'kind': 'text', 'text': words};

Map<String, Object?> _switch(bool on) => {'id': 2, 'kind': 'switch', 'tappable': true, 'text': '', 'checked': on};

void main() {
  test('leaves are what the sheet draws: words, state and taps, through containers', () {
    final windows = [
      _window({
        'id': 9,
        'kind': 'column',
        'children': [
          {
            'id': 3,
            'kind': 'row',
            'tappable': true,
            'children': [_text('Banner'), _switch(true)],
          },
          _text('  '),
          {'id': 4, 'kind': 'image'},
          {'id': 5, 'kind': 'button', 'tappable': true, 'text': 'Save and restart the app, and then some more words'},
          {'id': 6, 'kind': 'iconButton', 'tappable': true, 'label': 'Close'},
        ],
      }),
    ];
    expect(leaves(windows), [
      (kind: 'text', words: 'Banner', detail: '', state: null, tappable: true),
      (kind: 'switch', words: '', detail: '', state: 'on', tappable: true),
      (kind: 'button', words: 'Save and restart the app, and then some ', detail: '', state: null, tappable: true),
      (kind: 'iconButton', words: 'Close', detail: '', state: null, tappable: true),
    ]);
    expect(leaves(windows, state: false)[1].state, isNull);
  });

  test('the same with or without state, close at 80%, else different, or missing', () {
    List<Object?> screen(List<Map<String, Object?>> children) => [
      _window({'id': 9, 'kind': 'column', 'children': children}),
    ];
    final android = screen([_text('A'), _text('B'), _text('C'), _text('D'), _text('E'), _switch(true)]);
    expect(
      verdict(android, screen([_text('A'), _text('B'), _text('C'), _text('D'), _text('E'), _switch(true)])),
      Verdict.same,
    );
    expect(
      verdict(android, screen([_text('A'), _text('B'), _text('C'), _text('D'), _text('E'), _switch(false)])),
      Verdict.same,
    );
    expect(
      verdict(android, screen([_text('A'), _text('B'), _text('C'), _text('D'), _text('X'), _switch(true)])),
      Verdict.close,
    );
    expect(verdict(android, screen([_text('A'), _text('X'), _text('Y'), _text('Z')])), Verdict.different);
    expect(verdict(android, null), Verdict.missing);
    expect(verdict(android, screen([])), Verdict.missing);
    expect(likeness(leaves(android), leaves(android)), 1.0);
  });

  test(
    "a dropdown's options, a slider's maximum, a field's hint and a disabled control count; a run's choices don't",
    () {
      List<Object?> screen(Map<String, Object?> control) => [
        _window({
          'id': 9,
          'kind': 'column',
          'children': [_text('Quality'), control],
        }),
      ];
      Map<String, Object?> dropdown(List<String> options, int selected) => {
        'id': 7,
        'kind': 'dropdown',
        'options': options,
        'selected': selected,
      };
      Map<String, Object?> slider(int value, int max) => {'id': 8, 'kind': 'slider', 'value': value, 'max': max};
      Map<String, Object?> field(String hint) => {'id': 10, 'kind': 'field', 'text': '', 'hint': hint, 'input': 'text'};
      Map<String, Object?> button({bool enabled = true}) => {
        'id': 11,
        'kind': 'button',
        'tappable': true,
        'text': 'Save',
        if (!enabled) 'enabled': false,
      };

      expect(verdict(screen(dropdown(['480p', '720p'], 0)), screen(dropdown(['480p'], 0))), isNot(Verdict.same));
      expect(verdict(screen(dropdown(['480p', '720p'], 0)), screen(dropdown(['480p', '720p'], 1))), Verdict.same);
      expect(verdict(screen(slider(4, 10)), screen(slider(4, 100))), isNot(Verdict.same));
      expect(verdict(screen(slider(4, 10)), screen(slider(6, 10))), Verdict.same);
      expect(verdict(screen(field('Token')), screen(field(''))), isNot(Verdict.same));
      expect(verdict(screen(button()), screen(button(enabled: false))), isNot(Verdict.same));
    },
  );

  test('reports come from log lines, and a name twice is paired by order', () {
    Map<String, Object?> report(String name, List<Object?>? tree) => {'extension': name, 'tree': tree};
    final first = [_window(_text('One'))];
    final second = [_window(_text('Two'))];
    final android = reports([
      'I/flutter ( 1234): CS3-UI ${jsonEncode(report('Twice', first))}',
      'CS3-UI ${jsonEncode(report('Twice', second))}',
      'CS3-UI ${jsonEncode(report('NoScreen', null))}',
      'CS3-UI-END {"opened": 2}',
    ]);
    expect(android.map((r) => r['extension']), ['Twice', 'Twice', 'NoScreen']);
    final rows = compare(android, [
      report('Twice', first),
      report('Twice', [_window(_text('Other'))]),
    ]);
    expect(rows.map((r) => (r.extension, r.verdict)), [('Twice', Verdict.same), ('Twice', Verdict.different)]);
  });
}
