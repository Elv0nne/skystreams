// A test's ProviderScope is its root scope; the rule only recognises one
// passed to runApp.
// ignore_for_file: riverpod_lint/scoped_providers_should_specify_dependencies

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
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
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/core/services/tmdb_service.dart';
import 'package:skystream/features/cloudstream/presentation/cloudstream_badge.dart';
import 'package:skystream/features/details/presentation/widgets/episode_picker_sheet.dart';
import 'package:skystream/features/explore/data/explore_language_provider.dart';
import 'package:skystream/features/explore/data/explore_tmdb_provider.dart';
import 'package:skystream/features/search/data/search_history_store.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/search_screen.dart';
import 'package:skystream/features/search/presentation/search_sources.dart';
import 'package:skystream/features/search/presentation/widgets/search_result_section.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/sources/presentation/plugin_sources_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/multimedia_card.dart';

class _Manager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => const [];
}

class _History implements SearchHistoryStore {
  @override
  List<String> read() => const [];
  @override
  Future<void> write(List<String> next) async {}
}

/// A searcher that notes what it opens.
class _Source implements SearchSource {
  _Source(this.kind);

  @override
  final SearchSourceKind kind;
  final opened = <MultimediaItem>[];

  @override
  Future<void> open(BuildContext context, MultimediaItem item) async =>
      opened.add(item);
}

class _Client implements AddonClient {
  @override
  Future<List<AddonMetaPreview>> catalog(
    ManagedAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async => const [
    AddonMetaPreview(id: 'tt0133093', type: 'movie', name: 'The Matrix'),
  ];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Tmdb implements TmdbService {
  _Tmdb({this.seasons});

  /// A series' seasons as TMDB lists them; null when its details fail.
  final List<Object>? seasons;

  @override
  Future<Map<String, dynamic>?> getTvDetails(
    int tvId, {
    String language = 'en-US',
  }) async => seasons == null ? null : {'seasons': seasons};

  @override
  Future<Map<String, dynamic>?> getTvSeasonDetails(
    int tvId,
    int seasonNumber, {
    String language = 'en-US',
  }) async => null;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Language extends Language {
  @override
  String build() => 'en-US';
}

/// Nuvio's dialog with one stream found.
class _Service implements NuvioStreamService {
  @override
  Stream<NuvioProgress> resolve({
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
    bool personWaiting = false,
    Set<String>? only,
    bool fresh = false,
  }) => Stream.value(
    const NuvioProgress(
      streams: [
        NuvioStreamResult(
          scraperId: 'a',
          scraperName: 'A',
          title: 'The Matrix 1080p',
          url: 'https://cdn.test/matrix.mkv',
          quality: '1080p',
        ),
      ],
      statuses: [
        NuvioScraperStatus(
          scraperName: 'A',
          outcome: NuvioScraperOutcome.links,
          linkCount: 1,
        ),
      ],
      completedCount: 1,
      totalCount: 1,
      isLoading: false,
    ),
  );

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NuvioRepo extends NuvioRepository {
  @override
  NuvioState build() => const NuvioState(isLoading: false);
}

class _Probe implements LinkProbeService {
  @override
  Future<LinkProbeResult> probe(String url, {Map<String, String>? headers}) =>
      Future.value(const LinkProbeResult(reachable: true));

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _torrentio = ManagedAddon(
  manifestUrl: 'https://torrentio.test/manifest.json',
  addedAt: DateTime(2026),
  manifest: const AddonManifest(
    id: 'Torrentio',
    name: 'Torrentio',
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

MultimediaItem _film(String title, {int? tmdbId}) => MultimediaItem(
  title: title,
  url: 'u/$title',
  posterUrl: '',
  tmdbId: tmdbId,
);

final _series = MultimediaItem(
  title: 'The Matrix Show',
  url: '',
  posterUrl: '',
  contentType: MultimediaContentType.series,
  tmdbId: 9,
);

/// What Nuvio's dialog and the episode picker need.
List<Override> _nuvioOverrides(TmdbService tmdb) => [
  nuvioStreamServiceProvider.overrideWithValue(_Service()),
  nuvioRepositoryProvider.overrideWith(_NuvioRepo.new),
  linkProbeServiceProvider.overrideWithValue(_Probe()),
  playerSettingsProvider.overrideWithBuild((_, _) => const PlayerSettings()),
  tmdbServiceProvider.overrideWithValue(tmdb),
  languageProvider.overrideWith(_Language.new),
];

/// [section] on a page of an app whose details and add-on pages say where
/// they were asked for.
Widget _routed(Widget section, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: [
        extensionManagerProvider.overrideWith(_Manager.new),
        generalSettingsProvider.overrideWithValue(const GeneralSettings()),
        ...overrides,
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: ThemeData(brightness: Brightness.dark),
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Scaffold(body: ListView(children: [section])),
            ),
            GoRoute(
              path: '/details',
              builder: (_, _) => const Text('the details page'),
            ),
            GoRoute(
              path: '/addon-detail',
              builder: (_, state) => Text(
                'add-on page: ${state.uri.queryParameters['type']} '
                '${state.uri.queryParameters['id']} '
                '${state.uri.queryParameters['addon-url']}',
              ),
            ),
          ],
        ),
      ),
    );

Future<void> _settle(WidgetTester tester) async {
  // Result cards show a looping placeholder while posters load.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late SiteChecks checks;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  void tvSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('a section', () {
    testWidgets('names its system in a tag, CloudStream\'s keeping its badge', (
      tester,
    ) async {
      tvSize(tester);
      for (final (kind, id, label) in [
        (SearchSourceKind.skystream, 'p.a', 'SkyStream'),
        (SearchSourceKind.stremio, 'stremio:x', 'Stremio'),
        (SearchSourceKind.nuvio, 'nuvio', 'Nuvio'),
      ]) {
        await tester.pumpWidget(
          _routed(
            SearchResultSection(
              providerName: 'Section',
              providerId: id,
              results: [_film('Film')],
              kind: kind,
            ),
          ),
        );
        await _settle(tester);
        expect(find.text(label), findsOneWidget, reason: '$kind');
      }
      await tester.pumpWidget(
        _routed(
          SearchResultSection(
            providerName: 'Section',
            providerId: 'cs3:x',
            results: [_film('Film')],
            kind: SearchSourceKind.cloudstream,
          ),
        ),
      );
      await _settle(tester);
      expect(find.byType(CloudStreamBadge), findsOneWidget);
    });

    testWidgets('opens a result through its source', (tester) async {
      tvSize(tester);
      final source = _Source(SearchSourceKind.stremio);
      await tester.pumpWidget(
        _routed(
          SearchResultSection(
            providerName: 'S',
            providerId: 'stremio:x',
            results: [_film('The Matrix')],
            kind: SearchSourceKind.stremio,
            source: source,
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(MultimediaCard));
      await _settle(tester);
      expect(source.opened.single.title, 'The Matrix');
      expect(find.text('the details page'), findsNothing);
    });

    testWidgets('without a source, opens a result on the details page', (
      tester,
    ) async {
      tvSize(tester);
      await tester.pumpWidget(
        _routed(
          SearchResultSection(
            providerName: 'A',
            providerId: 'p.a',
            results: [_film('Film')],
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(MultimediaCard));
      await _settle(tester);
      expect(find.text('the details page'), findsOneWidget);
    });
  });

  group('through the real searchers', () {
    testWidgets(
      'a Stremio result opens Stremio\'s details page, asked of its add-on',
      (tester) async {
        tvSize(tester);
        final searcher = StremioSearcher(_torrentio, _Client());
        final items = await searcher.search('matrix');
        await tester.pumpWidget(
          _routed(
            SearchResultSection(
              providerName: searcher.name,
              providerId: searcher.packageName,
              results: items,
              kind: searcher.kind,
              source: searcher,
            ),
          ),
        );
        await _settle(tester);
        await tester.tap(find.byType(MultimediaCard));
        await _settle(tester);
        expect(
          find.text(
            'add-on page: movie tt0133093 https://torrentio.test/manifest.json',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('a Nuvio film opens Nuvio\'s sources dialog', (tester) async {
      tvSize(tester);
      final tmdb = _Tmdb();
      final searcher = NuvioSearcher(tmdb);
      await tester.pumpWidget(
        _routed(
          SearchResultSection(
            providerName: 'Nuvio',
            providerId: 'nuvio',
            results: [_film('The Matrix', tmdbId: 603)],
            kind: SearchSourceKind.nuvio,
            source: searcher,
          ),
          overrides: _nuvioOverrides(tmdb),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(MultimediaCard));
      await _settle(tester);
      expect(find.byType(PluginSourcesSheet), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a Nuvio series asks for its episode first', (tester) async {
      tvSize(tester);
      final tmdb = _Tmdb(
        seasons: [
          {'season_number': 1},
          {'season_number': 2},
        ],
      );
      await tester.pumpWidget(
        _routed(
          SearchResultSection(
            providerName: 'Nuvio',
            providerId: 'nuvio',
            results: [_series],
            kind: SearchSourceKind.nuvio,
            source: NuvioSearcher(tmdb),
          ),
          overrides: _nuvioOverrides(tmdb),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(MultimediaCard));
      await _settle(tester);
      expect(find.byType(EpisodePickerSheet), findsOneWidget);
      expect(find.byType(PluginSourcesSheet), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a Nuvio series\' episode picker outlives its card', (
      tester,
    ) async {
      // A rotation or a resize can rebuild the results while the picker is
      // open: it opens the sources dialog from a context that's still there.
      tvSize(tester);
      final tmdb = _Tmdb(
        seasons: [
          {'season_number': 1},
        ],
      );
      final shown = ValueNotifier(true);
      await tester.pumpWidget(
        _routed(
          ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (_, show, _) => show
                ? SearchResultSection(
                    providerName: 'Nuvio',
                    providerId: 'nuvio',
                    results: [_series],
                    kind: SearchSourceKind.nuvio,
                    source: NuvioSearcher(tmdb),
                  )
                : const SizedBox(),
          ),
          overrides: _nuvioOverrides(tmdb),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(MultimediaCard));
      await _settle(tester);
      expect(find.byType(EpisodePickerSheet), findsOneWidget);

      shown.value = false;
      await _settle(tester);
      expect(
        tester
            .widget<EpisodePickerSheet>(find.byType(EpisodePickerSheet))
            .hostContext
            .mounted,
        isTrue,
        reason: 'the picker would open the dialog from a card that is gone',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a Nuvio series whose seasons don\'t load says so', (
      tester,
    ) async {
      tvSize(tester);
      final tmdb = _Tmdb();
      await tester.pumpWidget(
        _routed(
          SearchResultSection(
            providerName: 'Nuvio',
            providerId: 'nuvio',
            results: [_series],
            kind: SearchSourceKind.nuvio,
            source: NuvioSearcher(tmdb),
          ),
          overrides: _nuvioOverrides(tmdb),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(MultimediaCard));
      await _settle(tester);
      expect(
        find.text('Couldn\'t load this series\' episodes'),
        findsOneWidget,
      );
      expect(find.byType(EpisodePickerSheet), findsNothing);
    });
  });

  /// The search screen showing [state].
  Future<void> pumpScreen(
    WidgetTester tester,
    SearchAggregateState state, {
    List<Override> overrides = const [],
  }) async {
    tvSize(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchHistoryStoreProvider.overrideWithValue(_History()),
          searchResultsProvider.overrideWith((ref) => Stream.value(state)),
          extensionManagerProvider.overrideWith(_Manager.new),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          ...overrides,
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark(),
          home: const SearchScreen(),
        ),
      ),
    );
    await _settle(tester);
  }

  testWidgets('the check section names an add-on\'s check by the add-on', (
    tester,
  ) async {
    final began = checks.now;
    checks
      ..met('torrentio.test', source: AddonClient.sourceFor(_torrentio))
      ..update('torrentio.test', CheckState.needsYou);
    await pumpScreen(
      tester,
      SearchAggregateState(
        startedAt: began,
        others: [StremioSearcher(_torrentio, _Client())],
      ),
    );
    await tester.tap(find.byTooltip('Show the sites'));
    await _settle(tester);
    expect(find.textContaining('Torrentio'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'on TV, the remote goes down into Stremio\'s and Nuvio\'s sections and opens a Nuvio film',
    (tester) async {
      final tmdb = _Tmdb();
      await pumpScreen(
        tester,
        SearchAggregateState(
          startedAt: checks.now,
          results: [
            ProviderSearchResult(
              providerId: 'p.a',
              providerName: 'A',
              results: [_film('Matrix A')],
            ),
            ProviderSearchResult(
              providerId: 'stremio:x',
              providerName: 'Torrentio',
              results: [_film('Matrix S')],
              source: _Source(SearchSourceKind.stremio),
            ),
            ProviderSearchResult(
              providerId: 'nuvio',
              providerName: 'Nuvio',
              results: [_film('The Matrix', tmdbId: 603)],
              source: NuvioSearcher(tmdb),
            ),
          ],
        ),
        overrides: _nuvioOverrides(tmdb),
      );

      /// The section holding the focus.
      String? focusedSection() => FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<SearchResultSection>()
          ?.providerName;

      tester
          .widget<MultimediaCard>(find.byType(MultimediaCard).first)
          .focusNode!
          .requestFocus();
      await tester.pump();
      expect(focusedSection(), 'A');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      expect(focusedSection(), 'Torrentio');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      expect(focusedSection(), 'Nuvio');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _settle(tester);
      expect(find.byType(PluginSourcesSheet), findsOneWidget);
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(
        focused?.findAncestorWidgetOfExactType<SearchResultSection>(),
        isNull,
        reason: 'the remote\'s focus stayed behind the dialog',
      );
      expect(
        focused?.findAncestorWidgetOfExactType<PluginSourcesSheet>(),
        isNotNull,
        reason: 'the remote\'s focus isn\'t on the dialog\'s streams',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
