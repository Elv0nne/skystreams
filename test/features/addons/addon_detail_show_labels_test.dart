/// A show that a Stremio add-on publishes as `other` (CNCVerse Bridge's shows)
/// is named and looked up as a show on its page, as its episodes already are:
/// its badge, its details, and the TMDB details it asks for are a series'.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/models/tmdb_details.dart';
import 'package:skystream/features/details/data/tmdb_details_provider.dart';

import 'stremio_page_fakes.dart';

/// [kBridgeShow], with the TMDB id its add-on gave it.
const _show = AddonMeta(
  id: 'cnc:show',
  type: 'other',
  name: 'Money Heist',
  addonId: 'com.bridge',
  addonName: 'Bridge',
  moviedbId: 71446,
  videos: [
    AddonVideo(id: 'cnc:s1e1', title: 'One', season: 1, episode: 1),
    AddonVideo(id: 'cnc:s1e2', title: 'Two', season: 1, episode: 2),
  ],
);

/// TMDB's details, with [director] to tell which were asked for.
TmdbDetails _details(String director) => TmdbDetails(
  id: 71446,
  mediaType: 'tv',
  title: 'Money Heist',
  releaseDate: '2017-05-02',
  voteAverage: 8.2,
  overview: '',
  runtime: 0,
  certification: '',
  director: director,
  seasons: const [],
  tmdbCast: const [],
  genres: const [],
  tmdbTrailers: const [],
  productionCompanies: const [],
  tmdbStatus: '',
  budget: 0,
  revenue: 0,
  tagline: '',
  originCountry: '',
  originalLanguage: '',
  releaseDateFull: '',
);

void main() {
  useTestClearance();

  for (final (layout, size) in [
    ('a large layout', const Size(1920, 1080)),
    ('a phone', const Size(430, 932)),
  ]) {
    testWidgets('on $layout, a show published as `other` is called a series '
        "and gets a series' TMDB details", (tester) async {
      await openStremioPage(
        tester,
        _show,
        size: size,
        overrides: [
          tmdbDetailsProvider(MovieDetailsParams(71446, 'tv'))
              .overrideWith((ref) async => _details('Álex Pina')),
          tmdbDetailsProvider(MovieDetailsParams(71446, 'movie'))
              .overrideWith((ref) async => _details('A film by that number')),
        ],
      );

      expect(find.text('SERIES', skipOffstage: false), findsOneWidget);
      expect(find.text('MOVIE', skipOffstage: false), findsNothing);
      expect(find.text('SHOW DETAILS', skipOffstage: false), findsOneWidget);
      expect(find.text('Álex Pina', skipOffstage: false), findsOneWidget);
      expect(
        find.text('A film by that number', skipOffstage: false),
        findsNothing,
      );
    });
  }
}
