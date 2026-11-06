import 'dart:async';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_page_dialog.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

void main() {
  /// An app whose one button shows [dialog]; its answer lands in the returned list.
  Future<List<({bool accept, String? text})>> show(WidgetTester tester, PageDialog dialog, {Future<void>? gone}) async {
    final answers = <({bool accept, String? text})>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showExtensionPageDialog(context, dialog, gone: gone).then(answers.add),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return answers;
  }

  testWidgets("a prompt shows its message and default text; OK answers the field's text", (tester) async {
    final answers = await show(
      tester,
      const PageDialog(id: 1, kind: DialogKind.prompt, message: 'Your name?', defaultText: 'Player'),
    );
    expect(find.text('Your name?'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Player'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Tester');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(answers, [(accept: true, text: 'Tester')]);
  });

  testWidgets('a confirm has Cancel and OK, and Cancel answers no; an alert has OK alone', (tester) async {
    final answers = await show(tester, const PageDialog(id: 1, kind: DialogKind.confirm, message: 'Keep playing?'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answers, [(accept: false, text: null)]);
    final alert = await show(tester, const PageDialog(id: 2, kind: DialogKind.alert, message: 'Game ready'));
    expect(find.text('Cancel'), findsNothing);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(alert, [(accept: true, text: null)]);
  });

  testWidgets('Back cancels it, and it closes by itself, cancelled, when its page goes', (tester) async {
    final answers = await show(tester, const PageDialog(id: 1, kind: DialogKind.prompt, message: 'Your name?'));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(answers, [(accept: false, text: null)]);
    final gone = Completer<void>();
    final closed = await show(
      tester,
      const PageDialog(id: 2, kind: DialogKind.alert, message: 'Held'),
      gone: gone.future,
    );
    expect(find.text('Held'), findsOneWidget);
    gone.complete();
    await tester.pumpAndSettle();
    expect(find.text('Held'), findsNothing);
    expect(closed, [(accept: false, text: null)]);
  });

  // A prompt's field with a remote: the keys are a keyboard's while one is up; with it put away, Down reaches the
  // buttons and Select - OK on a remote - brings the keyboard back.
  FocusNode promptField(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).focusNode;

  testWidgets("a prompt's field keeps Down while a keyboard is up", (tester) async {
    await show(tester, const PageDialog(id: 1, kind: DialogKind.prompt, message: 'Your name?'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 540);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(promptField(tester).hasFocus, isTrue);
  });

  testWidgets("with the keyboard put away, Down leaves a prompt's field for its buttons", (tester) async {
    await show(tester, const PageDialog(id: 1, kind: DialogKind.prompt, message: 'Your name?'));
    tester.testTextInput.hide();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(promptField(tester).hasFocus, isFalse);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextButton>(), isNotNull);
  });

  testWidgets("Select brings back a prompt's keyboard put away with Back", (tester) async {
    await show(tester, const PageDialog(id: 1, kind: DialogKind.prompt, message: 'Your name?'));
    tester.testTextInput.hide();
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(promptField(tester).hasFocus, isTrue);
  });
}
