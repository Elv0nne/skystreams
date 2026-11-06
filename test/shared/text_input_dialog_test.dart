import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/text_input_dialog.dart';

/// Hosts the dialog behind a button so the test drives it the way the app
/// does: open, type, confirm, and observe what `showDialog` resolves with.
class _Host extends StatelessWidget {
  final ValueChanged<String?> onResult;
  final bool allowEmpty;
  final bool showPasteButton;

  const _Host({
    required this.onResult,
    this.allowEmpty = false,
    this.showPasteButton = false,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () async {
          final value = await TextInputDialog.show(
            context,
            title: 'Add a thing',
            confirmLabel: 'Install',
            allowEmpty: allowEmpty,
            showPasteButton: showPasteButton,
          );
          onResult(value);
        },
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required ValueChanged<String?> onResult,
  bool allowEmpty = false,
  bool showPasteButton = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: _Host(
        onResult: onResult,
        allowEmpty: allowEmpty,
        showPasteButton: showPasteButton,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('confirming survives the exit transition', (tester) async {
    String? popped;
    var completed = false;
    await _pumpHost(
      tester,
      onResult: (value) {
        popped = value;
        completed = true;
      },
    );

    await tester.enterText(find.byType(TextField), '  https://x.test/m.json ');
    await tester.tap(find.text('Install'));

    // One frame, not pumpAndSettle: the route has popped but the dialog's
    // element tree is still mounted for the exit animation. A controller
    // disposed as soon as `await showDialog` returned blew up right here.
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(popped, 'https://x.test/m.json');
  });

  testWidgets('submitting from the keyboard pops with the trimmed value', (
    tester,
  ) async {
    String? popped;
    await _pumpHost(tester, onResult: (value) => popped = value);

    await tester.enterText(find.byType(TextField), ' abc ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();

    expect(popped, 'abc');
  });

  testWidgets('cancel pops with null', (tester) async {
    String? popped = 'sentinel';
    await _pumpHost(tester, onResult: (value) => popped = value);

    await tester.enterText(find.byType(TextField), 'typed but abandoned');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(popped, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('whitespace-only confirm is a no-op unless allowEmpty', (
    tester,
  ) async {
    var resolved = false;
    await _pumpHost(tester, onResult: (_) => resolved = true);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    expect(resolved, isFalse);
    expect(find.byType(TextInputDialog), findsOneWidget);
  });

  testWidgets('allowEmpty pops with the empty string', (tester) async {
    String? popped = 'sentinel';
    await _pumpHost(
      tester,
      allowEmpty: true,
      onResult: (value) => popped = value,
    );

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();

    expect(popped, '');
  });

  testWidgets('paste button fills the field from the clipboard', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': '  https://pasted.test  '};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    String? popped;
    await _pumpHost(
      tester,
      showPasteButton: true,
      onResult: (value) => popped = value,
    );

    await tester.tap(find.byIcon(Icons.content_paste_rounded));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'https://pasted.test',
    );

    await tester.tap(find.text('Install'));
    await tester.pumpAndSettle();
    expect(popped, 'https://pasted.test');
  });
}
