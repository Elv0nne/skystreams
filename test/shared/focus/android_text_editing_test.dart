import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/shared/focus/android_text_editing.dart';

/// Telling Android when a Flutter text field has focus, for the televisions
/// that give a keyboard a session only for a text editor - see
/// TextEditorProxy.kt.
void main() {
  late List<MethodCall> calls;
  late bool needed;
  VoidCallback? stop;

  setUp(() {
    calls = [];
    needed = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidTextEditingChannel, (call) async {
          calls.add(call);
          return call.method == 'needed' ? needed : null;
        });
  });

  tearDown(() {
    stop?.call();
    stop = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidTextEditingChannel, null);
  });

  List<Object?> editing() => [
    for (final call in calls)
      if (call.method == 'editing') call.arguments,
  ];

  Future<(FocusNode, FocusNode)> pumpFieldAndButton(WidgetTester tester) async {
    final field = FocusNode();
    final button = FocusNode();
    addTearDown(field.dispose);
    addTearDown(button.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(focusNode: field),
              TextButton(
                focusNode: button,
                onPressed: () {},
                child: const Text('Go'),
              ),
            ],
          ),
        ),
      ),
    );
    return (field, button);
  }

  testWidgets('says when a text field takes focus and when it leaves, '
      'once each', (tester) async {
    final (field, button) = await pumpFieldAndButton(tester);
    stop = await tester.runAsync<VoidCallback?>(installAndroidTextEditing);

    field.requestFocus();
    await tester.pump();
    field.requestFocus();
    await tester.pump();
    expect(editing(), [true]);

    button.requestFocus();
    await tester.pump();
    expect(editing(), [true, false]);

    field.requestFocus();
    await tester.pump();
    expect(editing(), [true, false, true]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  // A field no keyboard types into is no text editor: reported as one,
  // Android starts the keyboard app with nothing to type into.
  for (final (name, field) in <(String, Widget Function(FocusNode))>[
    ('a SelectableText', (node) => SelectableText('Dune', focusNode: node)),
    (
      'a read-only TextField',
      (node) => TextField(focusNode: node, readOnly: true),
    ),
    (
      'a TextField that wants no keyboard',
      (node) => TextField(focusNode: node, keyboardType: TextInputType.none),
    ),
  ]) {
    testWidgets('says nothing for $name', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: field(node))));
      stop = await tester.runAsync<VoidCallback?>(installAndroidTextEditing);

      node.requestFocus();
      await tester.pump();

      expect(node.hasFocus, isTrue);
      expect(editing(), isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('says nothing where the device gives keyboards a session '
      'anyway', (tester) async {
    needed = false;
    final (field, _) = await pumpFieldAndButton(tester);
    stop = await tester.runAsync<VoidCallback?>(installAndroidTextEditing);

    field.requestFocus();
    await tester.pump();

    expect(editing(), isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('asks nothing off Android', (tester) async {
    final (field, _) = await pumpFieldAndButton(tester);
    stop = await tester.runAsync<VoidCallback?>(installAndroidTextEditing);

    field.requestFocus();
    await tester.pump();

    expect(calls, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a build without the channel is left alone', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(androidTextEditingChannel, null);
    final (field, _) = await pumpFieldAndButton(tester);

    stop = await tester.runAsync<VoidCallback?>(installAndroidTextEditing);
    field.requestFocus();
    await tester.pump();

    expect(stop, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
