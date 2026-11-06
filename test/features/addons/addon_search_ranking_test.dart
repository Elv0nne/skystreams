import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/features/addons/presentation/addon_providers.dart';

/// Add-on search asks every searchable catalog and merges the answers into
/// one list. Merged in catalog order, the first installed catalog's loose
/// matches came first: searching "India vs Afghanistan" opened on Cinemeta's
/// "India's Got Latent", while the match itself sat in a bridge's live-events
/// catalog behind twenty-odd others, past the ten suggestions shown. The
/// names below are what Cinemeta and CNCVerse answered for that search.
void main() {
  AddonMetaPreview item(String name, {String addon = 'cinemeta'}) =>
      AddonMetaPreview(id: '$addon:$name', type: 'other', name: name);

  List<String> names(List<AddonMetaPreview> items) => [
    for (final i in items) i.name,
  ];

  group('merged search results', () {
    test('lead with the names that match the search', () {
      final ranked = rankAddonSearchResults([
        item("The Dan Bongino Show: Behind Biden's Afghanistan Disaster"),
        item('Monsters vs. Aliens'),
        item("India's Got Latent"),
        item('Caminho das Índias'),
        item('India vs West Indies', addon: 'cnc'),
        item('Match 1 | Afghanistan vs Hong Kong', addon: 'cnc'),
        item('Afghanistan vs India', addon: 'cnc'),
        item('Match 7 | India vs Afghanistan', addon: 'cnc'),
        item('India vs. Afghanistan', addon: 'live'),
      ], 'India vs Afghanistan');
      expect(names(ranked).take(3), [
        'India vs. Afghanistan',
        'Match 7 | India vs Afghanistan',
        'Afghanistan vs India',
      ]);
      // Then by how much of the search they share, and a name sharing none
      // of it goes last.
      expect(names(ranked).last, 'Caminho das Índias');
      expect(
        names(ranked).indexOf('India vs West Indies'),
        lessThan(names(ranked).indexOf("India's Got Latent")),
      );
    });

    test('keep the catalogs\' own order among equals', () {
      final ranked = rankAddonSearchResults([
        item('Match 12 | India vs Oman'),
        item('Match 6 | India vs Pakistan'),
        item('Final | India vs Pakistan'),
      ], 'india vs');
      expect(names(ranked), [
        'Match 12 | India vs Oman',
        'Match 6 | India vs Pakistan',
        'Final | India vs Pakistan',
      ]);
    });

    test('match a word still being typed', () {
      final ranked = rankAddonSearchResults([
        item("India's Got Latent"),
        item('Afghanistan vs India', addon: 'cnc'),
      ], 'india vs afgh');
      expect(ranked.first.name, 'Afghanistan vs India');
    });
  });

  test('add-on search returns them in that order', () async {
    final container = ProviderContainer(
      overrides: [
        addonRepositoryProvider.overrideWith(_Repo.new),
        addonClientProvider.overrideWithValue(_Client()),
      ],
    );
    addTearDown(container.dispose);
    final results = await container.read(
      addonSearchProvider('India vs Afghanistan').future,
    );
    expect(results.first.name, 'India vs Afghanistan');
    expect(results, hasLength(4));
  });
}

ManagedAddon _addon(String id, List<AddonCatalog> catalogs) => ManagedAddon(
  manifestUrl: 'https://$id.test/manifest.json',
  addedAt: DateTime(2026),
  manifest: AddonManifest(
    id: id,
    name: id,
    version: '1',
    resources: const [AddonResource(name: 'catalog')],
    types: const ['movie', 'series', 'tv'],
    catalogs: catalogs,
  ),
);

const _search = [AddonExtraProperty(name: 'search')];

class _Repo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    isLoading: false,
    addons: [
      _addon('cinemeta', const [
        AddonCatalog(
          type: 'series',
          id: 'top',
          name: 'Popular',
          extra: _search,
        ),
      ]),
      _addon('bridge', const [
        AddonCatalog(
          type: 'tv',
          id: 'live',
          name: 'Live Events',
          extra: _search,
        ),
      ]),
    ],
  );
}

class _Client extends AddonClient {
  _Client() : super(Dio());

  @override
  Future<List<AddonMetaPreview>> catalog(
    ManagedAddon addon, {
    required String type,
    required String id,
    Map<String, String>? extra,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) async => [
    for (final name
        in id == 'top'
            ? const ['Star vs. the Forces of Evil', "India's Got Latent"]
            : const ['India vs West Indies', 'India vs Afghanistan'])
      AddonMetaPreview(id: '$id:$name', type: type, name: name),
  ];
}
