import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/core/services/tmdb_service.dart';
import 'package:skystream/features/explore/data/explore_tmdb_provider.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/search_sources.dart';

/// An extension answering [answer] after [after].
class _Plugin extends SkyStreamProvider {
  _Plugin(this.packageName, this.answer, {this.live = false});

  @override
  final String packageName;
  final Future<List<MultimediaItem>> Function() answer;
  final bool live;

  @override
  String get name => packageName;
  @override
  String get mainUrl => 'https://$packageName.example';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes =>
      live ? const {ProviderType.livestream} : const {ProviderType.movie};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => answer();

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

class _Manager extends ExtensionManager {
  _Manager(this.plugins);

  final List<SkyStreamProvider> plugins;

  @override
  List<SkyStreamProvider> build() => plugins;
}

/// One add-on, `S`, with one catalog that takes a search.
final _addon = ManagedAddon(
  manifestUrl: 'https://s.test/manifest.json',
  addedAt: DateTime(2026),
  manifest: const AddonManifest(
    id: 'S',
    name: 'S',
    version: '1.0.0',
    resources: [AddonResource(name: 'catalog')],
    types: ['movie'],
    catalogs: [
      AddonCatalog(
        type: 'movie',
        id: 'top',
        name: 'Top',
        extra: [AddonExtraProperty(name: 'search')],
      ),
    ],
  ),
);

class _AddonRepo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(addons: [_addon], isLoading: false);
}

class _NuvioRepo extends NuvioRepository {
  @override
  NuvioState build() => NuvioState(
    isLoading: false,
    repos: [
      NuvioRepo(
        manifestUrl: 'https://nuvio.test/manifest.json',
        addedAt: DateTime(2026),
        manifest: const NuvioManifest(
          name: 'Repo',
          version: '1.0.0',
          scrapers: [
            NuvioScraperInfo(
              id: 'a',
              name: 'A',
              version: '1.0.0',
              filename: 'a.js',
            ),
          ],
        ),
      ),
    ],
  );
}

/// The add-on's search answers, in turn; the last repeats.
class _Client implements AddonClient {
  _Client(this.answers);

  final List<Future<List<AddonMetaPreview>> Function()> answers;
  final tokens = <CancelToken?>[];

  @override
  Future<List<AddonMetaPreview>> catalog(
    ManagedAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) {
    tokens.add(cancelToken);
    return answers[(tokens.length - 1).clamp(0, answers.length - 1)]();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tmdb implements TmdbService {
  _Tmdb(this.answer);

  final Future<List<MultimediaItem>> Function() answer;
  var searches = 0;

  @override
  Future<List<MultimediaItem>> multiSearch({
    required String query,
    String language = 'en-US',
    int page = 1,
  }) {
    searches++;
    return answer();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<T> _after<T>(int ms, T value) =>
    Future.delayed(Duration(milliseconds: ms), () => value);

MultimediaItem _film(String title) =>
    MultimediaItem(title: title, url: 'u/$title', posterUrl: '');

const _matrix = AddonMetaPreview(
  id: 'tt0133093',
  type: 'movie',
  name: 'The Matrix',
);

final _tmdbMatrix = MultimediaItem(
  title: 'The Matrix',
  url: '',
  posterUrl: '',
  contentType: MultimediaContentType.movie,
  tmdbId: 603,
);

/// The search bar with Stremio add-ons' and Nuvio's sections.
void main() {
  late SiteChecks checks;

  setUp(() {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    checks = SiteChecks();
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: checks,
      solver: ClearanceSolver(store: store, siteKeys: keys, checks: checks),
    );
  });

  /// A search for [query] over [plugins], the add-on `S` answering [client]
  /// and Nuvio [tmdb]; the states it emits.
  Future<(ProviderContainer, List<SearchAggregateState>)> search(
    List<SkyStreamProvider> plugins, {
    required _Client client,
    required _Tmdb tmdb,
    String query = 'matrix',
    SearchFilter filter = SearchFilter.content,
    bool waitForEnd = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(() => _Manager(plugins)),
        addonRepositoryProvider.overrideWith(_AddonRepo.new),
        addonClientProvider.overrideWithValue(client),
        nuvioRepositoryProvider.overrideWith(_NuvioRepo.new),
        tmdbServiceProvider.overrideWithValue(tmdb),
      ],
    );
    addTearDown(container.dispose);
    final states = <SearchAggregateState>[];
    container.listen(searchResultsProvider, (_, next) {
      if (next.hasValue) states.add(next.value!);
    }, fireImmediately: true);
    container.read(searchFilterProvider.notifier).set(filter);
    container.read(searchQueryProvider.notifier).set(query);
    if (waitForEnd) {
      await until(() => states.isNotEmpty && !states.last.isLoading);
    }
    return (container, states);
  }

  test('add-ons and Nuvio search with the extensions, as sections in the order they answer', () async {
    final (_, states) = await search(
      [
        _Plugin('ext', () => _after(90, [_film('Matrix Ext')])),
      ],
      client: _Client([
        () async => [_matrix],
      ]),
      tmdb: _Tmdb(() => _after(40, [_tmdbMatrix])),
    );
    final results = states.last.results;
    expect(results.map((r) => r.providerName), ['S', 'Nuvio', 'ext']);
    expect(results.map((r) => r.kind), [
      SearchSourceKind.stremio,
      SearchSourceKind.nuvio,
      SearchSourceKind.skystream,
    ]);
    expect(results[0].source, isA<StremioSearcher>());
    expect(results[0].results.single.url, 'tt0133093');
    expect(results[1].source, isA<NuvioSearcher>());
    expect(results[1].results.single.tmdbId, 603);
    expect(results[2].source, isNull);
    expect(states.last.others.map((s) => s.name), ['S', 'Nuvio']);
  });

  test('the live filter searches no add-on and no Nuvio', () async {
    final client = _Client([
      () async => [_matrix],
    ]);
    final tmdb = _Tmdb(() async => [_tmdbMatrix]);
    final (_, states) = await search(
      [
        _Plugin('tv', () async => [_film('Matrix TV')], live: true),
      ],
      client: client,
      tmdb: tmdb,
      filter: SearchFilter.live,
    );
    expect(states.last.results.map((r) => r.providerName), ['tv']);
    expect(client.tokens, isEmpty);
    expect(tmdb.searches, 0);
    expect(states.last.others, isEmpty);
  });

  test(
    'a newer search stops the add-ons\' requests of the one before',
    () async {
      final client = _Client([
        () => Completer<List<AddonMetaPreview>>().future,
        () async => [_matrix],
      ]);
      final (container, states) = await search(
        const [],
        client: client,
        tmdb: _Tmdb(() async => const []),
        waitForEnd: false,
      );
      await until(() => client.tokens.isNotEmpty);
      container.read(searchQueryProvider.notifier).set('matrix reloaded');
      await until(() => client.tokens.length == 2);
      await pumpEventQueue();
      expect(client.tokens.first!.isCancelled, isTrue);
    },
  );

  test('an add-on that met a check and came back empty searches again once it clears', () async {
    final client = _Client([
      () async {
        checks.met('s.test', source: AddonClient.sourceFor(_addon));
        checks.update('s.test', CheckState.needsYou);
        return const [];
      },
      () async => [_matrix],
    ]);
    final (_, states) = await search(
      const [],
      client: client,
      tmdb: _Tmdb(() async => const []),
    );
    expect(states.last.results, isEmpty);

    checks.update('s.test', CheckState.cleared);
    await until(() => states.last.results.isNotEmpty);
    expect(states.last.results.single.results.single.title, 'The Matrix');
    expect(client.tokens, hasLength(2));
  });

  test(
    'a searcher\'s results stay as it ranked them, not cut by title words',
    () async {
      // TMDB and add-ons match accents, apostrophes, years and people; the
      // extensions' word filter would drop "Pokémon" for "pokemon".
      const pokemon = 'Pokémon: The First Movie';
      final (_, states) = await search(
        const [],
        client: _Client([
          () async => const [
            AddonMetaPreview(id: 'tt0190641', type: 'movie', name: pokemon),
          ],
        ]),
        tmdb: _Tmdb(
          () async => [
            MultimediaItem(
              title: pokemon,
              url: '',
              posterUrl: '',
              contentType: MultimediaContentType.movie,
              tmdbId: 10228,
            ),
          ],
        ),
        query: 'pokemon',
      );
      expect(
        states.last.results.map((r) => r.providerName),
        unorderedEquals(['S', 'Nuvio']),
      );
    },
  );

  test('add-ons and Nuvio start at once, not after every extension', () async {
    // More extensions than a search runs at a time, none answering yet.
    final gate = Completer<List<MultimediaItem>>();
    final (_, states) = await search(
      [for (var i = 0; i < 40; i++) _Plugin('ext$i', () => gate.future)],
      client: _Client([
        () async => [_matrix],
      ]),
      tmdb: _Tmdb(() async => [_tmdbMatrix]),
      waitForEnd: false,
    );
    await until(() => states.isNotEmpty && states.last.results.length == 2);
    expect(states.last.isLoading, isTrue);
    gate.complete(const []);
  });

  test('the search loads until every searcher has answered once', () async {
    final gate = Completer<List<MultimediaItem>>();
    final (_, states) = await search(
      [
        _Plugin('ext', () async => [_film('Matrix Ext')]),
      ],
      client: _Client([
        () async => [_matrix],
      ]),
      tmdb: _Tmdb(() => gate.future),
      waitForEnd: false,
    );
    await until(() => states.isNotEmpty && states.last.results.length == 2);
    expect(states.last.isLoading, isTrue);
    gate.complete([_tmdbMatrix]);
    await until(() => !states.last.isLoading);
    expect(states.last.results, hasLength(3));
  });
}

/// Waits, a few milliseconds at a time, until [done].
Future<void> until(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
