import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/builtin_addons.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/services/tmdb_service.dart';
import 'package:skystream/features/search/presentation/search_sources.dart';

/// An add-on client whose catalogs answer from [answers], by `type/id`; a
/// catalog with no answer fails.
class _Client implements AddonClient {
  _Client(this.answers);

  final Map<String, Future<List<AddonMetaPreview>> Function()> answers;
  final calls = <String>[];

  @override
  Future<List<AddonMetaPreview>> catalog(
    ManagedAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) {
    calls.add('$type/$id $extra');
    final answer = answers['$type/$id'];
    return answer == null ? Future.error(Exception('down')) : answer();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tmdb implements TmdbService {
  _Tmdb(this.items);

  final List<MultimediaItem> items;

  @override
  Future<List<MultimediaItem>> multiSearch({
    required String query,
    String language = 'en-US',
    int page = 1,
  }) async => items;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _search = AddonExtraProperty(name: 'search');

AddonCatalog _catalog(
  String type,
  String id, {
  List<AddonExtraProperty> extra = const [_search],
}) => AddonCatalog(type: type, id: id, name: id, extra: extra);

ManagedAddon _addon(
  String name, {
  List<AddonCatalog> catalogs = const [],
  List<String> resources = const ['catalog'],
}) => ManagedAddon(
  manifestUrl: 'https://$name.test/manifest.json',
  addedAt: DateTime(2026),
  manifest: AddonManifest(
    id: name,
    name: name,
    version: '1.0.0',
    resources: [for (final r in resources) AddonResource(name: r)],
    types: const ['movie', 'series'],
    catalogs: catalogs,
  ),
);

AddonMetaPreview _preview(String id, String type, String name) =>
    AddonMetaPreview(id: id, type: type, name: name, poster: 'p/$id.jpg');

MultimediaItem _tmdb(String title, MultimediaContentType type, int? id) =>
    MultimediaItem(
      title: title,
      url: '',
      posterUrl: '',
      contentType: type,
      tmdbId: id,
    );

void main() {
  group('a Stremio add-on\'s searcher', () {
    test('asks each catalog that can search, and only those', () async {
      final client = _Client({
        'movie/top': () async => const [],
        'series/top': () async => const [],
      });
      await StremioSearcher(
        _addon(
          'a',
          catalogs: [
            _catalog('movie', 'top'),
            _catalog('series', 'top'),
            _catalog('movie', 'popular', extra: const []),
            _catalog(
              'movie',
              'genre',
              extra: const [
                _search,
                AddonExtraProperty(name: 'genre', isRequired: true),
              ],
            ),
          ],
        ),
        client,
      ).search(' matrix ');
      expect(client.calls, [
        'movie/top {search: matrix}',
        'series/top {search: matrix}',
      ]);
    });

    test(
      'answers its catalogs\' results once each, closest to the query first',
      () async {
        final client = _Client({
          'movie/top': () async => [
            _preview('tt1', 'movie', 'The Matrix Revolutions'),
            _preview('tt2', 'movie', 'Matrix'),
          ],
          'series/top': () async => [_preview('tt2', 'movie', 'Matrix')],
        });
        final items = await StremioSearcher(
          _addon(
            'a',
            catalogs: [_catalog('movie', 'top'), _catalog('series', 'top')],
          ),
          client,
        ).search('matrix');
        expect(items.map((i) => i.title), ['Matrix', 'The Matrix Revolutions']);
      },
    );

    test('keeps each result\'s id, poster and kind', () async {
      final items = await StremioSearcher(
        _addon('a', catalogs: [_catalog('series', 'top')]),
        _Client({
          'series/top': () async => [_preview('tt9', 'series', 'Matrix Show')],
        }),
      ).search('matrix');
      expect(items.single.url, 'tt9');
      expect(items.single.posterUrl, 'p/tt9.jpg');
      expect(items.single.contentType, MultimediaContentType.series);
    });

    test(
      'a catalog that fails is left out; when all fail, the search fails',
      () async {
        final addon = _addon(
          'a',
          catalogs: [_catalog('movie', 'top'), _catalog('series', 'top')],
        );
        final some = await StremioSearcher(
          addon,
          _Client({
            'movie/top': () async => [_preview('tt1', 'movie', 'Matrix')],
          }),
        ).search('matrix');
        expect(some.map((i) => i.title), ['Matrix']);
        expect(
          StremioSearcher(addon, _Client({})).search('matrix'),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('is named and filed as its add-on, a Stremio section', () {
      final searcher = StremioSearcher(
        _addon('Torrentio', catalogs: [_catalog('movie', 'top')]),
        _Client({}),
      );
      expect(searcher.name, 'Torrentio');
      expect(searcher.kind, SearchSourceKind.stremio);
      expect(searcher.checkSource, 'addon:Torrentio');
      expect(
        searcher.packageName,
        'stremio:https://Torrentio.test/manifest.json',
      );
    });
  });

  group('Nuvio\'s searcher', () {
    test('answers the films and series TMDB knows by id', () async {
      final items = await NuvioSearcher(
        _Tmdb([
          _tmdb('The Matrix', MultimediaContentType.movie, 603),
          _tmdb('The Matrix Show', MultimediaContentType.series, 9),
          _tmdb('No id', MultimediaContentType.movie, null),
          _tmdb('Something else', MultimediaContentType.other, 7),
        ]),
      ).search('matrix');
      expect(items.map((i) => i.title), ['The Matrix', 'The Matrix Show']);
    });

    test('is one Nuvio section, meeting no bot check of its own', () {
      final searcher = NuvioSearcher(_Tmdb(const []));
      expect(searcher.name, 'Nuvio');
      expect(searcher.kind, SearchSourceKind.nuvio);
      expect(searcher.checkSource, isNull);
    });
  });

  group('the searchers a search adds', () {
    final searching = _addon('a', catalogs: [_catalog('movie', 'top')]);
    final streams = _addon('t', resources: const ['stream']);

    List<String> names({
      required List<ManagedAddon> addons,
      bool nuvioActive = false,
    }) => [
      for (final s in searchSources(
        addons: addons,
        client: _Client({}),
        nuvioActive: nuvioActive,
        tmdb: _Tmdb(const []),
      ))
        s.name,
    ];

    test('one per add-on that can search, and Nuvio while it has scrapers', () {
      expect(names(addons: [searching, streams], nuvioActive: true), [
        'a',
        'Nuvio',
      ]);
    });

    test('Cinemeta, only for stream add-ons with none that can search', () {
      expect(names(addons: [streams]), [BuiltInAddons.cinemeta.displayName]);
      expect(names(addons: [searching, streams]), ['a']);
      expect(names(addons: const []), isEmpty);
    });
  });
}
