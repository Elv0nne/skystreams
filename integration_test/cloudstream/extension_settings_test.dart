/// An extension's own settings screen in SkyStream's sheet, on a device, with SkyStream's own test
/// extension (test_extension.dart):
/// - on Android, its windows stay invisible and untouchable while the sheet shows them (elsewhere they're
///   the engine's stand-ins, which nothing draws);
/// - every kind of control reaches the extension;
/// - the restart alert's Yes and "Save and restart" never restart the app, and reload the extension;
/// - a closed screen with changes applies them;
/// - Back on the alert closes it alone (Android 16 sends dialogs no Back key), and a swipe down on the
///   sheet's header is Back too;
/// - Force close;
/// - on a TV, the alert takes the D-pad's focus from the sheet behind it.
///
/// ```
/// packages/cs3_engine/tool/build_test_extension.sh
/// python3 -m http.server 8765 --directory packages/cs3_engine/test_extension/build &
/// flutter test integration_test/cloudstream/extension_settings_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true --dart-define=CS3_TEST_EXTENSION=http://10.0.2.2:8765/SkyStreamTest.cs3 \
///   [--dart-define=CS3_TV_KEYS=true] --dart-define-from-file=DEFINES
/// ```
///
/// It expects the test extension's own defaults, as a first install has them (its second provider on, its
/// timeout below the slider's end), and leaves what it saved. Before running it again on the same app
/// data, with the app closed, delete the extension's preferences: on the desktops
/// `<app support>/extensions/cloudstream/engine/shared_prefs/skystream_test.properties`, on Android the
/// app's `shared_prefs/skystream_test.xml`. iOS installs the app afresh for each run.
// The printed line is the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_sheet.dart';

import 'support.dart';
import 'test_extension.dart';

const _tvKeys = bool.fromEnvironment('CS3_TV_KEYS');

List<String> _providers(ProviderContainer container) => container
    .read(cloudStreamRepositoryProvider)
    .installed
    .firstWhere((p) => p.info.internalName == 'SkyStreamTest')
    .providers
    .map((p) => p.name)
    .toList();

Finder _inSheet(Finder finder) => find.descendant(of: find.byType(ExtensionSheet), matching: finder);

/// Brings [finder] into the sheet's view first, as a person scrolls to it: a keyboard left up by a field
/// can cover the lower part of the sheet (the tablet's does).
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _openSettings(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('cs3_settings_SkyStreamTest'));
  await waitFor(tester, button);
  await tester.tap(button);
  await waitFor(tester, find.text('SkyStream test settings'), timeout: const Duration(seconds: 30));
  // The sheet is there before it has slid up: taps wait for it to be in place.
  await tester.pump(const Duration(seconds: 1));
}

/// The label of the control the D-pad is on: its first text.
String? _focusedLabel() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return null;
  String? label;
  void visit(Element element) {
    final widget = element.widget;
    if (label == null && widget is Text) label = widget.data;
    if (label == null) element.visitChildren(visit);
  }

  (focused as Element).visitChildren(visit);
  return label;
}

Future<void> _sheetGone(WidgetTester tester) =>
    pumpUntil(tester, () => find.byType(ExtensionSheet).evaluate().isEmpty, what: 'the sheet closed');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("an extension's settings open in SkyStream's sheet, apply without a restart, and never restart the app", (
    tester,
  ) async {
    await withApp(tester, (container) async {
      final changes = await CloudStreamChanges.note(tester, container);
      final events = <Map<String, dynamic>>[];
      final listening = container.read(cloudStreamEngineHostProvider).events.listen(events.add);
      final plugin = await installTestExtension(tester, container);
      try {
        go(tester, '/settings/cloudstream');
        await _openSettings(tester);

        // On Android the extension's own windows are invisible and untouchable: the sheet is SkyStream's
        // drawing. Elsewhere they're the engine's stand-ins, which nothing draws, and say nothing of it.
        if (Platform.isAndroid) expect(lastWindows(events).every((w) => w.hidden == true), isTrue);
        expect(find.text('Second provider'), findsOneWidget);
        expect(find.text('Dark posters'), findsOneWidget);

        // Every kind of control reaches the extension.
        await _reveal(tester, _inSheet(find.text('Second provider')));
        await tester.tap(_inSheet(find.text('Second provider')));
        await pumpUntil(tester, () {
          final box = findNode(lastWindows(events).first.root, (n) => n.kind == UiKind.checkbox);
          return box != null && !box.checked;
        }, what: 'the extension unticked its box');
        await _reveal(tester, _inSheet(find.byType(TextField)).first);
        await tester.enterText(_inSheet(find.byType(TextField)).first, 'abc123');
        // Done typing: the keyboard goes, as when a person taps elsewhere, and the sheet takes its size back.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump(const Duration(seconds: 1));
        await _reveal(tester, _inSheet(find.byType(DropdownButtonFormField<int>)));
        await tester.tap(_inSheet(find.byType(DropdownButtonFormField<int>)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('1080p').last);
        // The menu is gone only after a frame; until then it takes the next tap.
        await tester.pumpAndSettle();
        await _reveal(tester, _inSheet(find.text('Careful')));
        await tester.tap(_inSheet(find.text('Careful')));
        await _reveal(tester, _inSheet(find.byType(Slider)));
        await tester.drag(_inSheet(find.byType(Slider)), const Offset(4000, 0));
        await waitFor(tester, find.text('Timeout: 60 s'), timeout: const Duration(seconds: 10));
        final list = _inSheet(find.byType(Scrollable)).first;
        await tester.scrollUntilVisible(_inSheet(find.text('Item 30')), 200, scrollable: list);
        await tester.tap(_inSheet(find.text('Item 30')));
        await waitFor(tester, find.text('Picked: Item 30'), timeout: const Duration(seconds: 10));

        // Save; the restart alert's Yes reloads the extension, without its second provider, and the app runs on.
        await tester.scrollUntilVisible(_inSheet(find.text('Save')), 200, scrollable: list);
        await tester.tap(_inSheet(find.text('Save')));
        await waitFor(tester, find.text('Restart required'), timeout: const Duration(seconds: 10));
        await tester.tap(find.text('Yes'));
        await _sheetGone(tester);
        expect(events.any((e) => e['event'] == 'restartRequested'), isTrue);
        await pumpUntil(
          tester,
          () => _providers(container).length == 1,
          what: 'the reload dropped the second provider',
        );
        expect(_providers(container), ['SkyStream Test A']);

        // Back on, closed with No: a change applies once the screen closes.
        await _openSettings(tester);
        await _reveal(tester, _inSheet(find.text('Second provider')));
        await tester.tap(_inSheet(find.text('Second provider')));
        await tester.pump(const Duration(milliseconds: 500));
        final save = _inSheet(find.text('Save'));
        await tester.scrollUntilVisible(save, 200, scrollable: _inSheet(find.byType(Scrollable)).first);
        await tester.tap(save);
        await waitFor(tester, find.text('Restart required'), timeout: const Duration(seconds: 10));
        await tester.tap(find.text('No'));
        await _sheetGone(tester);
        await pumpUntil(
          tester,
          () => _providers(container).length == 2,
          what: 'the reload brought the second provider back',
        );
        expect(snackBarText(tester), contains("SkyStream Test's settings applied"));

        // Back on the alert closes the alert alone, as on any phone (Android 16 sends a dialog no Back key);
        // a swipe down on the sheet's header is Back too, and closes the extension's screen, then the sheet.
        await _openSettings(tester);
        await tester.scrollUntilVisible(save, 200, scrollable: _inSheet(find.byType(Scrollable)).first);
        await tester.tap(save);
        await waitFor(tester, find.text('Restart required'), timeout: const Duration(seconds: 10));
        await tester.binding.handlePopRoute();
        await pumpUntil(tester, () => find.text('Restart required').evaluate().isEmpty, what: 'Back closed the alert');
        expect(find.byType(ExtensionSheet), findsOneWidget, reason: 'its screen stays');
        expect(lastWindows(events), hasLength(1));
        await tester.fling(_inSheet(find.text('SkyStream Test')), const Offset(0, 300), 1500);
        await _sheetGone(tester);
        await pumpUntil(
          tester,
          () => container.read(cloudStreamRepositoryProvider).applying.isEmpty,
          what: 'the saved change applied',
        );

        // "Save and restart" restarts through the activity: stopped too.
        await _openSettings(tester);
        final restart = _inSheet(find.text('Save and restart'));
        await tester.scrollUntilVisible(restart, 200, scrollable: _inSheet(find.byType(Scrollable)).first);
        await tester.tap(restart);
        await _sheetGone(tester);

        // Force close shuts the screen.
        await _openSettings(tester);
        final closedBefore = events.where((e) => e['event'] == 'uiClosed').length;
        await tester.tap(find.byTooltip('More'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Force close'));
        await _sheetGone(tester);
        expect(events.where((e) => e['event'] == 'uiClosed').length, closedBefore + 1);
        print('CS3-SETTINGS ${Platform.operatingSystem} passed');
      } finally {
        await listening.cancel();
        await tester.runAsync(() => container.read(cloudStreamRepositoryProvider.notifier).uninstall(plugin));
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null || testExtensionUrl.isEmpty || _tvKeys);

  testWidgets('on a TV the sheet is full screen and the D-pad reaches its controls', (tester) async {
    await withApp(tester, (container) async {
      final changes = await CloudStreamChanges.note(tester, container);
      final events = <Map<String, dynamic>>[];
      final listening = container.read(cloudStreamEngineHostProvider).events.listen(events.add);
      final plugin = await installTestExtension(tester, container);
      try {
        go(tester, '/settings/cloudstream');
        await _openSettings(tester);
        final dialog = tester.widget<Dialog>(
          find.ancestor(of: find.byType(ExtensionSheet), matching: find.byType(Dialog)),
        );
        expect(dialog.insetPadding, EdgeInsets.zero, reason: 'full screen');
        String? focused() =>
            FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<ListTile>()?.title.toString();
        for (var i = 0; i < 30 && !(focused()?.contains('Second provider') ?? false); i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(focused(), contains('Second provider'));
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await pumpUntil(tester, () {
          final box = findNode(lastWindows(events).first.root, (n) => n.kind == UiKind.checkbox);
          return box != null && !box.checked;
        }, what: 'select on the D-pad ticked the box off');

        // Save by the D-pad: the restart alert takes the focus from the sheet behind it, so select acts on
        // the alert (its No closes it and the screen), not on Save again.
        // Down to the end: from the list's last item it skips Save and its neighbour, beside the item's column, for
        // the full-width sign-in row below them (part 5's); a sideways press, then Up, reaches Save (Flutter's
        // directional focus otherwise retraces the last move), as a person would go.
        for (var i = 0; i < 80 && _focusedLabel() != 'Save' && _focusedLabel() != 'Sign in to the test site'; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump(const Duration(milliseconds: 150));
        }
        if (_focusedLabel() == 'Sign in to the test site') {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump(const Duration(milliseconds: 150));
          for (var i = 0; i < 4 && _focusedLabel() != 'Save'; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            await tester.pump(const Duration(milliseconds: 150));
          }
        }
        expect(_focusedLabel(), 'Save');
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await waitFor(tester, find.text('Restart required'), timeout: const Duration(seconds: 10));
        await tester.pump(const Duration(milliseconds: 500));
        expect(_focusedLabel(), anyOf('No', 'Yes'), reason: "the alert's first button has the focus");
        for (var i = 0; i < 4 && _focusedLabel() != 'No'; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(_focusedLabel(), 'No');
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await _sheetGone(tester);

        // The remote's Back reaches the app as the system's back, not as a key.
        await pumpUntil(
          tester,
          () => container.read(cloudStreamRepositoryProvider).applying.isEmpty,
          what: 'the change applied',
        );
        await _openSettings(tester);
        await tester.binding.handlePopRoute();
        await _sheetGone(tester);
        print('CS3-SETTINGS-TV passed');
      } finally {
        await listening.cancel();
        await tester.runAsync(() => container.read(cloudStreamRepositoryProvider.notifier).uninstall(plugin));
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null || testExtensionUrl.isEmpty || !_tvKeys);
}
