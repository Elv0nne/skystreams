/// Stremio add-ons as sources of the player's subtitle search: each add-on
/// that answers subtitles, and OpenSubtitles' keyless one, beside the three
/// providers.
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_subtitle_service.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';
import 'package:skystream/features/player/data/addon_subtitles_provider.dart';
import 'package:skystream/features/player/presentation/subtitle_search_provider.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

/// Answers every add-on with [tracks] and notes what it was asked.
class _Service extends AddonSubtitleService {
  _Service([this.tracks = const []]) : super(AddonClient(Dio()));

  final List<AddonSubtitleTrack> tracks;
  final asked = <({String type, String id})>[];

  @override
  Future<List<AddonSubtitleTrack>> ask(
    ManagedAddon addon, {
    required String type,
    required String id,
    CancelToken? cancelToken,
  }) async {
    asked.add((type: type, id: id));
    return tracks;
  }
}

ManagedAddon _addon(
  String name, {
  List<String> resources = const ['subtitles'],
}) => ManagedAddon(
  manifestUrl: 'https://${name.toLowerCase()}.example/manifest.json',
  addedAt: DateTime(2026),
  manifest: AddonManifest(
    id: 'org.example.${name.toLowerCase()}',
    name: name,
    version: '1.0.0',
    types: const ['movie', 'series'],
    idPrefixes: const ['tt'],
    resources: [for (final r in resources) AddonResource(name: r)],
  ),
);

AddonSubtitleTrack _track(String id, String lang, {String? release}) =>
    AddonSubtitleTrack(
      id: id,
      url: 'https://subs.example/$id.srt',
      lang: lang,
      release: release,
    );

void main() {
  group('an add-on as a subtitle source', () {
    test('is asked for a film by its tt id', () async {
      final service = _Service();
      await AddonSubtitlesProvider(
        service,
        _addon('Subs'),
      ).search(query: 'The Matrix', imdbId: '0133093', language: 'en');
      expect(service.asked, [(type: 'movie', id: 'tt0133093')]);
    });

    test('and for an episode by its season and episode', () async {
      final service = _Service();
      await AddonSubtitlesProvider(service, _addon('Subs')).search(
        query: 'Breaking Bad',
        imdbId: 'tt0903747',
        season: 2,
        episode: 5,
        language: 'en',
      );
      expect(service.asked, [(type: 'series', id: 'tt0903747:2:5')]);
    });

    // Stremio names an episode and nothing broader: a title alone, or a
    // season without its episode, is no request an add-on can answer.
    test('is not asked without an IMDb id, or for a whole season', () async {
      final service = _Service([_track('1', 'eng')]);
      final provider = AddonSubtitlesProvider(service, _addon('Subs'));
      expect(await provider.search(query: 'The Matrix', tmdbId: 603), isEmpty);
      expect(
        await provider.search(
          query: 'Breaking Bad',
          imdbId: 'tt0903747',
          season: 2,
        ),
        isEmpty,
      );
      expect(service.asked, isEmpty);
    });

    // An add-on answers in every language it has, coded its own way.
    test(
      'keeps the language asked for, whatever code the add-on gives it',
      () async {
        final service = _Service([
          _track('1', 'eng'),
          _track('2', 'ger'),
          _track('3', 'pob'),
          _track('4', 'por'),
          _track('5', 'zht'),
          _track('6', 'zho'),
          _track('7', 'tgl'),
        ]);
        final provider = AddonSubtitlesProvider(service, _addon('Subs'));
        Future<List<String>> ids(String language) async => [
          for (final s in await provider.search(
            query: 'x',
            imdbId: 'tt1',
            language: language,
          ))
            s.id.split('#').last,
        ];
        expect(await ids('en'), ['1']);
        expect(await ids('pt'), ['3', '4']);
        expect(await ids('zh'), ['5', '6']);
        expect(await ids('fil'), ['7']);
      },
    );

    test('names a result by its release, under the add-on\'s name', () async {
      final service = _Service([
        _track('1', 'eng', release: 'Breaking.Bad.S02E05.720p.BluRay.x264-EbP'),
        _track('2', 'eng'),
      ]);
      final provider = AddonSubtitlesProvider(service, _addon('Subs'));
      final results = await provider.search(
        query: 'Breaking Bad',
        imdbId: 'tt0903747',
        season: 2,
        episode: 5,
        language: 'en',
      );

      expect(results.map((s) => s.name), [
        'Breaking.Bad.S02E05.720p.BluRay.x264-EbP',
        'English',
      ]);
      expect(results.first.source, 'Subs');
      expect(results.first.language, 'en');
      expect(results.first.downloadUrl, 'https://subs.example/1.srt');
      expect(
        await provider.getDownloadUrl(results.first),
        results.first.downloadUrl,
      );
      // Unique beside another add-on's subtitle of the same id.
      expect(
        results.first.id,
        isNot(
          (await AddonSubtitlesProvider(
            service,
            _addon('Other'),
          ).search(query: 'x', imdbId: 'tt1', language: 'en')).first.id,
        ),
      );
    });
  });

  // Downloads are routed by a result's source, so every source's name is its
  // own.
  group('the sources a subtitle search asks', () {
    test(
      'are the three providers, then the add-ons, OpenSubtitles v3 last',
      () {
        final sources = subtitleSources(
          dio: Dio(),
          settings: const PlayerSettings(),
          addons: AddonSubtitleService(AddonClient(Dio())),
          installed: [
            _addon('Subs'),
            _addon('Catalog', resources: const ['catalog']),
          ],
        );
        expect(sources.map((s) => s.name), [
          'OpenSubtitles',
          'SubDL',
          'SubSource',
          'Subs',
          'OpenSubtitles v3',
        ]);
      },
    );

    test('give an add-on named as a provider a name of its own', () {
      final sources = subtitleSources(
        dio: Dio(),
        settings: const PlayerSettings(),
        addons: AddonSubtitleService(AddonClient(Dio())),
        installed: [_addon('SubDL')],
      );
      expect(sources.map((s) => s.name), [
        'OpenSubtitles',
        'SubDL',
        'SubSource',
        'SubDL · Stremio',
        'OpenSubtitles v3',
      ]);
    });
  });
}
