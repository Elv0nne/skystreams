/// The patterns that draw extension screens as SkyStream's: a checkbox and its label as one row, a
/// tappable card as a list tile, a label above a field as the field's label, rows of buttons.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_ui_session.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/ui_node_view.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class _Api implements ExtensionUiApi {
  final sent = <String>[];

  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  Future<int> openSettings(String plugin) async => 1;

  @override
  Future<int> openPopups(String plugin) async => 1;

  @override
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) async {
    sent.add('$node $action');
    return {'done': true};
  }

  @override
  Future<void> closeUi(int session, {bool force = false}) async {}
}

UiNode _node(Map<String, dynamic> json) => UiNode.fromJson(json);

/// CNC Verse's studio row: an unlabelled checkbox, and its label beside it.
final _studio = _node({
  'id': 1,
  'kind': 'column',
  'children': [
    {'id': 2, 'kind': 'checkbox', 'text': '', 'checked': true, 'tappable': true},
    {'id': 3, 'kind': 'text', 'text': 'Disney', 'tappable': true},
  ],
});

/// StreamPlay's menu card: a tappable group of an icon, a title, a subtitle and a chevron image.
final _card = _node({
  'id': 10,
  'kind': 'row',
  'tappable': true,
  'children': [
    {'id': 11, 'kind': 'image'},
    {
      'id': 12,
      'kind': 'column',
      'children': [
        {'id': 13, 'kind': 'text', 'text': 'Febbox Login'},
        {'id': 14, 'kind': 'text', 'text': 'Connect your account to access cloud files'},
      ],
    },
    {'id': 15, 'kind': 'image'},
  ],
});

void main() {
  test('a toggle with one or two texts and nothing else is one row', () {
    final row = toggleRow(_studio)!;
    expect((row.toggle.id, row.title, row.subtitle), (2, 'Disney', null));
    final labelled = toggleRow(
      _node({
        'id': 1,
        'kind': 'row',
        'children': [
          {'id': 2, 'kind': 'switch', 'text': 'Dark posters'},
          {'id': 3, 'kind': 'text', 'text': 'Darker artwork on Home'},
        ],
      }),
    )!;
    expect((labelled.title, labelled.subtitle), ('Dark posters', 'Darker artwork on Home'));
    expect(
      toggleRow(
        _node({
          'id': 1,
          'kind': 'column',
          'children': [
            {'id': 2, 'kind': 'checkbox'},
            {'id': 3, 'kind': 'checkbox'},
            {'id': 4, 'kind': 'text', 'text': 'Two toggles'},
          ],
        }),
      ),
      isNull,
    );
    expect(
      toggleRow(
        _node({
          'id': 1,
          'kind': 'column',
          'children': [
            {'id': 2, 'kind': 'checkbox'},
            {'id': 3, 'kind': 'button', 'text': 'Also a button'},
          ],
        }),
      ),
      isNull,
    );
  });

  test('a tappable group of texts and pictures is a tile; one with a control is not', () {
    final tile = tappableTile(_card)!;
    expect((tile.title, tile.subtitle), ('Febbox Login', 'Connect your account to access cloud files'));
    expect(
      tappableTile(
        _node({
          'id': 1,
          'kind': 'row',
          'tappable': true,
          'children': [
            {'id': 2, 'kind': 'text', 'text': 'Has a switch'},
            {'id': 3, 'kind': 'switch'},
          ],
        }),
      ),
      isNull,
    );
    expect(
      tappableTile(
        _node({
          'id': 1,
          'kind': 'row',
          'children': [
            {'id': 2, 'kind': 'text', 'text': 'Not tappable'},
          ],
        }),
      ),
      isNull,
    );
  });

  test("an icon button's words name its icon", () {
    expect(iconFor('Save settings'), Icons.save_outlined);
    expect(iconFor('Close'), Icons.close_rounded);
    expect(iconFor('Refresh list'), Icons.refresh_rounded);
    expect(iconFor('Delete'), Icons.delete_outline);
    expect(iconFor('Settings'), Icons.settings_outlined);
    expect(iconFor('Frobnicate'), isNull);
    expect(iconFor(null), isNull);
  });

  test('an icon comes from a whole word, not from part of one', () {
    expect(iconFor('Feedback'), isNull);
    expect(iconFor('Closed captions'), isNull);
    expect(iconFor('Disclosure'), isNull);
    expect(iconFor('Address'), isNull);
    expect(iconFor('Go back'), Icons.arrow_back_rounded);
    expect(iconFor('Add link'), Icons.add_rounded);
  });

  testWidgets('the patterns draw as rows and tiles, labels sit on their fields, and buttons wrap', (tester) async {
    final api = _Api();
    final session = ExtensionUiSession.test(api);
    final screen = _node({
      'id': 100,
      'kind': 'column',
      'children': [
        _studio.toJsonForTest(),
        _card.toJsonForTest(),
        {'id': 20, 'kind': 'text', 'text': 'Token'},
        {'id': 21, 'kind': 'field', 'hint': 'Paste a token'},
        {
          'id': 30,
          'kind': 'row',
          'children': [
            {'id': 31, 'kind': 'button', 'text': 'Save', 'tappable': true},
            {'id': 32, 'kind': 'button', 'text': 'Cancel', 'tappable': true},
          ],
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: UiNodeView(node: screen, session: session),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Disney'));
    await tester.tap(find.text('Febbox Login'));
    expect(api.sent, ['2 click', '10 click']);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).decoration?.labelText, 'Token');
    expect(find.text('Token'), findsOneWidget, reason: 'the label is drawn once, on the field');
    expect(find.byType(Wrap), findsOneWidget);
    session.dispose();
  });
}

extension on UiNode {
  /// Back to the engine's JSON, to nest the samples in a screen.
  Map<String, dynamic> toJsonForTest() => {
    'id': id,
    'kind': switch (kind) {
      UiKind.switchToggle => 'switch',
      final k => k.name,
    },
    'text': ?text,
    'tappable': tappable,
    'checked': checked,
    'children': [for (final c in children) c.toJsonForTest()],
  };
}
