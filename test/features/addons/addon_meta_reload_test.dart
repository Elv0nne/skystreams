/// An open Stremio page keeps its details while the add-on list is read again
/// unchanged (found by the Stremio direct-play device test): the update check
/// at launch reads every manifest again, and the page asked its add-on for the
/// details again - deferred while the player covered it, so a viewer back from
/// an episode met the loading placeholder, for as long as a bridge takes to
/// describe a title (9 to 29 s for CNCVerse).
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/features/addons/presentation/addon_providers.dart';

const _bridgeUrl = 'https://bridge.test/manifest.json';

ManagedAddon _install(String url, {List<String> resources = const ['meta']}) =>
    ManagedAddon(
      manifestUrl: url,
      addedAt: DateTime(2026),
      manifest: AddonManifest(
        id: url,
        name: 'Add-on',
        version: '1',
        resources: [for (final r in resources) AddonResource(name: r)],
        types: const ['movie', 'series', 'other'],
      ),
    );

class _Repo extends AddonRepository {
  @override
  AddonsState build() =>
      AddonsState(isLoading: false, addons: [_install(_bridgeUrl)]);

  /// What an update check that found nothing new leaves: the same add-ons,
  /// as new objects.
  void readAgain() =>
      state = state.copyWith(addons: [for (final a in state.addons) a]);

  void add(ManagedAddon addon) =>
      state = state.copyWith(addons: [...state.addons, addon]);
}

class _Client extends AddonClient {
  _Client() : super(Dio());

  var asked = 0;

  @override
  Future<AddonMeta?> meta(
    ManagedAddon addon, {
    required String type,
    required String id,
    bool forceRefresh = false,
    CancelToken? cancelToken,
    bool personWaiting = false,
  }) async {
    asked++;
    return AddonMeta.fromJson(
      {'id': id, 'type': type, 'name': 'Title'},
      addonId: addon.id,
      addonName: addon.displayName,
    );
  }
}

void main() {
  late _Client client;
  late ProviderContainer container;
  final details = addonMetaProvider(
    'other',
    'cnc:title',
    preferredAddonUrl: _bridgeUrl,
  );

  setUp(() async {
    client = _Client();
    container = ProviderContainer(
      overrides: [
        addonRepositoryProvider.overrideWith(_Repo.new),
        addonClientProvider.overrideWithValue(client),
      ],
    );
    final open = container.listen(details, (_, _) {});
    addTearDown(open.close);
    addTearDown(container.dispose);
    expect((await container.read(details.future))?.id, 'cnc:title');
    expect(client.asked, 1);
  });

  _Repo repo() => container.read(addonRepositoryProvider.notifier) as _Repo;

  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  test('the same add-ons read again: the page keeps its details', () async {
    repo().readAgain();
    await settle();

    expect(container.read(details).isLoading, isFalse);
    expect(client.asked, 1);
  });

  test('a new add-on that can describe titles: it is asked again', () async {
    repo().add(_install('https://other.test/manifest.json'));
    await settle();
    await container.read(details.future);

    expect(client.asked, 2);
  });

  test('a new add-on that only streams: nothing to ask again', () async {
    repo().add(
      _install('https://streams.test/manifest.json', resources: ['stream']),
    );
    await settle();

    expect(container.read(details).isLoading, isFalse);
    expect(client.asked, 1);
  });
}
