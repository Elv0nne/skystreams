/// An episode card's line under its title (CloudStream details, Part 1): the
/// rating, runtime and air date, as CloudStream shows them; and an episode not
/// out yet says when it airs and doesn't play.
library;

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/episode_watch_repository.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/details/presentation/details_controller.dart';
import 'package:skystream/features/details/presentation/downloaded_file_provider.dart';
import 'package:skystream/features/details/presentation/widgets/episode_card.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

// The fakes are episode_card_test.dart's: Hive, path_provider and the player
// stay out of a widget test.
class _NoHistory extends HistoryRepository {
  _NoHistory() : super(StorageService());

  @override
  List<HistoryItem> getWatchHistory() => const <HistoryItem>[];
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

class _RecordingController extends DetailsController {
  _RecordingController(this._state);

  final DetailsState _state;
  static final List<String> played = <String>[];

  @override
  DetailsState build(String itemUrl) => _state;

  @override
  Future<void> handlePlayPress(
    BuildContext context,
    MultimediaItem details, {
    Episode? specificEpisode,
    String? overrideUrl,
  }) async {
    played.add(specificEpisode!.url);
  }
}

String _date(DateTime d) =>
    const DefaultMaterialLocalizations().formatShortDate(d.toLocal());

void main() {
  late AppLocalizations l10n;
  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  group('the line under an episode', () {
    final now = DateTime.utc(2026, 10, 11);

    test('rating, runtime and air date', () {
      final aired = DateTime.utc(2025, 1, 4, 15);
      expect(
        episodeMetaLine(
          l10n,
          Episode(
            name: 'E',
            url: 'e',
            rating: 8.2,
            runtime: 24,
            airedAt: aired,
          ),
          formatDate: _date,
          now: now,
        ),
        '★ 8.2 · 24 min · ${_date(aired)}',
      );
    });

    test("a plugin's text air date, and nothing at all", () {
      expect(
        episodeMetaLine(
          l10n,
          Episode(name: 'E', url: 'e', airDate: '2024-05-01'),
          formatDate: _date,
          now: now,
        ),
        _date(DateTime.parse('2024-05-01')),
      );
      expect(
        episodeMetaLine(
          l10n,
          Episode(name: 'E', url: 'e'),
          formatDate: _date,
          now: now,
        ),
        isNull,
      );
    });

    test('an episode not out yet says when it airs', () {
      final airs = DateTime.utc(2026, 10, 13);
      expect(
        episodeMetaLine(
          l10n,
          Episode(name: 'E', url: 'e', runtime: 24, airedAt: airs),
          formatDate: _date,
          now: now,
        ),
        'Airs ${_date(airs)}',
      );
    });
  });

  final aired = Episode(
    name: 'Out',
    url: 'https://x.test/e1',
    season: 1,
    episode: 1,
    posterUrl: 'https://img.test/e1.png',
    airedAt: DateTime.utc(2025, 1, 4),
  );
  Episode upcoming() => Episode(
    name: 'Next Week',
    url: 'https://x.test/e2',
    season: 1,
    episode: 2,
    airedAt: DateTime.now().toUtc().add(const Duration(days: 2)),
  );

  testWidgets(
    'an episode not out yet says when it airs, and still plays, as in '
    'CloudStream',
    (tester) async {
      await _pumpCards(tester, [aired, upcoming()]);

      expect(find.textContaining('Airs '), findsOneWidget);
      // CloudStream swaps an upcoming episode's play icon and nothing else:
      // a tap plays it, as the date can be the broadcast's while the site
      // already has the episode.
      expect(find.byIcon(Icons.schedule_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      await tester.tap(find.text('2. NEXT WEEK'));
      await tester.pump();
      await tester.tap(find.text('1. OUT'));
      await tester.pump();
      expect(_RecordingController.played, [
        'https://x.test/e2',
        'https://x.test/e1',
      ]);
    },
  );

  testWidgets('on a phone, the line under the title keeps its date', (
    tester,
  ) async {
    // Beside a phone's thumbnail one line held "★ 6.9 · 24 min · Jan 4," and
    // cut the year (Anichi's episodes on the Android emulator). 430 dp, a
    // large phone: the test font draws every glyph a full em wide, about
    // twice the app's, so the app's font fits narrower phones too.
    final rated = Episode(
      name: 'Out',
      url: 'https://x.test/e1',
      season: 1,
      episode: 1,
      rating: 6.9,
      runtime: 24,
      airedAt: DateTime.utc(2025, 1, 4, 15),
    );
    await _pumpCards(tester, [rated], size: const Size(430, 932));
    final line = tester.renderObject<RenderParagraph>(
      find.textContaining('24 min'),
    );
    expect(line.didExceedMaxLines, isFalse);
  });

  testWidgets("a thumbnail carries a CloudStream title's headers", (
    tester,
  ) async {
    await _pumpCards(
      tester,
      [aired],
      headers: {'Referer': 'https://x.test/'},
      provider: 'cs3:repo/Ext/Ext',
    );
    final thumbnail = tester.widget<CachedNetworkImage>(
      find.byWidgetPredicate(
        (w) =>
            w is CachedNetworkImage && w.imageUrl == 'https://img.test/e1.png',
      ),
    );
    expect(thumbnail.httpHeaders, {'Referer': 'https://x.test/'});
  });

  testWidgets("a plugin's headers stay off a thumbnail", (tester) async {
    await _pumpCards(
      tester,
      [aired],
      headers: {'Referer': 'https://x.test/'},
      provider: 'some.plugin',
    );
    final thumbnail = tester.widget<CachedNetworkImage>(
      find.byWidgetPredicate(
        (w) =>
            w is CachedNetworkImage && w.imageUrl == 'https://img.test/e1.png',
      ),
    );
    expect(thumbnail.httpHeaders, isNull);
  });
}

/// The cards as the details screen lays them out (episode_card_test.dart's
/// harness): each in a row of its own, as tall as its content.
Future<void> _pumpCards(
  WidgetTester tester,
  List<Episode> episodes, {
  Map<String, String>? headers,
  String? provider,
  Size size = const Size(960, 540),
}) async {
  _RecordingController.played.clear();
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = size * 2.0;
  addTearDown(tester.view.reset);
  final item = MultimediaItem(
    title: 'S',
    url: 'https://x.test/s',
    posterUrl: '',
    provider: provider,
    headers: headers,
    contentType: MultimediaContentType.series,
    episodes: episodes,
  );
  final history = _NoHistory();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        historyRepositoryProvider.overrideWithValue(history),
        episodeWatchRepositoryProvider.overrideWithValue(
          _NoEpisodeWatch(history),
        ),
        downloadedFilesProvider.overrideWith(_FakeDownloadedFiles.new),
        detailsControllerProvider.overrideWith2(
          (_) => _RecordingController(
            DetailsState(details: AsyncValue.data(item), item: item),
          ),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final episode in episodes)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: EpisodeCard(episode: episode, parentItem: item),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
