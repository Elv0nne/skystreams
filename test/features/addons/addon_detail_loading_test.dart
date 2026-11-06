/// The Stremio page's loading placeholder fits a phone held sideways (found
/// by the Stremio direct-play device test: the page reloaded behind the
/// player, and a viewer coming back in landscape met a placeholder 123 points
/// taller than the screen).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/features/addons/presentation/addon_detail_screen.dart';
import 'package:skystream/features/addons/presentation/addon_providers.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'stremio_page_fakes.dart';

void main() {
  useTestClearance();

  for (final (form, size) in [
    ('a phone held sideways', const Size(874, 402)),
    ('a phone held upright', const Size(402, 874)),
  ]) {
    testWidgets('on $form, the loading placeholder fits', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            addonRepositoryProvider.overrideWith(BridgeRepo.new),
            addonMetaProvider(
              'other',
              'cnc:show',
              preferredAddonUrl: kBridgeUrl,
            ).overrideWith((ref) => Completer<AddonMeta?>().future),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AddonDetailScreen(
              type: 'other',
              id: 'cnc:show',
              addonUrl: kBridgeUrl,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
