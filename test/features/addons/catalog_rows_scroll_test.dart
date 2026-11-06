/// The Stremio catalog tab has to scroll back up through rows it has shown.
///
/// A bridge add-on - CNCVerse and the like - publishes dozens of catalogs, and
/// a good share of them come back empty. An empty catalog used to stay in the
/// lazily built list as a zero-height row. [SliverList] places rows it
/// rebuilds on the way back up by dead reckoning, and near-zero rows at that
/// leading edge threw it into a loop of corrections: every drag upward was
/// cancelled by a scroll-offset correction, the offset ran past the end of
/// the content, and the list jittered and bounced instead of scrolling.
///
/// Measured in this harness against the height an empty row was given: 0 px
/// and 1 px both jam, 56 px and up scroll normally, and failed catalogs, whose
/// error rows have real height, never did. So empty catalogs leave the list.
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/addons/presentation/addons_screen.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const int _catalogCount = 40;

/// One bridge add-on publishing [_catalogCount] browsable catalogs.
class _Repo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    isLoading: false,
    addons: [
      ManagedAddon(
        manifestUrl: 'https://bridge.test/manifest.json',
        addedAt: DateTime(2026),
        manifest: AddonManifest(
          id: 'bridge',
          name: 'Bridge',
          version: '1',
          resources: const [
            AddonResource(name: 'catalog'),
            AddonResource(name: 'stream'),
          ],
          types: const ['other'],
          catalogs: [
            for (var i = 0; i < _catalogCount; i++)
              AddonCatalog(type: 'other', id: 'c$i', name: 'Provider $i'),
          ],
        ),
      ),
    ],
  );
}

/// Answers straight away, as the client's cache does for a row seen before.
///
/// Every third catalog is empty and every fifth one fails, which is what a
/// bridge's upstreams do. The first is empty too, so there is no hero
/// carousel and its timers stay out of the test.
class _Client extends AddonClient {
  _Client() : super(Dio());

  @override
  Future<List<AddonMetaPreview>> catalog(
    ManagedAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final n = int.parse(id.substring(1));
    if (n % 3 == 0) return const <AddonMetaPreview>[];
    if (n % 5 == 0) throw Exception('upstream answered 500');
    return [
      for (var i = 0; i < 10; i++)
        AddonMetaPreview(
          id: 'tt$n$i',
          type: 'movie',
          name: 'Title $n.$i',
          poster: 'https://img.test/$n/$i.jpg',
        ),
    ];
  }
}

void main() {
  testWidgets('dragging back up through the catalogs scrolls them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);

    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          addonRepositoryProvider.overrideWith(_Repo.new),
          addonClientProvider.overrideWithValue(_Client()),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.createDarkTheme(null),
          home: Scaffold(
            body: AddonCatalogsTabView(scrollController: controller),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final list = find.byType(CustomScrollView);
    // The catalog rows' own list, ahead of the posters' horizontal ones.
    RenderSliverList rows() =>
        tester.renderObject<RenderSliverList>(find.byType(SliverList).first);
    int firstBuiltRow() =>
        (rows().firstChild!.parentData! as SliverMultiBoxAdaptorParentData)
            .index!;

    // Down to the end, so every row has been built and has loaded...
    for (var i = 0; i < 24; i++) {
      await tester.drag(list, const Offset(0, -450));
      await tester.pump(const Duration(milliseconds: 60));
    }
    // Empty catalogs at the end leave while the list sits there, so it
    // settles back onto the shorter end once. That is fine; what follows is
    // not about it.
    await tester.pump(const Duration(seconds: 1));
    final rowAtBottom = firstBuiltRow();

    // ...then back up through the rows that have since been dropped.
    var framesPastEnd = 0;
    for (var i = 0; i < 12; i++) {
      await tester.drag(list, const Offset(0, 300));
      for (var frame = 0; frame < 4; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        if (controller.offset > controller.position.maxScrollExtent + 1) {
          framesPastEnd += 1;
        }
      }
    }

    expect(
      framesPastEnd,
      0,
      reason: 'the offset ran past the end of the content mid-list',
    );
    expect(
      firstBuiltRow(),
      lessThan(rowAtBottom - 3),
      reason: '3600 px of dragging up left the same rows on screen',
    );

    await tester.pumpWidget(const SizedBox());
    // Riverpod disposes what the tree dropped on a timer of its own.
    await tester.pump(const Duration(minutes: 1));
  });
}
