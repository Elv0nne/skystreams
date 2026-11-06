/// The details screen shows what an extension sent (CloudStream details,
/// Part 1): artwork with the extension's headers, tags, the next episode only
/// while it is ahead, and Coming soon instead of Play. On a phone, and on the
/// large layout desktops, tablets and televisions take.
library;

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/storage/episode_watch_repository.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/details/presentation/details_controller.dart';
import 'package:skystream/features/details/presentation/details_screen.dart';
import 'package:skystream/features/details/presentation/downloaded_file_provider.dart';
import 'package:skystream/features/details/presentation/widgets/details_layout_widgets.dart';
import 'package:skystream/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:skystream/features/library/presentation/library_provider.dart';
import 'package:skystream/features/library/presentation/library_state.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const String _kUrl = 'https://ext.test/title';
const String _kExtension = 'cs3:repo/Ext/Ext';
const Map<String, String> _kHeaders = {'Referer': 'https://ext.test/'};

class _NoHistory extends HistoryRepository {
  _NoHistory() : super(StorageService());

  @override
  List<HistoryItem> getWatchHistory() => const <HistoryItem>[];
  @override
  int getPosition(String url) => 0;
  @override
  int getDuration(String url) => 0;
  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => 0;
}

class _NoEpisodeWatch extends EpisodeWatchRepository {
  _NoEpisodeWatch(HistoryRepository history)
    : super(StorageService(), history, _ignore);

  static void _ignore() {}

  @override
  bool? getExplicitState(String mainUrl, Episode episode) => null;
  @override
  bool isWatched(String mainUrl, Episode episode) => false;
}

class _FakeDownloadedFiles extends DownloadedFiles {
  @override
  Map<String, File?> build() => const <String, File?>{};
  @override
  Future<void> checkFile(MultimediaItem item, {Episode? episode}) async {}
}

class _FakeLibrary extends Library {
  @override
  LibraryState build() => const LibraryEmpty();
}

class _FakeController extends DetailsController {
  _FakeController(this._item);

  final MultimediaItem _item;

  @override
  DetailsState build(String itemUrl) => DetailsState(
    details: AsyncValue.data(_item),
    isMovie: true,
    item: _item,
    seasonMap: {1: _item.episodes ?? const []},
  );

  @override
  Future<void> loadDetails(
    MultimediaItem item, {
    bool autoPlay = false,
    bool forceRefresh = false,
  }) async {}
}

MultimediaItem _film({
  bool comingSoon = false,
  int nextInSeconds = 3600,
  String provider = _kExtension,
}) => MultimediaItem(
  title: 'A Title',
  url: _kUrl,
  posterUrl: 'https://img.test/poster.png',
  bannerUrl: 'https://img.test/back.png',
  logoUrl: 'https://img.test/logo.png',
  provider: provider,
  headers: _kHeaders,
  contentType: MultimediaContentType.movie,
  tags: const ['Adventure', 'Fantasy'],
  comingSoon: comingSoon,
  nextAiring: NextAiring(
    episode: 2,
    unixTime: DateTime.now().millisecondsSinceEpoch ~/ 1000 + nextInSeconds,
  ),
  episodes: comingSoon
      ? null
      : [Episode(name: 'A Title', url: 'cs3data:eA==', season: 1, episode: 1)],
);

Future<void> _pump(WidgetTester tester, MultimediaItem item, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  // The test font draws every glyph a full em wide: "Download" overflows the
  // large layout's 400-dp button pair by under a pixel, where real fonts are
  // far narrower. Slightly smaller text keeps these tests about what they say.
  tester.platformDispatcher.textScaleFactorTestValue = 0.9;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final history = _NoHistory();
  final container = ProviderContainer(
    overrides: [
      historyRepositoryProvider.overrideWithValue(history),
      episodeWatchRepositoryProvider.overrideWithValue(
        _NoEpisodeWatch(history),
      ),
      downloadedFilesProvider.overrideWith(_FakeDownloadedFiles.new),
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile()),
      ),
      detailsControllerProvider.overrideWith2((_) => _FakeController(item)),
      libraryProvider.overrideWith(_FakeLibrary.new),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DetailsScreen(item: item),
      ),
    ),
  );
  // Never settle: the artwork placeholders never resolve under test.
  await tester.pump();
}

Iterable<CachedNetworkImage> _artwork(WidgetTester tester) => tester
    .widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))
    .where((i) => i.imageUrl.startsWith('https://img.test/'));

void main() {
  for (final (name, size) in [
    ('a phone', const Size(590, 1200)),
    ('the large layout', const Size(1600, 1000)),
  ]) {
    group('on $name', () {
      testWidgets("artwork carries the extension's headers, and tags show", (
        tester,
      ) async {
        await _pump(tester, _film(), size);
        expect(_artwork(tester), isNotEmpty);
        for (final image in _artwork(tester)) {
          expect(image.httpHeaders, _kHeaders, reason: image.imageUrl);
        }
        expect(find.byType(TagsRow, skipOffstage: false), findsOneWidget);
        expect(
          find.byType(NextAiringWidget, skipOffstage: false),
          findsOneWidget,
        );
      });

      testWidgets("a plugin's own headers stay off the artwork", (
        tester,
      ) async {
        // A JavaScript plugin's `headers` aren't defined for images (some
        // carry API headers), and other hosts' art would get them.
        await _pump(tester, _film(provider: 'some.plugin'), size);
        expect(_artwork(tester), isNotEmpty);
        for (final image in _artwork(tester)) {
          expect(image.httpHeaders, isNull, reason: image.imageUrl);
        }
      });

      testWidgets('a next airing that has passed is not shown', (tester) async {
        await _pump(tester, _film(nextInSeconds: -3600), size);
        expect(
          find.byType(NextAiringWidget, skipOffstage: false),
          findsNothing,
        );
      });

      testWidgets('a title not out yet says Coming soon instead of Play', (
        tester,
      ) async {
        await _pump(tester, _film(comingSoon: true), size);
        expect(
          find.byType(ComingSoonLabel, skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.byType(DetailsActionButtons, skipOffstage: false),
          findsNothing,
        );
      });
    });
  }

  // Lower on the page than a test window reaches, so on its own: each
  // recommendation brings its own headers, from its search result.
  testWidgets("a recommendation's poster carries its own headers", (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: RecommendationsCarousel(
              items: [
                MultimediaItem(
                  title: 'More',
                  url: 'https://ext.test/more',
                  posterUrl: 'https://img.test/more.png',
                  provider: _kExtension,
                  headers: _kHeaders,
                ),
              ],
              onItemTap: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_artwork(tester).single.httpHeaders, _kHeaders);
  });
}
