/// The test extension's pages on a device (the spec's §9 and §7 for pages):
/// - its sign-in, in its settings: the page shows in the sheet, and its cookie, the Authorization header its script
///   sends, its call of the extension's JavaScript interface, its title, its redirect and the extension's own user
///   agent all reach the extension, which says so in its settings ("Signed in: …");
/// - a page promotion from Home: kept behind Support (5 s on, no call waiting), which opens it, page and all, again
///   after it's closed;
/// - a page while the person waits (a title opening): the sheet shows it, page and all, and closing it ends the wait;
/// - on a TV, the D-pad goes into the promotion's page and out of it again (the way out by the device's own keys: the
///   run presses Up with `adb shell input keyevent 19` when the test prints `CS3-PAGES-TV in the page`).
///
/// ```
/// packages/cs3_engine/tool/build_test_extension.sh
/// python3 -m http.server 8765 --directory packages/cs3_engine/test_extension/build &
/// flutter test integration_test/cloudstream/extension_pages_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true --dart-define=CS3_TEST_EXTENSION=http://10.0.2.2:8765/SkyStreamTest.cs3 \
///   [--dart-define=CS3_TV_KEYS=true] --dart-define-from-file=DEFINES
/// ```
// The printed lines are the test's report.
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
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_page_view.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_sheet.dart';

import 'support.dart';
import 'test_extension.dart';

const _tvKeys = bool.fromEnvironment('CS3_TV_KEYS');

const _signedIn =
    'Signed in: cookie ok, token cs3test-token, name Test Person, title SkyStream Test sign-in, code cs3test-code, '
    'agent ok';

Finder _inSheet(Finder finder) => find.descendant(of: find.byType(ExtensionSheet), matching: finder);

Future<void> _sheetGone(WidgetTester tester) =>
    pumpUntil(tester, () => find.byType(ExtensionSheet).evaluate().isEmpty, what: 'the sheet closed');

List<String> _kept(ProviderContainer container, String path) =>
    container.read(cloudStreamRepositoryProvider).popups[CloudStreamRepository.pathKey(path)] ?? const [];

/// Whether keyboard focus is inside the page's view.
bool _focusInPage() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  return focused.findAncestorWidgetOfExactType<ExtensionPageView>() != null || (focused.widget is ExtensionPageView);
}

/// Home's second page shows a page promotion: kept once sorted, 5 s on, with no call waiting on it.
Future<void> _promotionKept(WidgetTester tester, ProviderContainer container, String path) async {
  final host = container.read(cloudStreamEngineHostProvider);
  await whilePumping(
    tester,
    host.run(path, (e) => e.mainPage('SkyStream Test A', page: 2, plugin: path), kind: 'mainPage'),
  );
  await pumpUntil(
    tester,
    () => _kept(container, path).contains('Test promotion'),
    what: 'the page promotion kept',
    timeout: const Duration(seconds: 20),
  );
  expect(find.byType(ExtensionSheet), findsNothing, reason: 'Home is a background call');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("an extension's pages show in the sheet, and what they do reaches the extension", (tester) async {
    await withApp(tester, (container) async {
      final changes = await CloudStreamChanges.note(tester, container);
      final host = container.read(cloudStreamEngineHostProvider);
      final events = <Map<String, dynamic>>[];
      final listening = host.events.listen(events.add);
      final plugin = await installTestExtension(tester, container);
      final path = plugin.filePath;
      try {
        // The sign-in, in its settings.
        go(tester, '/settings/cloudstream');
        final settings = find.byKey(const ValueKey('cs3_settings_SkyStreamTest'));
        await waitFor(tester, settings);
        await tester.tap(settings);
        await waitFor(tester, _inSheet(find.text('Sign in to the test site')), timeout: const Duration(seconds: 30));
        await tester.pump(const Duration(seconds: 1));
        await reveal(tester, _inSheet(find.text('Sign in to the test site')));
        await tester.tap(_inSheet(find.text('Sign in to the test site')).last);
        await waitFor(tester, _inSheet(find.byType(ExtensionPageView)), timeout: const Duration(seconds: 20));
        print('CS3-PAGES sign-in page shown');
        await waitFor(tester, _inSheet(find.text(_signedIn)), timeout: const Duration(seconds: 45));
        expect(_inSheet(find.byType(ExtensionPageView)), findsNothing, reason: 'its dialog closed once signed in');
        await tester.tap(_inSheet(find.byTooltip('Close')).first);
        await _sheetGone(tester);

        // A page promotion: kept, and Support opens it with its page. Before a title opens: within 5 s after one,
        // the extension's windows are the person's, not the background's.
        await _promotionKept(tester, container, path);
        go(tester, '/settings/cloudstream');
        final support = find.byKey(const ValueKey('cs3_support_SkyStreamTest'));
        await waitFor(tester, support);
        await tester.tap(support);
        await waitFor(tester, _inSheet(find.text('Test promotion')), timeout: const Duration(seconds: 30));
        await waitFor(tester, _inSheet(find.byType(ExtensionPageView)), timeout: const Duration(seconds: 20));
        await tester.pump(const Duration(seconds: 2));
        await tester.binding.handlePopRoute();
        await _sheetGone(tester);
        // Closing put it back behind Support (the owner, 2026-10-08): Support opens it again, page and all.
        await pumpUntil(
          tester,
          () => _kept(container, path).contains('Test promotion'),
          what: 'the promotion back behind Support',
        );
        await waitFor(tester, support);
        await tester.tap(support);
        await waitFor(tester, _inSheet(find.text('Test promotion')), timeout: const Duration(seconds: 30));
        await waitFor(tester, _inSheet(find.byType(ExtensionPageView)), timeout: const Duration(seconds: 20));
        await tester.pump(const Duration(seconds: 2));
        await tester.binding.handlePopRoute();
        await _sheetGone(tester);

        // A page while the person waits on a title opening: shown, page and all; closing it ends the wait.
        final opening = host.run(
          path,
          (e) => e.load('SkyStream Test A', 'https://skystream.invalid/movie/1#verify', plugin: path),
          kind: 'load',
        );
        await waitFor(tester, _inSheet(find.text("Verify you're human")), timeout: const Duration(seconds: 30));
        await waitFor(tester, _inSheet(find.byType(ExtensionPageView)), timeout: const Duration(seconds: 20));
        await tester.pump(const Duration(seconds: 2));
        await tester.binding.handlePopRoute();
        final loaded = await whilePumping(tester, opening);
        expect(loaded['name'], 'Test Movie');
        await _sheetGone(tester);

        expect(events.where((e) => e['event'] == 'popupEscaped'), isEmpty, reason: 'nothing showed over the app');
        print('CS3-PAGES ${Platform.operatingSystem} passed');
      } finally {
        await listening.cancel();
        await tester.runAsync(() => container.read(cloudStreamRepositoryProvider.notifier).uninstall(plugin));
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null || testExtensionUrl.isEmpty || _tvKeys);

  testWidgets("on a TV, the D-pad goes into a page and out of it again", (tester) async {
    await withApp(tester, (container) async {
      final changes = await CloudStreamChanges.note(tester, container);
      final plugin = await installTestExtension(tester, container);
      try {
        await _promotionKept(tester, container, plugin.filePath);
        go(tester, '/settings/cloudstream');
        final support = find.byKey(const ValueKey('cs3_support_SkyStreamTest'));
        await waitFor(tester, support);
        await tester.tap(support);
        await waitFor(tester, _inSheet(find.byType(ExtensionPageView)), timeout: const Duration(seconds: 30));
        await tester.pump(const Duration(seconds: 3));
        for (var i = 0; i < 10 && !_focusInPage(); i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump(const Duration(milliseconds: 300));
        }
        expect(_focusInPage(), isTrue, reason: 'the D-pad went into the page');
        // In the page, the remote's keys go to the WebView itself, which a test's key events (Flutter's own) never
        // reach: the run presses Up on the device (adb) when it reads this line. The page's one link is at its top,
        // so Up from it leaves the page.
        print('CS3-PAGES-TV in the page: press Up');
        await pumpUntil(
          tester,
          () => !_focusInPage(),
          what: 'the D-pad out of the page',
          timeout: const Duration(seconds: 60),
        );
        await tester.binding.handlePopRoute();
        await _sheetGone(tester);
        print('CS3-PAGES-TV passed');
      } finally {
        await tester.runAsync(() => container.read(cloudStreamRepositoryProvider.notifier).uninstall(plugin));
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null || testExtensionUrl.isEmpty || !_tvKeys);
}
