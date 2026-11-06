/// CNC Verse's settings, round trip, through SkyStream's sheet as a person uses it (the spec's "CNC
/// Verse's round trip"): its Settings button, Disney ticked the other way, Save settings, the restart
/// alert's Yes. The app runs on, the extension reloads with Disney's provider gone (or back), Home's
/// providers follow, and the way back restores them. Live: CNC's repository and CNC Verse come from
/// GitHub.
///
/// ```
/// flutter test integration_test/cloudstream/cnc_round_trip_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true --dart-define-from-file=DEFINES
/// ```
// The printed line is the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_sheet.dart';

import 'support.dart';

const _cnc = 'https://raw.githubusercontent.com/NivinCNC/CNCVerse-Cloud-Stream-Extension/refs/heads/builds/CNC.json';
const _name = 'CNC Verse';

/// CNC Verse's providers, as its last load reported them.
Set<String> _providers(ProviderContainer container) => {
  for (final provider
      in container
          .read(cloudStreamRepositoryProvider)
          .installed
          .firstWhere((p) => p.info.internalName == _name)
          .providers)
    provider.name,
};

/// CNC Verse's providers among Home's: CloudStream's sit beside the app's own.
Set<String> _onHome(ProviderContainer container) => {
  for (final provider in container.read(extensionManagerProvider).whereType<CloudStreamProvider>())
    if (provider.plugin.info.internalName == _name) provider.name,
};

Finder _inSheet(Finder finder) => find.descendant(of: find.byType(ExtensionSheet), matching: finder);

/// Opens CNC Verse's settings, ticks Disney the other way, saves, answers the restart alert's Yes, and
/// returns once the reload has applied it, on Home too.
Future<void> _flipDisney(WidgetTester tester, ProviderContainer container) async {
  final hadDisney = _providers(container).contains('Disney');
  // Also takes the last trip's snackbar away, so this one's is the one read.
  go(tester, '/settings/cloudstream');
  final button = find.byKey(const ValueKey('cs3_settings_$_name'));
  await waitFor(tester, button);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await waitFor(tester, _inSheet(find.text('Select studios to show on home')), timeout: const Duration(seconds: 30));
  // The sheet is there before it has slid up: taps wait for it to be in place.
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(_inSheet(find.text('Disney')));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(_inSheet(find.byTooltip('Save settings')));
  await waitFor(tester, find.text('Restart Required'), timeout: const Duration(seconds: 10));
  await tester.tap(find.text('Yes'));
  await pumpUntil(tester, () => find.byType(ExtensionSheet).evaluate().isEmpty, what: 'the sheet closed');
  await pumpUntil(
    tester,
    () => _providers(container).contains('Disney') != hadDisney,
    what: 'the reload ${hadDisney ? 'dropped' : 'brought back'} Disney',
  );
  expect(snackBarText(tester), contains("$_name's settings applied"));
  await pumpUntil(
    tester,
    () =>
        _onHome(container).length == _providers(container).length &&
        _onHome(container).containsAll(_providers(container)),
    what: "Home's providers following the reload",
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    "CNC Verse's settings apply through the sheet, both ways, and never restart the app",
    (tester) async {
      await withApp(tester, (container) async {
        final changes = await ensureInstalled(tester, container, repository: _cnc, internalName: _name);
        final events = <Map<String, dynamic>>[];
        final listening = container.read(cloudStreamEngineHostProvider).events.listen(events.add);
        try {
          await pumpUntil(tester, () => _providers(container).isNotEmpty, what: "CNC Verse's providers");
          final before = _providers(container);
          await _flipDisney(tester, container);
          final flipped = _providers(container);
          expect(flipped.length, before.length + (before.contains('Disney') ? -1 : 1));
          await _flipDisney(tester, container);
          expect(_providers(container), before, reason: 'the way back restores them');
          expect(
            events.where((e) => e['event'] == 'restartRequested'),
            hasLength(2),
            reason: 'both restarts were stopped, and heard',
          );
          print(
            'CS3-CNC ${Platform.operatingSystem} ${jsonEncode({'before': before.toList(), 'flipped': flipped.toList()})}',
          );
        } finally {
          await listening.cancel();
          await changes.undo(tester, container);
        }
      });
    },
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
