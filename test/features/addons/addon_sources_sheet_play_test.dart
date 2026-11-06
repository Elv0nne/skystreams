/// A link picked in the Stremio sources sheet plays with its add-on named on
/// the item (Stremio direct play): the player asks that add-on for the next
/// episode, as Stremio itself goes on with the add-on a show started on. The
/// add-on that described the title stays named too: Continue Watching reopens
/// the title through it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/data/addon_stream_service.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart'
    show kAddonItemSource;
import 'package:skystream/core/addons/models/addon_stream_source.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/addons/presentation/addon_sources_sheet.dart';
import 'package:skystream/features/details/presentation/playback_launcher.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const _torrentioUrl = 'https://torrentio.test/config/manifest.json';
const _cinemetaUrl = 'https://cinemeta.test/manifest.json';

class _Service implements AddonStreamService {
  @override
  Stream<AddonStreamProgress> resolve({
    required List<dynamic> addons,
    required AddonStreamRequest request,
    bool forceRefresh = false,
    dynamic cancelToken,
    bool personWaiting = false,
    Set<String>? only,
  }) async* {
    yield const AddonStreamProgress(
      streams: [
        AddonStreamSource(
          addonId: 'com.torrentio',
          addonName: 'Torrentio',
          name: 'Torrentio 1080p',
          title: 'Show S01E02',
          url: 'https://cdn.test/s1e2.mkv',
        ),
      ],
      completedCount: 1,
      totalCount: 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    addons: [
      ManagedAddon(
        manifestUrl: _torrentioUrl,
        addedAt: DateTime(2026),
        manifest: AddonManifest.fromJson({
          'id': 'com.torrentio',
          'name': 'Torrentio',
          'version': '1.0.0',
          'types': ['movie', 'series'],
          'idPrefixes': ['tt'],
          'resources': ['stream'],
        }),
      ),
    ],
    isLoading: false,
  );
}

class _Probe implements LinkProbeService {
  @override
  Future<LinkProbeResult> probe(String url, {Map<String, String>? headers}) =>
      Future.value(const LinkProbeResult(reachable: true));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Launcher implements PlaybackLauncher {
  final played = <({MultimediaItem item, String videoUrl})>[];

  @override
  Future<void> playResolved(
    BuildContext context, {
    required MultimediaItem item,
    required String videoUrl,
    Episode? episode,
    List<StreamResult> streams = const <StreamResult>[],
  }) async {
    played.add((item: item, videoUrl: videoUrl));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets("a picked link's add-on and type go to the player with it", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final launcher = _Launcher();
    // Described by Cinemeta, which serves no links.
    final show = MultimediaItem(
      title: 'Show',
      url: 'tt0944947',
      posterUrl: '',
      contentType: MultimediaContentType.series,
      source: kAddonItemSource,
      addonUrl: _cinemetaUrl,
      addonType: 'series',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          addonStreamServiceProvider.overrideWithValue(_Service()),
          addonRepositoryProvider.overrideWith(_Repo.new),
          linkProbeServiceProvider.overrideWithValue(_Probe()),
          playbackLauncherProvider.overrideWithValue(launcher),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.createDarkTheme(null),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => AddonSourcesSheet.open(
                context,
                item: show,
                request: const AddonStreamRequest(
                  type: 'series',
                  contentId: 'tt0944947',
                  videoId: 'tt0944947:1:2',
                  season: 1,
                  episode: 2,
                ),
                episode: Episode(
                  name: 'Two',
                  url: 'tt0944947:1:2',
                  season: 1,
                  episode: 2,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Play').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final played = launcher.played.single;
    expect(played.videoUrl, 'tt0944947:1:2');
    expect(
      played.item.addonUrl,
      _cinemetaUrl,
      reason:
          'Continue Watching reopens it through the add-on that described '
          'it',
    );
    expect(
      played.item.streamAddonUrl,
      _torrentioUrl,
      reason:
          'the player asks the add-on whose link plays for the next '
          'episode',
    );
    expect(played.item.addonType, 'series');
  });
}
