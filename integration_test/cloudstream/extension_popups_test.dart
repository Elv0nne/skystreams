/// The test extension's own windows outside its settings, on a device (the spec's pop-up rules):
/// - Home's support pop-up shows nothing over the app: the extension's row gains Support, which opens it live in
///   SkyStream's sheet; closing the sheet puts it back behind Support, which opens it again as it was; its own
///   Later closes it, and the button goes; the same pop-up again (from each provider, and from Home loaded twice)
///   is kept once;
/// - the page dialog its search shows is dropped once sorted (5 s on, its call still waiting), so the search doesn't
///   wait it out (20 s);
/// - the choice its links show while the person waits opens in the sheet, and the person's pick reaches it;
/// - on a TV, the sheet Support opens is full screen, the D-pad presses the pop-up's buttons, and Back closes it.
///
/// Its second provider may be off (extension_settings_test.dart's TV run leaves it so): Home runs on the
/// providers it has.
///
/// ```
/// packages/cs3_engine/tool/build_test_extension.sh
/// python3 -m http.server 8765 --directory packages/cs3_engine/test_extension/build &
/// flutter test integration_test/cloudstream/extension_popups_test.dart -d DEVICE \
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
import 'package:skystream/core/cloudstream/cloudstream_models.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_sheet.dart';

import 'support.dart';
import 'test_extension.dart';

const _tvKeys = bool.fromEnvironment('CS3_TV_KEYS');

Finder _inSheet(Finder finder) => find.descendant(of: find.byType(ExtensionSheet), matching: finder);

List<String> _kept(ProviderContainer container, String path) =>
    container.read(cloudStreamRepositoryProvider).popups[CloudStreamRepository.pathKey(path)] ?? const [];

/// The label of the control the D-pad is on: its first text (as extension_settings_test.dart reads it).
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

/// Home's support pop-up, from each of [plugin]'s providers and from the first again (Home loaded twice):
/// kept once, with nothing shown.
Future<void> _homeLoads(
  WidgetTester tester,
  ProviderContainer container,
  CsInstalledPlugin plugin,
  List<Map<String, dynamic>> events,
) async {
  final host = container.read(cloudStreamEngineHostProvider);
  final path = plugin.filePath;
  final providers = [for (final p in plugin.providers) p.name];
  for (final provider in [...providers, providers.first]) {
    await whilePumping(tester, host.run(path, (e) => e.mainPage(provider, plugin: path), kind: 'mainPage'));
  }
  await pumpUntil(tester, () => _kept(container, path).isNotEmpty, what: 'the support pop-up kept');
  await pumpFor(tester, const Duration(seconds: 1));
  expect(_kept(container, path), ['Support SkyStream Test'], reason: 'the same pop-up twice is kept once');
  expect(events.where((e) => e['event'] == 'uiOpened'), isEmpty, reason: 'Home is a background call');
  expect(events.where((e) => e['event'] == 'popupEscaped'), isEmpty, reason: 'nothing showed over the app');
  expect(find.byType(ExtensionSheet), findsNothing);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    "an extension's own windows never show over the app: kept, dropped, or in the sheet while the person waits",
    (tester) async {
      await withApp(tester, (container) async {
        final changes = await CloudStreamChanges.note(tester, container);
        final host = container.read(cloudStreamEngineHostProvider);
        final events = <Map<String, dynamic>>[];
        final listening = host.events.listen(events.add);
        final plugin = await installTestExtension(tester, container);
        final path = plugin.filePath;
        try {
          await _homeLoads(tester, container, plugin, events);

          // Support opens it live: its button works.
          go(tester, '/settings/cloudstream');
          final support = find.byKey(const ValueKey('cs3_support_SkyStreamTest'));
          await waitFor(tester, support);
          await tester.tap(support);
          await waitFor(
            tester,
            _inSheet(find.text('Keep the test extension alive.')),
            timeout: const Duration(seconds: 30),
          );
          // The sheet is there before it has slid up: taps wait for it to be in place.
          await tester.pump(const Duration(seconds: 1));
          await tester.tap(_inSheet(find.text('Count me in')));
          await waitFor(tester, _inSheet(find.text('Thanks!')), timeout: const Duration(seconds: 10));
          // Closing the sheet puts it back behind Support (the owner, 2026-10-08): the same live pop-up, still
          // thanking, opens again.
          await tester.tap(_inSheet(find.byTooltip('Close')).first);
          await pumpUntil(tester, () => find.byType(ExtensionSheet).evaluate().isEmpty, what: 'the sheet closed');
          await pumpUntil(tester, () => _kept(container, path).isNotEmpty, what: 'the pop-up back behind Support');
          await waitFor(tester, support);
          await tester.tap(support);
          await waitFor(tester, _inSheet(find.text('Thanks!')), timeout: const Duration(seconds: 30));
          await tester.pump(const Duration(seconds: 1));
          // Its own Later closes it: the extension's close, so it's gone, and Support with it.
          await tester.tap(_inSheet(find.text('Later')));
          await pumpUntil(tester, () => find.byType(ExtensionSheet).evaluate().isEmpty, what: 'the sheet closed');
          await pumpUntil(tester, () => support.evaluate().isEmpty, what: 'Support gone with its pop-up');
          expect(
            container.read(cloudStreamRepositoryProvider).applying,
            isEmpty,
            reason: "a pop-up's screen reloads nothing",
          );

          // Search: its own bot check holds a page its call waits on; dropped once sorted, 5 s on, so the search
          // doesn't wait it out (20 s).
          final searching = Stopwatch()..start();
          await whilePumping(
            tester,
            host.run(path, (e) => e.search('SkyStream Test A', 'anything', plugin: path), kind: 'search'),
          );
          expect(searching.elapsed, lessThan(const Duration(seconds: 10)));
          expect(events.where((e) => e['event'] == 'popupDropped' && e['reason'] == 'page'), isNotEmpty);
          expect(find.byType(ExtensionSheet), findsNothing);

          // Links: the person waits, so the extension's choice opens in the sheet, and their pick reaches it.
          final links = host.run(
            path,
            (e) => e.loadLinks('SkyStream Test A', 'https://skystream.invalid/play/1', plugin: path),
            kind: 'loadLinks',
          );
          await waitFor(tester, _inSheet(find.text('Pick a server')), timeout: const Duration(seconds: 30));
          await tester.pump(const Duration(seconds: 1));
          await tester.tap(_inSheet(find.text('Server 2')));
          final answer = await whilePumping(tester, links);
          expect(((answer['links'] as List).single as Map)['url'], endsWith('server-2.m3u8'));
          await pumpUntil(
            tester,
            () => find.byType(ExtensionSheet).evaluate().isEmpty,
            what: 'the sheet closed with its window',
          );
          expect(events.where((e) => e['event'] == 'popupEscaped'), isEmpty);
          print('CS3-POPUPS ${Platform.operatingSystem} passed');
        } finally {
          await listening.cancel();
          await tester.runAsync(() => container.read(cloudStreamRepositoryProvider.notifier).uninstall(plugin));
          await changes.undo(tester, container);
        }
      });
    },
    skip: skipReason != null || testExtensionUrl.isEmpty || _tvKeys,
  );

  testWidgets("on a TV, Support's sheet is full screen, the D-pad presses the pop-up's buttons, and Back closes it", (
    tester,
  ) async {
    await withApp(tester, (container) async {
      final changes = await CloudStreamChanges.note(tester, container);
      final host = container.read(cloudStreamEngineHostProvider);
      final events = <Map<String, dynamic>>[];
      final listening = host.events.listen(events.add);
      final plugin = await installTestExtension(tester, container);
      try {
        await _homeLoads(tester, container, plugin, events);
        go(tester, '/settings/cloudstream');
        // Tapped, as the settings test taps Settings: the row's D-pad order is the CloudStream screen's, not this part's.
        final support = find.byKey(const ValueKey('cs3_support_SkyStreamTest'));
        await waitFor(tester, support);
        await tester.tap(support);
        await waitFor(
          tester,
          _inSheet(find.text('Keep the test extension alive.')),
          timeout: const Duration(seconds: 30),
        );
        // The sheet is there before it has slid up: keys wait for it to be in place.
        await tester.pump(const Duration(seconds: 1));
        final dialog = tester.widget<Dialog>(
          find.ancestor(of: find.byType(ExtensionSheet), matching: find.byType(Dialog)),
        );
        expect(dialog.insetPadding, EdgeInsets.zero, reason: 'full screen');
        for (var i = 0; i < 20 && _focusedLabel() != 'Count me in'; i++) {
          await tester.sendKeyEvent(
            _focusedLabel() == 'Later' ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowDown,
          );
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(_focusedLabel(), 'Count me in');
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await waitFor(tester, _inSheet(find.text('Thanks!')), timeout: const Duration(seconds: 10));
        // The remote's Back closes the pop-up, and with it the sheet.
        await tester.binding.handlePopRoute();
        await pumpUntil(tester, () => find.byType(ExtensionSheet).evaluate().isEmpty, what: 'the sheet closed');
        // Back put it back behind Support (the owner, 2026-10-08): the button stays.
        await pumpUntil(
          tester,
          () => _kept(container, plugin.filePath).isNotEmpty,
          what: 'the pop-up back behind Support',
        );
        expect(support, findsOneWidget);
        print('CS3-POPUPS-TV passed');
      } finally {
        await listening.cancel();
        await tester.runAsync(() => container.read(cloudStreamRepositoryProvider.notifier).uninstall(plugin));
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null || testExtensionUrl.isEmpty || !_tvKeys);
}
