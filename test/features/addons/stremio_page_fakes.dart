/// What the Stremio details page tests share (Stremio direct play): an add-on
/// shaped like CNCVerse Bridge, a stream service that answers per episode, a
/// launcher that notes what it would play, and history.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart' show Override;
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/data/addon_stream_service.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/storage/episode_watch_repository.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/addons/presentation/addon_detail_screen.dart';
import 'package:skystream/features/addons/presentation/addon_providers.dart';
import 'package:skystream/features/details/presentation/playback_launcher.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const kBridgeUrl = 'https://bridge.test/u/a/manifest.json';

/// CNCVerse Bridge's shape: a catalog, its titles' meta and their streams.
class BridgeRepo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    addons: [
      ManagedAddon(
        manifestUrl: kBridgeUrl,
        addedAt: DateTime(2026),
        manifest: AddonManifest.fromJson({
          'id': 'com.bridge',
          'name': 'Bridge',
          'version': '1.0.0',
          'types': ['movie', 'series', 'other'],
          'idPrefixes': ['cnc:', 'tt'],
          'resources': ['catalog', 'meta', 'stream'],
          'catalogs': <Object>[],
        }),
      ),
    ],
    isLoading: false,
  );
}

/// Answers with [links] (a test may change them between asks), or with
/// [byVideo]'s links for an episode it names; never, when [hold] is set.
/// With a [gate], an ask nobody waits on answers once it opens; with
/// [holdWaiting], an ask somebody waits on never does. Notes each ask.
class FakeStreamService implements AddonStreamService {
  FakeStreamService(
    this.links, {
    this.byVideo = const {},
    this.hold = false,
    this.gate,
    this.holdWaiting = false,
  });

  List<AddonStreamSource> links;
  final Map<String, List<AddonStreamSource>> byVideo;
  final bool hold;
  final Future<void>? gate;
  final bool holdWaiting;
  final asked = <({AddonStreamRequest request, bool personWaiting})>[];

  @override
  Stream<AddonStreamProgress> resolve({
    required List<dynamic> addons,
    required AddonStreamRequest request,
    bool forceRefresh = false,
    dynamic cancelToken,
    bool personWaiting = false,
    Set<String>? only,
  }) async* {
    asked.add((request: request, personWaiting: personWaiting));
    if (hold || (personWaiting && holdWaiting)) {
      await Completer<void>().future;
    }
    if (!personWaiting && gate != null) await gate!;
    yield AddonStreamProgress(
      streams: byVideo[request.videoId] ?? links,
      completedCount: 1,
      totalCount: 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Notes what it was asked to play instead of opening a player - or, with
/// [opensPlayer], opens a stand-in "PLAYER" page and returns when it closes,
/// as the real launcher's player route does.
class RecordingLauncher implements PlaybackLauncher {
  RecordingLauncher({this.opensPlayer = false});

  final bool opensPlayer;
  final played =
      <
        ({
          MultimediaItem item,
          String videoUrl,
          Episode? episode,
          List<StreamResult> streams,
        })
      >[];

  @override
  Future<void> playResolved(
    BuildContext context, {
    required MultimediaItem item,
    required String videoUrl,
    Episode? episode,
    List<StreamResult> streams = const <StreamResult>[],
  }) async {
    played.add((
      item: item,
      videoUrl: videoUrl,
      episode: episode,
      streams: streams,
    ));
    if (!opensPlayer) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => const Scaffold(body: Center(child: Text('PLAYER'))),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Saved positions by URL (of an hour each), and the episode played last.
class FakeHistory extends HistoryRepository {
  FakeHistory({this.positions = const {}, this.lastEpisode})
    : super(StorageService());

  final Map<String, int> positions;
  final String? lastEpisode;

  @override
  List<HistoryItem> getWatchHistory() => const <HistoryItem>[];
  @override
  int getPosition(String url) => positions[url] ?? 0;
  @override
  int getDuration(String url) => positions.containsKey(url) ? 3600000 : 0;
  @override
  int getEpisodePosition(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => positions[url] ?? 0;
  @override
  int getEpisodeDuration(
    String url, {
    String? mainUrl,
    int? season,
    int? episode,
  }) => positions.containsKey(url) ? 3600000 : 0;
  @override
  String? getLastEpisodeUrl(String url) => lastEpisode;
}

/// Episodes watched, by URL.
class FakeWatched extends EpisodeWatchRepository {
  FakeWatched(HistoryRepository history, this.watched)
    : super(StorageService(), history, _ignore);

  final Set<String> watched;

  static void _ignore() {}

  @override
  bool? getExplicitState(String mainUrl, Episode episode) => null;
  @override
  bool isWatched(String mainUrl, Episode episode) =>
      watched.contains(episode.url);
}

/// Every link answers.
class FakeProbe implements LinkProbeService {
  @override
  Future<LinkProbeResult> probe(String url, {Map<String, String>? headers}) =>
      Future.value(const LinkProbeResult(reachable: true));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const kBridgeMovie = AddonMeta(
  id: 'cnc:film',
  type: 'other',
  name: 'Spider-Man',
  addonId: 'com.bridge',
  addonName: 'Bridge',
);

/// Two seasons, published as `other` the way CNCVerse publishes shows.
const kBridgeShow = AddonMeta(
  id: 'cnc:show',
  type: 'other',
  name: 'Money Heist',
  addonId: 'com.bridge',
  addonName: 'Bridge',
  videos: [
    AddonVideo(id: 'cnc:s1e1', title: 'One', season: 1, episode: 1),
    AddonVideo(id: 'cnc:s1e2', title: 'Two', season: 1, episode: 2),
    AddonVideo(id: 'cnc:s2e1', title: 'Three', season: 2, episode: 1),
  ],
);

const kLink = AddonStreamSource(
  addonId: 'com.bridge',
  addonName: 'Bridge',
  url: 'https://cdn.test/a.m3u8',
  name: 'Auto',
);

const kDonate = AddonStreamSource(
  addonId: 'com.bridge',
  addonName: 'Bridge',
  externalUrl: 'https://donate.test/',
);

/// The bot-check machinery the page reads, for every test in the file.
void useTestClearance() {
  setUp(() {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    final checks = SiteChecks();
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: checks,
      solver: ClearanceSolver(store: store, siteKeys: keys, checks: checks),
    );
  });
  tearDown(() => Clearance.instance.solver.dispose());
}

/// The Stremio details page for [meta], listed by [kBridgeUrl]'s catalog.
Future<({FakeStreamService service, RecordingLauncher launcher})>
openStremioPage(
  WidgetTester tester,
  AddonMeta meta, {
  List<AddonStreamSource> links = const [kLink],
  Map<String, List<AddonStreamSource>> byVideo = const {},
  bool hold = false,
  Future<void>? gate,
  bool holdWaiting = false,
  bool opensPlayer = false,
  HistoryRepository? history,
  Set<String> watched = const {},
  Size size = const Size(1920, 1080),
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final service = FakeStreamService(
    links,
    byVideo: byVideo,
    hold: hold,
    gate: gate,
    holdWaiting: holdWaiting,
  );
  final launcher = RecordingLauncher(opensPlayer: opensPlayer);
  final saved = history ?? FakeHistory();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        addonRepositoryProvider.overrideWith(BridgeRepo.new),
        addonMetaProvider(
          meta.type,
          meta.id,
          preferredAddonUrl: kBridgeUrl,
        ).overrideWith((ref) async => meta),
        addonStreamServiceProvider.overrideWithValue(service),
        playbackLauncherProvider.overrideWithValue(launcher),
        playerSettingsProvider.overrideWithBuild(
          (_, _) => const PlayerSettings(),
        ),
        historyRepositoryProvider.overrideWithValue(saved),
        episodeWatchRepositoryProvider.overrideWithValue(
          FakeWatched(saved, watched),
        ),
        linkProbeServiceProvider.overrideWithValue(FakeProbe()),
        ...overrides,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AddonDetailScreen(
          type: meta.type,
          id: meta.id,
          addonUrl: kBridgeUrl,
        ),
      ),
    ),
  );
  await settle(tester);
  return (service: service, launcher: launcher);
}

/// A few frames: the page's shimmers never settle.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}
