/// A Stremio show in the player (Stremio direct play): the next episode's
/// links come from the add-on the show came from, asked by the episode's own
/// id and the type the add-on published it as - never from whatever provider
/// is active on Home, which is what an add-on item used to fall back to.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;
import 'package:skystream/core/addons/data/addon_playback_launcher.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/data/addon_stream_service.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/features/library/presentation/history_provider.dart';
import 'package:skystream/features/player/domain/episode_navigator.dart';
import 'package:skystream/features/player/domain/stream_resolver.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

const _bridgeUrl = 'https://bridge.test/u/a/manifest.json';

ProviderReader _readerOf(List<(Object, Object?)> entries) {
  return <T>(ProviderListenable<T> provider) {
    for (final (key, value) in entries) {
      if (identical(key, provider)) return value as T;
    }
    throw StateError('resolver read an unstubbed provider: $provider');
  };
}

final _bridge = ManagedAddon(
  manifestUrl: _bridgeUrl,
  addedAt: DateTime(2026),
  manifest: AddonManifest.fromJson({
    'id': 'com.bridge',
    'name': 'Bridge',
    'version': '1.0.0',
    'types': ['movie', 'series', 'other'],
    'idPrefixes': ['cnc:', 'tt'],
    'resources': ['catalog', 'meta', 'stream'],
  }),
);

class _Service implements AddonStreamService {
  _Service(this.links);

  final List<AddonStreamSource> links;
  final asked = <AddonStreamRequest>[];
  final askedOf = <List<dynamic>>[];

  @override
  Stream<AddonStreamProgress> resolve({
    required List<dynamic> addons,
    required AddonStreamRequest request,
    bool forceRefresh = false,
    dynamic cancelToken,
    bool personWaiting = false,
    Set<String>? only,
  }) async* {
    asked.add(request);
    askedOf.add(addons);
    yield AddonStreamProgress(streams: links);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The provider active on Home: it must never be asked for an add-on item.
class _Active implements SkyStreamProvider {
  var asked = false;

  @override
  String get name => 'Home';

  @override
  Future<List<StreamResult>> loadStreams(String url) async {
    asked = true;
    return const [
      StreamResult(url: 'https://wrong.test/x.mp4', source: 'Wrong'),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MultimediaItem _show({String? addonUrl = _bridgeUrl}) => MultimediaItem(
  title: 'Money Heist',
  url: 'cnc:show',
  posterUrl: '',
  contentType: MultimediaContentType.series,
  provider: 'Bridge',
  source: kAddonItemSource,
  addonUrl: addonUrl,
  addonType: 'other',
  episodes: [
    Episode(name: 'One', url: 'cnc:s1e1', season: 1, episode: 1),
    Episode(name: 'Two', url: 'cnc:s1e2', season: 1, episode: 2),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Active active;
  late _Service service;

  List<(Object, Object?)> stubs({List<ManagedAddon>? installs}) => [
    (activeProviderProvider, active),
    (
      playerSettingsProvider,
      const AsyncValue<PlayerSettings>.data(PlayerSettings()),
    ),
    (watchHistoryProvider, const <HistoryItem>[]),
    (
      addonRepositoryProvider,
      AddonsState(addons: installs ?? [_bridge], isLoading: false),
    ),
    (addonStreamServiceProvider, service),
    (addonStreamConverterProvider, const AddonStreamConverter()),
  ];

  setUp(() {
    active = _Active();
    service = _Service(const [
      AddonStreamSource(
        addonId: 'com.bridge',
        addonName: 'Bridge',
        url: 'https://cdn.test/e2.m3u8',
        name: 'Auto',
      ),
    ]);
  });

  test("the next episode's links come from the show's add-on, asked by its "
      'own id as the type the add-on published', () async {
    final resolved = await resolvePlayback(
      read: _readerOf(stubs()),
      item: _show(),
      videoUrl: 'cnc:s1e2',
      probeCandidates: 0,
    );

    expect(resolved.streams.first.url, 'https://cdn.test/e2.m3u8');
    expect(active.asked, isFalse);
    final asked = service.asked.first;
    expect(asked.videoId, 'cnc:s1e2');
    expect(asked.type, 'other');
    expect((asked.season, asked.episode), (1, 2));
  });

  test('a link picked from another add-on goes on with that add-on, while '
      'the title still names the one that described it', () async {
    // Described by Cinemeta, which serves no links; the viewer played
    // Bridge's link from the sources sheet.
    final cinemeta = ManagedAddon(
      manifestUrl: 'https://cinemeta.test/manifest.json',
      addedAt: DateTime(2026),
      manifest: AddonManifest.fromJson({
        'id': 'com.linvo.cinemeta',
        'name': 'Cinemeta',
        'version': '1.0.0',
        'types': ['movie', 'series'],
        'idPrefixes': ['tt'],
        'resources': ['catalog', 'meta'],
      }),
    );
    final resolved = await resolvePlayback(
      read: _readerOf(stubs(installs: [cinemeta, _bridge])),
      item: _show(addonUrl: cinemeta.manifestUrl)
          .copyWith(streamAddonUrl: _bridgeUrl),
      videoUrl: 'cnc:s1e2',
      probeCandidates: 0,
    );

    expect(resolved.streams.first.url, 'https://cdn.test/e2.m3u8');
    expect(service.askedOf.first, [_bridge]);
    expect(service.asked.first.videoId, 'cnc:s1e2');
  });

  test('with its add-on gone there is nobody to ask: not the active '
      'provider', () async {
    await expectLater(
      resolvePlayback(
        read: _readerOf(stubs(installs: const [])),
        item: _show(),
        videoUrl: 'cnc:s1e2',
        probeCandidates: 0,
      ),
      throwsA(
        isA<StreamResolutionException>().having(
          (e) => e.failure,
          'failure',
          StreamResolutionFailure.noProvider,
        ),
      ),
    );
    expect(active.asked, isFalse);
    expect(service.asked, isEmpty);
  });

  test('an add-on item names no plugin to wait on', () {
    expect(pluginFor(_readerOf(stubs()), _show(), 'cnc:s1e2'), isNull);
    expect(active.asked, isFalse);
  });

  test('the player finds the next episode of a show its add-on published '
      'as `other`', () {
    final item = AddonMeta.fromJson(
      {
        'id': 'cnc:show',
        'type': 'other',
        'name': 'Money Heist',
        'videos': [
          {'id': 'cnc:s1e2', 'title': 'Two', 'season': 1, 'episode': 2},
          {'id': 'cnc:s1e1', 'title': 'One', 'season': 1, 'episode': 1},
        ],
      },
      addonId: 'com.bridge',
      addonName: 'Bridge',
    ).toMultimediaItem(addonUrl: _bridgeUrl);
    final first = item.episodes!.first;
    expect(
      nextEpisodeFor(item: item, current: first, videoUrl: first.url).next?.url,
      'cnc:s1e2',
    );
  });
}
