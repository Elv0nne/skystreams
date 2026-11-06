/// Stremio add-ons on a launch: every manifest fetched again, and the ones
/// whose version moved named, so the launch toast can say what changed.
///
/// The refresh used to be kicked off from `load()`, fire-and-forget, with
/// nothing reported. The launch now runs it for every extension system at once
/// and lists what changed across all of them.
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';

AddonManifest _manifest(String id, String name, String version) =>
    AddonManifest(
      id: id,
      name: name,
      version: version,
      resources: const [AddonResource(name: 'stream')],
      types: const ['movie'],
    );

ManagedAddon _stored(String url, AddonManifest manifest) =>
    ManagedAddon(manifestUrl: url, manifest: manifest, addedAt: DateTime(2026));

/// Hands back whatever [latest] says each add-on publishes now.
class _Client extends AddonClient {
  _Client(this.latest) : super(Dio());

  final Map<String, AddonManifest> latest;
  final List<String> fetched = <String>[];

  @override
  Future<AddonManifest> fetchManifest(
    String manifestUrl, {
    bool forceRefresh = false,
    bool personWaiting = false,
  }) async {
    fetched.add(manifestUrl);
    final manifest = latest[manifestUrl];
    if (manifest == null) throw const AddonException('unreachable');
    return manifest;
  }

  @override
  void invalidate(ManagedAddon addon) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const moved = 'https://moved.test/manifest.json';
  const same = 'https://same.test/manifest.json';
  const gone = 'https://gone.test/manifest.json';

  ProviderContainer boot(_Client client) {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'stremio_addons_v2': <String>[
        jsonEncode(_stored(moved, _manifest('moved', 'Torrentio', '1.0.0'))),
        jsonEncode(_stored(same, _manifest('same', 'Cinemeta', '3.0.0'))),
        jsonEncode(_stored(gone, _manifest('gone', 'Dead Addon', '1.0.0'))),
      ],
    });
    final container = ProviderContainer(
      overrides: [addonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('every add-on is fetched again, and the ones that moved named', () async {
    final client = _Client(<String, AddonManifest>{
      moved: _manifest('moved', 'Torrentio', '1.1.0'),
      same: _manifest('same', 'Cinemeta', '3.0.0'),
    });
    final container = boot(client);

    final updated = await container
        .read(addonRepositoryProvider.notifier)
        .autoUpdate();

    expect(updated, <String>['Torrentio']);
    expect(client.fetched, unorderedEquals(<String>[moved, same, gone]));
    final addons = container.read(addonRepositoryProvider).addons;
    expect(
      addons.firstWhere((a) => a.manifestUrl == moved).manifest?.version,
      '1.1.0',
    );
    // An add-on that could not be reached keeps what it had.
    expect(
      addons.firstWhere((a) => a.manifestUrl == gone).manifest?.version,
      '1.0.0',
    );
  });

  test('loading the add-ons does not start a refresh of its own', () async {
    final client = _Client(const <String, AddonManifest>{});
    final container = boot(client);

    container.read(addonRepositoryProvider);
    await pumpEventQueue();

    expect(
      container.read(addonRepositoryProvider).addons,
      hasLength(3),
      reason: 'the stored add-ons were not loaded',
    );
    expect(
      client.fetched,
      isEmpty,
      reason: 'load() fetched manifests the launch refresh fetches again',
    );
  });
}
