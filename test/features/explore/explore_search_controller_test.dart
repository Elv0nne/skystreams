import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/features/explore/data/explore_mode_provider.dart';
import 'package:skystream/features/explore/presentation/controllers/explore_search_controller.dart';

/// Typing in the search field moves the controller's query along with the
/// text, and submitting asks for that query's results. The results already
/// held were taken for the new query's, so the second search of a visit
/// showed the first one's results: "vyaan" answered with the cricket found
/// for "India vs Afghanistan".
void main() {
  late _Client client;
  late ProviderContainer container;

  setUp(() {
    client = _Client();
    container = ProviderContainer(
      overrides: [
        exploreModeProvider.overrideWith(_StremioMode.new),
        addonRepositoryProvider.overrideWith(_Repo.new),
        addonClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    container.listen(exploreSearchControllerProvider, (_, _) {});
  });

  ExploreSearchController controller() =>
      container.read(exploreSearchControllerProvider.notifier);

  List<String> results() => [
    for (final item in container.read(exploreSearchControllerProvider).results)
      item.title,
  ];

  test('a new search shows its own results, not the last one\'s', () async {
    await controller().fetchResults('India vs Afghanistan');
    expect(results(), ['India vs Afghanistan match']);

    // Typed into the field, as the suggestions list reports it, then
    // submitted.
    controller().onQueryChanged('vyaan');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await controller().fetchResults('vyaan');
    expect(results(), ['vyaan match']);
  });

  // A plain item keeps neither the add-on that listed a title nor the type it
  // listed it as: a CNCVerse `other` opened as a `movie` asked of every
  // add-on, and a scraping bridge's slow description was cut off.
  test('a result opens where it came from, as what it was listed', () async {
    await controller().fetchResults('vyaan');
    final item = container.read(exploreSearchControllerProvider).results.single;
    expect(parseAddonSearchItemUrl(item.url), (
      type: 'other',
      id: 'cnc:vyaan',
      addonUrl: 'https://bridge.test/manifest.json',
    ));
  });

  test('coming back to the same search does not ask again', () async {
    await controller().fetchResults('vyaan');
    final asked = client.searches;
    await controller().fetchResults('vyaan');
    expect(client.searches, asked);
    expect(results(), ['vyaan match']);
  });
}

class _StremioMode extends ExploreMode {
  @override
  ExploreModeType build() => ExploreModeType.stremio;
}

class _Repo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    isLoading: false,
    addons: [
      ManagedAddon(
        manifestUrl: 'https://bridge.test/manifest.json',
        addedAt: DateTime(2026),
        manifest: const AddonManifest(
          id: 'bridge',
          name: 'Bridge',
          version: '1',
          resources: [AddonResource(name: 'catalog')],
          types: ['other'],
          catalogs: [
            AddonCatalog(
              type: 'other',
              id: 'search',
              name: 'Search',
              extra: [AddonExtraProperty(name: 'search')],
            ),
          ],
        ),
      ),
    ],
  );
}

class _Client extends AddonClient {
  _Client() : super(Dio());

  int searches = 0;

  @override
  Future<List<AddonMetaPreview>> catalog(
    ManagedAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async {
    final query = extra?['search'];
    if (query == null) return const [];
    searches++;
    return [
      AddonMetaPreview(
        id: 'cnc:$query',
        type: type,
        name: '$query match',
        addonId: addon.id,
      ),
    ];
  }
}
