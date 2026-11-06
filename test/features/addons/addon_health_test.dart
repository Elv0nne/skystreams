import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/features/addons/presentation/addon_providers.dart';

/// The Manage tab shows Nuvio-style Working/Unavailable badges via
/// [probeAddonsHealth]: every installed manifest is pinged concurrently and
/// one dead host must not hold the others' verdicts hostage.
void main() {
  AddonManifest sampleManifest(String id) => AddonManifest.fromJson({
    'id': id,
    'name': id,
    'version': '1.0.0',
    'types': const ['movie'],
    'resources': const ['catalog'],
  });

  ManagedAddon managed(String label) => ManagedAddon(
    manifestUrl: 'https://$label.example/manifest.json',
    manifest: sampleManifest('test.$label'),
    addedAt: DateTime(2024),
  );

  group('probeAddonsHealth', () {
    test(
      'fast answers are working with latency, throwers unavailable',
      () async {
        final results = await probeAddonsHealth(
          _FakeHealthClient({
            'up': () async => sampleManifest('test.up'),
            'down': () async =>
                throw const AddonException('manifest not valid'),
          }),
          [managed('up'), managed('down')],
        );

        final up = results['https://up.example/manifest.json']!;
        expect(up.status, AddonHealthStatus.working);
        expect(up.latencyMs, isNotNull);
        expect(up.message, isNull);

        final down = results['https://down.example/manifest.json']!;
        expect(down.status, AddonHealthStatus.unavailable);
        expect(down.message, contains('manifest not valid'));
        expect(down.latencyMs, isNull);
      },
    );

    test(
      'a hanging host degrades to unavailable within the probe timeout',
      () async {
        final results = await probeAddonsHealth(
          _FakeHealthClient({
            'hang': () => Future<AddonManifest>.delayed(
              const Duration(hours: 1),
              () => sampleManifest('test.hang'),
            ),
          }),
          [managed('hang')],
          timeout: const Duration(milliseconds: 300),
        );

        final hang = results['https://hang.example/manifest.json']!;
        expect(hang.status, AddonHealthStatus.unavailable);
        expect(hang.latencyMs, isNull);
        expect(hang.message, isNotNull);
      },
    );

    test(
      'every installed add-on gets a verdict — no key goes missing',
      () async {
        final results = await probeAddonsHealth(
          _FakeHealthClient({
            'a': () async => sampleManifest('test.a'),
            'b': () async => sampleManifest('test.b'),
            'c': () async => throw const AddonException('gone'),
          }),
          [managed('a'), managed('b'), managed('c')],
        );

        expect(results.keys, hasLength(3));
        expect(
          results.values.every(
            (h) =>
                h.latencyMs != null ||
                h.status == AddonHealthStatus.unavailable,
          ),
          isTrue,
        );
      },
    );
  });

  group('addonHealthProvider', () {
    // Switching an add-on off or moving it up the list says nothing about
    // whether its host answers. Watched whole, the add-on list re-fetched
    // every manifest on either, and every badge went back to "Checking".
    test('probes the installed set again only when the set changes', () async {
      final client = _FakeHealthClient({
        'a': () async => sampleManifest('test.a'),
        'b': () async => sampleManifest('test.b'),
        'c': () async => sampleManifest('test.c'),
      });
      final a = managed('a');
      final b = managed('b');
      final container = ProviderContainer(
        overrides: [
          addonClientProvider.overrideWithValue(client),
          addonRepositoryProvider.overrideWith(() => _StubRepository([a, b])),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(addonHealthProvider, (_, _) {});
      addTearDown(subscription.close);
      final repository =
          container.read(addonRepositoryProvider.notifier) as _StubRepository;

      await container.read(addonHealthProvider.future);
      expect(client.fetches, 2);

      repository.replace([b, a.copyWith(enabled: false)]);
      await container.read(addonHealthProvider.future);
      expect(client.fetches, 2, reason: 'the same hosts, reordered and off');

      repository.replace([a, b, managed('c')]);
      await container.read(addonHealthProvider.future);
      expect(client.fetches, 5, reason: 'an install probes the set again');
    });
  });
}

class _StubRepository extends AddonRepository {
  _StubRepository(this._initial);

  final List<ManagedAddon> _initial;

  @override
  AddonsState build() => AddonsState(addons: _initial, isLoading: false);

  void replace(List<ManagedAddon> addons) =>
      state = state.copyWith(addons: addons);
}

typedef _ManifestHandler = Future<AddonManifest> Function();

class _FakeHealthClient extends AddonClient {
  _FakeHealthClient(this.handlers) : super(Dio());

  final Map<String, _ManifestHandler> handlers;
  int fetches = 0;

  @override
  Future<AddonManifest> fetchManifest(
    String url, {
    bool forceRefresh = false,
    bool personWaiting = false,
  }) {
    fetches++;
    final key = Uri.parse(url).host.split('.').first;
    final handler = handlers[key];
    if (handler == null) {
      throw const AddonException('no fake handler for this host');
    }
    return handler();
  }
}
