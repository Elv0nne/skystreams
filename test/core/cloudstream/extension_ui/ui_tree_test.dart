/// Extension windows read as the engine sends them (the spec's "The protocol").
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';

void main() {
  test('a window and its nodes read as the engine sends them', () {
    final window = UiWindow.fromJson({
      'id': 'w1',
      'kind': 'sheet',
      'cancelable': false,
      'hidden': true,
      'root': {
        'id': 1,
        'kind': 'column',
        'children': [
          {'id': 2, 'kind': 'checkbox', 'text': 'Disney', 'checked': true, 'tappable': true},
          {'id': 3, 'kind': 'switch', 'text': 'Dark'},
          {'id': 4, 'kind': 'field', 'text': 'abc', 'hint': 'Token', 'input': 'password', 'enabled': false},
          {
            'id': 5,
            'kind': 'dropdown',
            'options': ['480p', '720p'],
            'selected': 1,
          },
          {'id': 6, 'kind': 'slider', 'value': 30, 'max': 60},
          {'id': 7, 'kind': 'list', 'items': 40, 'children': <Object>[]},
          {'id': 8, 'kind': 'row', 'weight': 2, 'children': <Object>[]},
          {'id': 9, 'kind': 'mystery'},
          {'id': 10, 'kind': 'text', 'text': '  ', 'label': 'Save settings', 'heading': true},
        ],
      },
    });
    expect(window.id, 'w1');
    expect(window.kind, 'sheet');
    expect(window.cancelable, isFalse);
    expect(window.hidden, isTrue);
    final nodes = window.root.children;
    expect(window.root.kind, UiKind.column);
    expect(window.root.isContainer, isTrue);
    expect(
      (nodes[0].kind, nodes[0].words, nodes[0].checked, nodes[0].tappable, nodes[0].isToggle),
      (UiKind.checkbox, 'Disney', true, true, true),
    );
    expect(nodes[1].kind, UiKind.switchToggle);
    expect((nodes[2].input, nodes[2].hint, nodes[2].enabled), ('password', 'Token', false));
    expect(nodes[3].options, ['480p', '720p']);
    expect(nodes[3].selected, 1);
    expect((nodes[4].value, nodes[4].max), (30, 60));
    expect((nodes[5].items, nodes[5].isContainer), (40, true));
    expect(nodes[6].weight, 2.0);
    expect(nodes[7].kind, UiKind.other);
    expect((nodes[8].words, nodes[8].heading), ('Save settings', true));
  });

  test('what the engine leaves out reads as its default', () {
    final node = UiNode.fromJson({'id': 3, 'kind': 'text'});
    expect((node.enabled, node.tappable, node.checked, node.heading, node.input), (true, false, false, false, 'text'));
    expect(node.children, isEmpty);
    expect(node.words, isNull);
    final window = UiWindow.fromJson({
      'id': 'w2',
      'root': {'id': 1, 'kind': 'column'},
    });
    expect((window.kind, window.cancelable, window.hidden, window.title), ('dialog', true, null, null));
  });

  test('a window that asks for the whole screen reads so, with its screen kept on and its orientation', () {
    final game = UiWindow.fromJson({
      'id': 'w2',
      'kind': 'dialog',
      'fullScreen': true,
      'keepScreenOn': true,
      'orientation': 6,
      'root': {'id': 1, 'kind': 'page'},
    });
    expect((game.fullScreen, game.keepScreenOn, game.orientation), (true, true, 6));
    final plain = UiWindow.fromJson({
      'id': 'w1',
      'kind': 'dialog',
      'root': {'id': 1, 'kind': 'text'},
    });
    expect((plain.fullScreen, plain.keepScreenOn, plain.orientation), (false, false, null));
  });
}
