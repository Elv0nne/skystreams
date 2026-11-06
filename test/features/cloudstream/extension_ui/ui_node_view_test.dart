/// Each kind of node an extension's window holds, drawn with SkyStream's widgets, sending what the
/// person does to the extension.
library;

import 'dart:async';

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
    sent.add('$node $action $value');
    return {'done': true};
  }

  @override
  Future<void> closeUi(int session, {bool force = false}) async {}
}

UiNode _node(Map<String, dynamic> json) => UiNode.fromJson(json);

void main() {
  late _Api api;
  late ExtensionUiSession session;

  setUp(() {
    api = _Api();
    session = ExtensionUiSession.test(api);
  });

  Future<void> show(WidgetTester tester, UiNode node) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: UiNodeView(node: node, session: session),
        ),
      ),
    ),
  );

  testWidgets('text reads plain or as a heading, and tappable text taps', (tester) async {
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'column',
        'children': [
          {'id': 2, 'kind': 'text', 'text': 'Studios', 'heading': true},
          {'id': 3, 'kind': 'text', 'text': 'Search is merged'},
          {'id': 4, 'kind': 'text', 'text': 'Disney', 'tappable': true},
        ],
      }),
    );
    final context = tester.element(find.text('Studios'));
    expect(
      tester.widget<Text>(find.text('Studios')).style?.fontSize,
      Theme.of(context).textTheme.titleMedium?.fontSize,
    );
    await tester.tap(find.text('Disney'));
    expect(api.sent, ['4 click null']);
  });

  testWidgets('buttons tap unless disabled; icon buttons show a known icon, else their words', (tester) async {
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'column',
        'children': [
          {'id': 2, 'kind': 'button', 'text': 'Clear All Cache', 'tappable': true},
          {'id': 3, 'kind': 'button', 'text': 'Disabled', 'tappable': true, 'enabled': false},
          {'id': 4, 'kind': 'iconButton', 'label': 'Save settings', 'tappable': true},
          {'id': 5, 'kind': 'iconButton', 'label': 'Frobnicate', 'tappable': true},
        ],
      }),
    );
    await tester.tap(find.text('Clear All Cache'));
    await tester.tap(find.text('Disabled'));
    await tester.tap(find.byTooltip('Save settings'));
    await tester.tap(find.text('Frobnicate'));
    expect(api.sent, ['2 click null', '4 click null', '5 click null']);
    expect(find.byIcon(Icons.save_outlined), findsOneWidget);
  });

  testWidgets('a lone checkbox, switch or radio is a row that taps it', (tester) async {
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'column',
        'children': [
          {'id': 2, 'kind': 'checkbox', 'text': 'Marvel', 'checked': true, 'tappable': true},
          {'id': 3, 'kind': 'switch', 'text': 'Dark posters', 'tappable': true},
          {'id': 4, 'kind': 'radio', 'text': 'Careful', 'tappable': true},
        ],
      }),
    );
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    await tester.tap(find.text('Marvel'));
    await tester.tap(find.text('Dark posters'));
    await tester.tap(find.text('Careful'));
    expect(api.sent, ['2 click null', '3 click null', '4 click null']);
  });

  testWidgets('a field takes typing and its keyboard action, and keeps what the person types', (tester) async {
    await show(tester, _node({'id': 1, 'kind': 'field', 'text': 'old', 'hint': 'Paste a token', 'input': 'password'}));
    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), 'abc123');
    // The extension's echo of what reached it earlier, arriving while the person is in the field, doesn't
    // replace what they've typed since.
    await show(tester, _node({'id': 1, 'kind': 'field', 'text': 'abc', 'input': 'password'}));
    expect(find.text('abc123'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.sent, ['1 text abc', '1 text abc123', '1 submit null']);
  });

  testWidgets("the extension's own change to a field shows even while the person is in it (a Reset)", (tester) async {
    await show(tester, _node({'id': 1, 'kind': 'field', 'text': 'old'}));
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump(const Duration(milliseconds: 400));
    await show(tester, _node({'id': 1, 'kind': 'field', 'text': 'abc'}));
    // Its Reset button, tapped without leaving the field.
    await show(tester, _node({'id': 1, 'kind': 'field', 'text': ''}));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
  });

  testWidgets('a field the extension moves (an error appears beside it) keeps the focus and the typing', (
    tester,
  ) async {
    // The reader leaves out a container with one thing in it: the field sits in the outer column.
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'column',
        'children': [
          {'id': 3, 'kind': 'field', 'text': ''},
          {'id': 5, 'kind': 'button', 'text': 'Save', 'tappable': true},
        ],
      }),
    );
    await tester.enterText(find.byType(TextField), 'abc');
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>(), isNotNull);
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'column',
        'children': [
          {
            'id': 2,
            'kind': 'column',
            'children': [
              {'id': 3, 'kind': 'field', 'text': ''},
              {'id': 4, 'kind': 'text', 'text': 'Invalid token'},
            ],
          },
          {'id': 5, 'kind': 'button', 'text': 'Save', 'tappable': true},
        ],
      }),
    );
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>(), isNotNull);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'abc');
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('a dropdown picks an option', (tester) async {
    await show(
      tester,
      _node({
        'id': 7,
        'kind': 'dropdown',
        'options': ['480p', '720p', '1080p'],
        'selected': 0,
      }),
    );
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1080p').last);
    await tester.pumpAndSettle();
    expect(api.sent, ['7 select 2']);
  });

  testWidgets('a slider sends where the person let go', (tester) async {
    await show(tester, _node({'id': 8, 'kind': 'slider', 'value': 0, 'max': 60}));
    await tester.drag(find.byType(Slider), const Offset(2000, 0));
    await tester.pumpAndSettle();
    expect(api.sent, ['8 slide 60']);
  });

  testWidgets("progress shows; decorative images and unknown views don't", (tester) async {
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'column',
        'children': [
          {'id': 2, 'kind': 'progress'},
          {'id': 3, 'kind': 'image'},
          {'id': 4, 'kind': 'other', 'label': 'Clouds'},
        ],
      }),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Clouds'), findsNothing);
  });

  testWidgets("a row's weighted children share what's left once the others have their own size", (tester) async {
    // The test extension's title row: a title with weight 1, and a close button with none.
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'row',
        'children': [
          {'id': 2, 'kind': 'text', 'text': 'SkyStream test settings', 'heading': true, 'weight': 1},
          {'id': 3, 'kind': 'iconButton', 'label': 'Close', 'tappable': true},
        ],
      }),
    );
    final button = tester.getRect(find.byType(IconButton));
    final screen = tester.getRect(find.byType(Scaffold));
    expect(button.width, greaterThanOrEqualTo(40), reason: 'the button keeps its own size');
    expect(button.right, lessThanOrEqualTo(screen.right), reason: 'and stays inside the row');
    await tester.tap(find.byTooltip('Close'));
    expect(api.sent, ['3 click null']);
  });

  testWidgets("a row of the extension's words beside a switch is one toggle row (NetNaija's 23 rows)", (tester) async {
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'row',
        'children': [
          {
            'id': 2,
            'kind': 'column',
            'weight': 1,
            'children': [
              {'id': 3, 'kind': 'text', 'text': 'Arabic Dub'},
              {'id': 4, 'kind': 'text', 'text': 'Dubbed audio'},
            ],
          },
          {'id': 5, 'kind': 'switch', 'checked': true, 'tappable': true},
        ],
      }),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Dubbed audio'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.tap(find.text('Arabic Dub'));
    expect(api.sent, ['5 click null']);
  });

  testWidgets('a weighted label beside a dropdown lays out both (StreamingCommunity, AltaDefinizione)', (tester) async {
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'row',
        'children': [
          {'id': 2, 'kind': 'text', 'text': 'Quality', 'weight': 1},
          {
            'id': 3,
            'kind': 'dropdown',
            'options': ['720p', '1080p'],
            'selected': 0,
          },
        ],
      }),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(DropdownButtonFormField<int>)).width, greaterThan(0));
  });

  testWidgets('a tappable group holding only a labelled image is an icon button (phisher98\'s "Save and Reload")', (
    tester,
  ) async {
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'row',
        'children': [
          {
            'id': 2,
            'kind': 'column',
            'weight': 1,
            'children': [
              {'id': 3, 'kind': 'text', 'text': 'StreamPlay settings', 'heading': true},
              {'id': 4, 'kind': 'text', 'text': 'Choose your sources'},
            ],
          },
          {
            'id': 5,
            'kind': 'row',
            'tappable': true,
            'children': [
              {'id': 6, 'kind': 'image', 'label': 'Save and Reload'},
            ],
          },
        ],
      }),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Save and Reload'));
    expect(api.sent, ['5 click null']);
  });

  testWidgets('a list draws all its items', (tester) async {
    await show(
      tester,
      _node({
        'id': 1,
        'kind': 'list',
        'items': 3,
        'children': [
          for (var i = 1; i <= 3; i++) {'id': 10 + i, 'kind': 'text', 'text': 'Item $i', 'tappable': true},
        ],
      }),
    );
    await tester.tap(find.text('Item 3'));
    expect(api.sent, ['13 click null']);
  });

  tearDown(() => session.dispose());
}
