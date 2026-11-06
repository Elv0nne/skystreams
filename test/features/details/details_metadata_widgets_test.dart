/// What the details page shows of an extension's metadata (CloudStream
/// details, Part 1): the status chip, tags, Coming soon, the next airing's
/// gate, the cast and the season chips.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/details/presentation/details_controller.dart';
import 'package:skystream/features/details/presentation/widgets/details_layout_widgets.dart';
import 'package:skystream/features/details/presentation/widgets/premium_details_widgets.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

MultimediaItem _show({
  MultimediaContentType type = MultimediaContentType.anime,
  ShowStatus status = ShowStatus.unknown,
  NextAiring? nextAiring,
}) => MultimediaItem(
  title: 'T',
  url: 'u',
  posterUrl: '',
  contentType: type,
  status: status,
  nextAiring: nextAiring,
);

void main() {
  group('the status chip', () {
    testWidgets('says a show is ongoing or completed', (tester) async {
      await _pump(tester, MetadataBar(item: _show(status: ShowStatus.ongoing)));
      expect(find.text('Ongoing'), findsOneWidget);

      await _pump(
        tester,
        MetadataBar(item: _show(status: ShowStatus.completed)),
      );
      expect(find.text('Completed'), findsOneWidget);
    });

    testWidgets('is absent when the source said nothing, on a film, and while '
        'loading', (tester) async {
      await _pump(tester, MetadataBar(item: _show()));
      expect(find.text('Ongoing'), findsNothing);

      await _pump(
        tester,
        MetadataBar(
          item: _show(
            type: MultimediaContentType.movie,
            status: ShowStatus.ongoing,
          ),
        ),
      );
      expect(find.text('Ongoing'), findsNothing);

      // A history item saved before `unknown` existed says `ongoing`; the
      // chip waits for the loaded details.
      await _pump(
        tester,
        MetadataBar(item: _show(status: ShowStatus.ongoing), isLoading: true),
      );
      expect(find.text('Ongoing'), findsNothing);
    });
  });

  testWidgets('tags show, ten at most', (tester) async {
    await _pump(tester, TagsRow(tags: [for (var i = 0; i < 12; i++) 'Tag $i']));
    expect(find.textContaining('Tag '), findsNWidgets(TagsRow.maxTags));
    expect(find.text('Tag 10'), findsNothing);
  });

  testWidgets('Coming soon says so', (tester) async {
    await _pump(tester, const ComingSoonLabel());
    expect(find.text('Coming soon'), findsOneWidget);
  });

  test('nextAiringAhead: only a next episode still to come', () {
    final now = DateTime.utc(2026, 10, 11);
    final seconds = now.millisecondsSinceEpoch ~/ 1000;
    expect(nextAiringAhead(_show(), now: now), isFalse);
    expect(
      nextAiringAhead(
        _show(nextAiring: NextAiring(episode: 2, unixTime: seconds - 60)),
        now: now,
      ),
      isFalse,
    );
    expect(
      nextAiringAhead(
        _show(nextAiring: NextAiring(episode: 2, unixTime: seconds + 60)),
        now: now,
      ),
      isTrue,
    );
    // Beyond any calendar (nanoseconds): not a time that is still to come.
    expect(
      nextAiringAhead(
        _show(
          nextAiring: NextAiring(episode: 2, unixTime: 1736002800000000000),
        ),
        now: now,
      ),
      isFalse,
    );
  });

  group('the cast', () {
    final withPhotos = [
      Actor(
        name: 'Frieren',
        image: 'https://img.test/f.png',
        role: 'Main',
        roleIsEnum: true,
        voiceActor: Actor(name: 'Atsumi Tanezaki'),
      ),
      Actor(name: 'Himmel', image: 'https://img.test/h.png', role: 'Hero'),
    ];

    testWidgets('names voice actors, and translates the role names only', (
      tester,
    ) async {
      await _pump(
        tester,
        CastCarousel(cast: withPhotos),
        locale: const Locale('de'),
      );
      expect(find.text('Atsumi Tanezaki'), findsOneWidget);
      expect(find.text('Hauptrolle'), findsOneWidget);
      expect(find.text('Hero'), findsOneWidget);
    });

    testWidgets('is one line when the first has no photo, as CloudStream', (
      tester,
    ) async {
      await _pump(
        tester,
        CastCarousel(
          cast: [
            Actor(name: 'Himmel'),
            Actor(name: 'Heiter', image: 'https://img.test/he.png'),
          ],
        ),
      );
      expect(find.text('Cast: Himmel, Heiter'), findsOneWidget);
      expect(find.byType(CircleAvatar), findsNothing);
    });
  });

  group('season chips', () {
    const names = [
      SeasonName(season: 1, name: 'First Arc'),
      SeasonName(season: 2, name: 'Second Arc', displaySeason: 2),
    ];

    test("use the extension's names", () async {
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      expect(seasonChipLabel(l10n, 1, names), 'First Arc');
      expect(seasonChipLabel(l10n, 2, names), 'Season 2: Second Arc');
      expect(seasonChipLabel(l10n, 3, names), 'Season 3');
      expect(seasonChipLabel(l10n, 1, null), 'Season 1');
    });

    testWidgets('show them on the page', (tester) async {
      final episodes = [
        Episode(name: 'A', url: 'a', season: 1, episode: 1),
        Episode(name: 'B', url: 'b', season: 2, episode: 1),
      ];
      final item = MultimediaItem(
        title: 'T',
        url: 'u',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
        seasonNames: names,
        episodes: episodes,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            detailsControllerProvider('u').overrideWithValue(
              DetailsState(
                details: AsyncValue.data(item),
                item: item,
                seasonMap: {
                  1: [episodes.first],
                  2: [episodes.last],
                },
              ),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: DetailsSeasonListWrapper(itemUrl: 'u')),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('First Arc'), findsOneWidget);
      expect(find.text('Season 2: Second Arc'), findsOneWidget);
    });
  });
}
