/// A CloudStream title's page shows what its extension sent (CloudStream details, Part 1): the test extension's
/// rich title (`/anime/rich`) through the real engine, on a device: the status, content rating and score, the plot
/// decoded, tags, the next airing, named seasons, an episode's runtime, the cast with a voice actor and a free-text
/// role, and a recommendation from the same extension.
///
/// ```
/// packages/cs3_engine/tool/build_test_extension.sh
/// python3 -m http.server 8765 --bind 127.0.0.1 --directory packages/cs3_engine/test_extension/build &
/// flutter test integration_test/cloudstream/details_metadata_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true --dart-define=CS3_TEST_EXTENSION=http://10.0.2.2:8765/SkyStreamTest.cs3
/// ```
// The printed line is the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/features/details/presentation/widgets/premium_details_widgets.dart';

import 'support.dart';
import 'test_extension.dart';

/// The test extension's first provider, once the app lists it.
CloudStreamProvider? _providerA(ProviderContainer container) => container
    .read(extensionManagerProvider)
    .whereType<CloudStreamProvider>()
    .where((p) => p.plugin.info.internalName == testExtensionInfo.internalName && p.info.name == 'SkyStream Test A')
    .firstOrNull;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("a CloudStream title's page shows what its extension sent", (tester) async {
    await withApp(tester, (container) async {
      final changes = await CloudStreamChanges.note(tester, container);
      await installTestExtension(tester, container);
      try {
        await pumpUntil(tester, () => _providerA(container) != null, what: 'the test extension listed');
        final item = MultimediaItem(
          title: 'Rich Title',
          url: 'https://skystream.invalid/anime/rich',
          posterUrl: '',
          provider: _providerA(container)!.packageName,
          contentType: MultimediaContentType.anime,
        );
        final from = tester.element(find.byType(Scaffold).first);
        DetailsRoute($extra: DetailsRouteExtra(item: item)).push<void>(from).ignore();
        await waitFor(tester, find.text('Ongoing'));

        // Top to bottom, as the page lays them out; each scrolled to first, as the page builds lazily.
        for (final finder in [
          find.text('PG-13'),
          find.text('8.8'),
          find.text('A journey & its end.'),
          find.text('Adventure'),
          find.byType(NextAiringWidget),
          find.text('First Arc'),
          find.text('Season 2: Second Arc'),
          find.textContaining('24 min'),
          find.text('Atsumi Tanezaki'),
          find.text('Hero'),
          find.text('Rich Sequel'),
        ]) {
          await reveal(tester, finder);
          expect(finder, findsWidgets);
        }
        print('CS3-DETAILS ${Platform.operatingSystem} passed');
      } finally {
        await changes.undo(tester, container);
      }
    });
  }, skip: skipReason != null || testExtensionUrl.isEmpty);
}
