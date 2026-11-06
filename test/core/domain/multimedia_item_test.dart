/// The item model's fields for what extensions provide (CloudStream details,
/// Part 1): each survives the JSON trip history and the library store items
/// on.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';

MultimediaItem _roundTrip(MultimediaItem item) =>
    MultimediaItem.fromJson(item.toJson());

void main() {
  group('show status', () {
    test('is unknown when nothing says', () {
      expect(
        MultimediaItem(title: 'T', url: 'u', posterUrl: '').status,
        ShowStatus.unknown,
      );
      expect(
        MultimediaItem.fromJson({'title': 'T', 'url': 'u', 'posterUrl': ''})
            .status,
        ShowStatus.unknown,
      );
    });

    test('reads what a source says, and keeps unknown through JSON', () {
      MultimediaItem withStatus(String raw) => MultimediaItem.fromJson({
        'title': 'T',
        'url': 'u',
        'posterUrl': '',
        'status': raw,
      });
      expect(withStatus('Completed').status, ShowStatus.completed);
      expect(withStatus('Ongoing').status, ShowStatus.ongoing);
      expect(withStatus('unknown').status, ShowStatus.unknown);
      expect(
        _roundTrip(MultimediaItem(title: 'T', url: 'u', posterUrl: '')).status,
        ShowStatus.unknown,
      );
    });
  });

  test("other sources' words map, and one it doesn't know says nothing", () {
    ShowStatus status(String raw) => MultimediaItem.fromJson({
      'title': 'T',
      'url': 'u',
      'posterUrl': '',
      'status': raw,
    }).status;
    // TMDB, MAL and AniList words, as plugins pass them on.
    for (final raw in ['Ended', 'Finished Airing', 'Canceled', 'CANCELLED']) {
      expect(status(raw), ShowStatus.completed, reason: raw);
    }
    for (final raw in ['Currently Airing', 'Returning Series', 'RELEASING']) {
      expect(status(raw), ShowStatus.ongoing, reason: raw);
    }
    for (final raw in ['Not yet aired', 'NOT_YET_RELEASED', 'Planned']) {
      expect(status(raw), ShowStatus.upcoming, reason: raw);
    }
    for (final raw in ['Hiatus', 'Rumored', '']) {
      expect(status(raw), ShowStatus.unknown, reason: raw);
    }
  });

  test('coming soon and season names survive JSON and copyWith', () {
    final item = MultimediaItem(
      title: 'T',
      url: 'u',
      posterUrl: '',
      comingSoon: true,
      seasonNames: const [
        SeasonName(season: 1, name: 'First Arc'),
        SeasonName(season: 2, name: 'Second Arc', displaySeason: 2),
      ],
    );
    final back = _roundTrip(item);
    expect(back.comingSoon, isTrue);
    expect(back.seasonNames!.map((s) => (s.season, s.name, s.displaySeason)), [
      (1, 'First Arc', null),
      (2, 'Second Arc', 2),
    ]);
    expect(item.copyWith(title: 'U').seasonNames, hasLength(2));
    expect(item.copyWith(title: 'U').comingSoon, isTrue);
  });

  test("a cast member's role kind and a trailer's raw flag survive JSON", () {
    final item = _roundTrip(
      MultimediaItem(
        title: 'T',
        url: 'u',
        posterUrl: '',
        cast: [Actor(name: 'Frieren', role: 'Main', roleIsEnum: true)],
        trailers: [
          Trailer(
            url: 'https://x.test/t.m3u8',
            raw: true,
            referer: 'https://x.test/',
          ),
        ],
      ),
    );
    expect(item.cast!.single.roleIsEnum, isTrue);
    expect(item.trailers!.single.raw, isTrue);
    expect(item.trailers!.single.referer, 'https://x.test/');
  });

  test("an episode's air time survives JSON, in UTC", () {
    final aired = DateTime.utc(2025, 1, 4, 15);
    final episode = Episode.fromJson(
      Episode(name: 'E', url: 'e', airedAt: aired).toJson(),
    );
    expect(episode.airedAt, aired);
    expect(episode.airedAt!.isUtc, isTrue);
  });

  test("a Stremio title's add-on and published type survive JSON and "
      'copyWith', () {
    // What the player asks for the next episode, and what Continue Watching
    // reopens the title with (Stremio direct play).
    final item = MultimediaItem(
      title: 'Money Heist',
      url: 'cnc:show',
      posterUrl: '',
      addonUrl: 'https://addon.test/u/x/manifest.json',
      addonType: 'other',
    );
    final back = _roundTrip(item);
    expect(back.addonUrl, 'https://addon.test/u/x/manifest.json');
    expect(back.addonType, 'other');
    final copy = back.copyWith(title: 'Money Heist (2017)');
    expect(copy.addonUrl, item.addonUrl);
    expect(copy.addonType, 'other');

    // The add-on whose link plays, which the player route carries as JSON.
    final playing = _roundTrip(
      item.copyWith(streamAddonUrl: 'https://torrentio.test/manifest.json'),
    );
    expect(playing.streamAddonUrl, 'https://torrentio.test/manifest.json');
    expect(playing.addonUrl, 'https://addon.test/u/x/manifest.json');

    // History written before them reads as no add-on at all.
    final old = MultimediaItem.fromJson({
      'title': 'T',
      'url': 'u',
      'posterUrl': '',
    });
    expect(old.addonUrl, isNull);
    expect(old.streamAddonUrl, isNull);
    expect(old.addonType, isNull);
  });

  group("a stream's quality", () {
    test('reads the forms plugins write', () {
      expect(parseStreamQuality(1080), 1080);
      expect(parseStreamQuality(720.0), 720);
      expect(parseStreamQuality('1080p'), 1080);
      expect(parseStreamQuality('720'), 720);
      expect(parseStreamQuality(' 480P '), 480);
      expect(parseStreamQuality('4K'), 2160);
      expect(parseStreamQuality('UHD'), 2160);
      expect(parseStreamQuality('2K'), 1440);
      expect(parseStreamQuality('1440p'), 1440);
      expect(parseStreamQuality('Auto'), 0);
      expect(parseStreamQuality(0), 0);
    });

    test("an extractor's Unknown is no quality, and nonsense is ignored", () {
      // Qualities.Unknown in skystream-extractors and CloudStream: plugins
      // pass extractor links on as they are.
      expect(parseStreamQuality(400), isNull);
      expect(parseStreamQuality(null), isNull);
      expect(parseStreamQuality('HD'), isNull);
      expect(parseStreamQuality('Server 2'), isNull);
      expect(parseStreamQuality(-1), isNull);
      expect(parseStreamQuality(99999), isNull);
      expect(parseStreamQuality(double.nan), isNull);
      expect(parseStreamQuality(true), isNull);
    });

    test('survives JSON and copyWith, so it reaches the player', () {
      const stream = StreamResult(
        url: 'https://cdn.test/master.m3u8',
        source: 'A',
        quality: 0,
      );
      expect(StreamResult.fromJson(stream.toJson()).quality, 0);
      expect(
        StreamResult.fromJson({'url': 'u', 'source': 's', 'quality': '720p'})
            .quality,
        720,
      );
      expect(
        StreamResult.fromJson({'url': 'u', 'source': 's'}).quality,
        isNull,
      );
      expect(stream.copyWith(source: 'B').quality, 0);
    });
  });
}
