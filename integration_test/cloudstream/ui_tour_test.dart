/// The CloudStream UI in SkyStream: the Settings tile, the CloudStream screen, the provider
/// list with the CloudStream badge, a CloudStream provider's home page on SkyStream's home, and
/// the global switch hiding the providers. Saves a PNG of each screen to the temporary
/// directory and prints its path (`CS3-UI`). Installs Internet Archive if it is missing, and
/// removes whatever it added.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/features/cloudstream/presentation/cloudstream_badge.dart';
import 'package:skystream/shared/widgets/custom_widgets.dart';

import 'support.dart';

Future<void> _shot(WidgetTester tester, String name, {Finder? of}) async =>
    print('CS3-UI $name ${await screenshot(tester, 'cs3-ui-$name', of: of)}');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CloudStream tile, screen, badge, home, and the global switch', (tester) async {
    await withApp(tester, (container) async {
      final notifier = container.read(cloudStreamRepositoryProvider.notifier);
      final wasEnabled = container.read(cloudStreamRepositoryProvider).enabled;
      if (!wasEnabled) await tester.runAsync(() => notifier.setEnabled(true));
      final changes = await ensureInstalled(tester, container, internalName: 'InternetArchiveProvider');
      try {
        go(tester, '/settings');
        await waitFor(tester, find.text('Settings'));
        final tile = find.text('CloudStream Extensions');
        await reveal(tester, tile);
        await pumpFor(tester, const Duration(seconds: 1));
        await _shot(tester, '1-settings-tile');

        await tester.tap(tile.first);
        await waitFor(tester, find.text('Add Repository'));
        await pumpFor(tester, const Duration(seconds: 2));
        await _shot(tester, '2-cloudstream-installed');
        await tester.tap(find.text('Repositories'));
        await pumpFor(tester, const Duration(seconds: 2));
        await _shot(tester, '3-cloudstream-repositories');

        // Home with Internet Archive picked from the provider list.
        go(tester, '/home');
        await pumpFor(tester, const Duration(seconds: 2));
        final picker = find.byIcon(Icons.extension);
        await waitFor(tester, picker);
        await tester.tap(picker.first);
        await waitFor(tester, find.byType(CloudStreamBadge));
        await pumpFor(tester, const Duration(seconds: 1));
        await _shot(tester, '4-provider-list-badge', of: find.byType(CloudStreamBadge));
        print('CS3-UI badges in the provider list: ${find.byType(CloudStreamBadge).evaluate().length}');
        await tester.tap(find.text('Internet Archive').last);
        await pumpFor(tester, const Duration(seconds: 15));
        await _shot(tester, '5-home-internet-archive');

        // The global switch: off hides CloudStream providers from the list.
        go(tester, '/settings/cloudstream');
        await waitFor(tester, find.text('Add Repository'));
        await tester.tap(find.byType(CustomSwitch).first);
        await pumpFor(tester, const Duration(seconds: 2));
        await _shot(tester, '6-cloudstream-switched-off');
        go(tester, '/home');
        await pumpFor(tester, const Duration(seconds: 2));
        await tester.tap(find.byIcon(Icons.extension).first);
        await pumpFor(tester, const Duration(seconds: 2));
        final badgesWhenOff = find.byType(CloudStreamBadge).evaluate().length;
        await _shot(tester, '7-provider-list-when-off');
        print('CS3-UI badges in the provider list with CloudStream off: $badgesWhenOff');

        // Back on. The list's own button closes it: a tap outside can land on the desktop
        // window's title bar instead.
        await tester.tap(find.widgetWithText(TextButton, 'Close').last);
        await pumpFor(tester, const Duration(seconds: 1));
        go(tester, '/settings/cloudstream');
        await waitFor(tester, find.text('Add Repository'));
        await tester.tap(find.byType(CustomSwitch).first);
        await pumpFor(tester, const Duration(seconds: 2));
        expect(badgesWhenOff, 0, reason: 'CloudStream providers still listed with CloudStream switched off');
        expect(container.read(cloudStreamRepositoryProvider).enabled, isTrue,
            reason: 'the switch did not turn CloudStream back on');
      } finally {
        // As it was, also when a step above failed with CloudStream switched off.
        if (container.read(cloudStreamRepositoryProvider).enabled != wasEnabled) {
          await tester.runAsync(() => notifier.setEnabled(wasEnabled));
        }
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null, timeout: const Timeout(Duration(minutes: 10)));
}
