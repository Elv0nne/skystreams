import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/features/addons/presentation/addon_providers.dart';

/// A scraping bridge's /meta is a scrape: CNCVerse took 9 to 29 seconds to
/// describe the titles its own search had just listed. At the 12 seconds a
/// plain meta add-on gets, most of them opened on "No installed add-on could
/// describe this title" - after 36 seconds, one timeout for each of the
/// `other`, `movie` and `series` it was asked as.
void main() {
  const bridgeUrl = 'https://bridge.test/manifest.json';

  Future<(AddonMeta?, bool)> open(
    WidgetTester tester,
    _Client client, {
    required Duration after,
  }) async {
    final container = ProviderContainer(
      overrides: [
        addonRepositoryProvider.overrideWith(_Repo.new),
        addonClientProvider.overrideWithValue(client),
      ],
    );
    addTearDown(container.dispose);
    AddonMeta? meta;
    var done = false;
    final subscription = container.listen(
      addonMetaProvider('other', 'cnc:vvaan', preferredAddonUrl: bridgeUrl),
      (_, _) {},
    );
    addTearDown(subscription.close);
    unawaited(
      container
          .read(
            addonMetaProvider(
              'other',
              'cnc:vvaan',
              preferredAddonUrl: bridgeUrl,
            ).future,
          )
          .then((value) {
            meta = value;
            done = true;
          }),
    );
    await tester.pump(after);
    return (meta, done);
  }

  testWidgets('the add-on that listed a title gets the time to describe it', (
    tester,
  ) async {
    final client = _Client(answerAfter: const Duration(seconds: 25));
    final (meta, done) = await open(
      tester,
      client,
      after: const Duration(seconds: 26),
    );
    expect(done, isTrue);
    expect(meta?.name, 'The Vvaan: Force of the Forrest');
  });

  testWidgets('a host that does not answer is asked once, not once a type', (
    tester,
  ) async {
    final client = _Client(answerAfter: null);
    final (meta, done) = await open(
      tester,
      client,
      after: const Duration(seconds: 50),
    );
    expect(done, isTrue);
    expect(meta, isNull);
    expect(client.requests, ['other']);
  });
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
          resources: [AddonResource(name: 'meta')],
          types: ['movie', 'series', 'other', 'tv'],
        ),
      ),
    ],
  );
}

class _Client extends AddonClient {
  _Client({required this.answerAfter}) : super(Dio());

  /// Null: never answers.
  final Duration? answerAfter;
  final List<String> requests = [];

  @override
  Future<AddonMeta?> meta(
    ManagedAddon addon, {
    required String type,
    required String id,
    bool forceRefresh = false,
    CancelToken? cancelToken,
    bool personWaiting = false,
  }) {
    requests.add(type);
    final delay = answerAfter;
    if (delay == null) return Completer<AddonMeta?>().future;
    return Future.delayed(
      delay,
      () => AddonMeta.fromJson({
        'id': id,
        'type': type,
        'name': 'The Vvaan: Force of the Forrest',
      }),
    );
  }
}
