/// The CloudStream switch on a device (the spec's §8, as the owner set it on 2026-10-07), with the test extension:
/// - off: the extension loaded this run is unloaded at once, and its kept pop-up and Support button go with it. Its
///   providers leave the provider list, Home's active one included, and nothing loads it while off: a call a screen
///   still holds fails, and its row's Settings waits for the switch;
/// - on again: its providers are back, Home's provider comes back by itself, and it loads again when used;
/// - on a TV, the D-pad reaches the switch and switches it both ways.
///
/// ```
/// packages/cs3_engine/tool/build_test_extension.sh
/// python3 -m http.server 8765 --directory packages/cs3_engine/test_extension/build &
/// flutter test integration_test/cloudstream/cloudstream_switch_test.dart -d DEVICE \
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
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/extensions/extension_manager.dart';

import 'support.dart';
import 'test_extension.dart';

const _tvKeys = bool.fromEnvironment('CS3_TV_KEYS');
const _a = 'SkyStream Test A';

/// The test extension's providers the app lists now: Home, search and the provider list draw from these.
List<String> _listed(ProviderContainer container) => [
  for (final p in container.read(extensionManagerProvider))
    if (p is CloudStreamProvider && p.plugin.info.internalName == testExtensionInfo.internalName) p.info.name,
]..sort();

/// Whether the engine has the test extension's provider A registered: whether it's loaded.
Future<bool> _loaded(CloudStreamEngineHost host) async =>
    (await (await host.engine()).providers()).any((p) => p is Map && p['name'] == _a);

/// Whether the focus is on the control keyed [key], or inside it.
bool _focusedIn(String key) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  if (focused.widget.key == ValueKey(key)) return true;
  var found = false;
  focused.visitAncestorElements((element) {
    found = element.widget.key == ValueKey(key);
    return !found;
  });
  return found;
}

/// Uninstalls the test extension with CloudStream switched on again, as found.
Future<void> _cleanUp(WidgetTester tester, ProviderContainer container) => tester.runAsync(() async {
  final notifier = container.read(cloudStreamRepositoryProvider.notifier);
  await notifier.setEnabled(true);
  final installed = container
      .read(cloudStreamRepositoryProvider)
      .installed
      .where((p) => p.info.internalName == testExtensionInfo.internalName)
      .firstOrNull;
  if (installed != null) await notifier.uninstall(installed);
});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("CloudStream switched off: none of its extensions is loaded or listed; on again, it's all back", (
    tester,
  ) async {
    await withApp(tester, (container) async {
      final changes = await CloudStreamChanges.note(tester, container);
      final host = container.read(cloudStreamEngineHostProvider);
      final plugin = await installTestExtension(tester, container);
      final path = plugin.filePath;
      try {
        final listed = _listed(container);
        expect(listed, contains(_a));
        // Home on A, and A loaded: its Home's support pop-up is kept for Support.
        final homeA = container
            .read(extensionManagerProvider)
            .whereType<CloudStreamProvider>()
            .firstWhere((p) => p.info.name == _a);
        await tester.runAsync(() => container.read(activeProviderProvider.notifier).set(homeA));
        await whilePumping(tester, host.run(path, (e) => e.mainPage(_a, plugin: path), kind: 'mainPage'));
        await pumpUntil(
          tester,
          () => container.read(cloudStreamRepositoryProvider).popupsFor(plugin).isNotEmpty,
          what: 'its pop-up kept',
        );
        expect(await whilePumping(tester, _loaded(host)), isTrue);

        go(tester, '/settings/cloudstream');
        final toggle = find.byKey(const ValueKey('cs3_cloudstream_switch'));
        await waitFor(tester, toggle);
        await waitFor(tester, find.byKey(const ValueKey('cs3_support_SkyStreamTest')));

        // Off: unloaded at once, its kept pop-up with it (Review Focus 2), and gone from the list.
        await tester.tap(toggle);
        await pumpUntil(tester, () => _listed(container).isEmpty, what: 'its providers left the list');
        await pumpUntil(
          tester,
          () => container.read(cloudStreamRepositoryProvider).popupsFor(plugin).isEmpty,
          what: 'its kept pop-up went with it',
        );
        await pumpFor(tester, const Duration(seconds: 1));
        expect(await whilePumping(tester, _loaded(host)), isFalse, reason: 'unloaded at once');
        expect(container.read(activeProviderProvider), isNull, reason: "Home's provider went with it");
        expect(find.byKey(const ValueKey('cs3_support_SkyStreamTest')), findsNothing);
        final settings = tester.widget<IconButton>(find.byKey(const ValueKey('cs3_settings_SkyStreamTest')));
        expect(settings.onPressed, isNull, reason: 'Settings waits for the switch');
        // A screen still holding its provider can't load it back (Review Focus 1).
        Object? refused;
        await tester.runAsync(() async {
          try {
            await host.run(path, (e) => e.mainPage(_a, plugin: path), kind: 'mainPage');
          } catch (error) {
            refused = error;
          }
        });
        expect(refused, isA<CloudStreamSwitchedOff>());
        expect(await whilePumping(tester, _loaded(host)), isFalse);

        // On again: listed, Home's provider back by itself (Review Focus 4), and loaded when used.
        await tester.tap(toggle);
        await pumpUntil(tester, () => _listed(container).isNotEmpty, what: 'its providers back');
        expect(_listed(container), listed);
        await pumpUntil(tester, () => container.read(activeProviderProvider)?.name == _a, what: "Home's provider back");
        expect(await whilePumping(tester, _loaded(host)), isFalse, reason: 'nothing loads until used');
        await whilePumping(tester, host.run(path, (e) => e.mainPage(_a, plugin: path), kind: 'mainPage'));
        expect(await whilePumping(tester, _loaded(host)), isTrue);
        print('CS3-SWITCH ${Platform.operatingSystem} passed');
      } finally {
        await _cleanUp(tester, container);
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null || testExtensionUrl.isEmpty || _tvKeys);

  testWidgets("on a TV, the D-pad reaches CloudStream's switch and switches it both ways", (tester) async {
    await withApp(tester, (container) async {
      final changes = await CloudStreamChanges.note(tester, container);
      await installTestExtension(tester, container);
      try {
        final listed = _listed(container);
        go(tester, '/settings/cloudstream');
        await waitFor(tester, find.byKey(const ValueKey('cs3_cloudstream_switch')));
        // Down to the list, then up: down from the tabs passes the header for the rows' buttons, and up from a row
        // goes through the header's buttons to the switch (the TV's focus order).
        for (var i = 0; i < 10; i++) {
          final before = FocusManager.instance.primaryFocus;
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump(const Duration(milliseconds: 150));
          if (FocusManager.instance.primaryFocus == before) break;
        }
        for (var i = 0; i < 10 && !_focusedIn('cs3_cloudstream_switch'); i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.pump(const Duration(milliseconds: 150));
        }
        expect(_focusedIn('cs3_cloudstream_switch'), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await pumpUntil(tester, () => _listed(container).isEmpty, what: 'switched off by the D-pad');
        await tester.pump(const Duration(milliseconds: 300));
        expect(_focusedIn('cs3_cloudstream_switch'), isTrue, reason: 'the focus stays on the switch');
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await pumpUntil(tester, () => _listed(container).isNotEmpty, what: 'switched on by the D-pad');
        expect(_listed(container), listed);
        print('CS3-SWITCH-TV passed');
      } finally {
        await _cleanUp(tester, container);
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null || testExtensionUrl.isEmpty || !_tvKeys);
}
