/// Stremio direct play, end to end on a real platform: an add-on that serves
/// a catalog, its titles' meta and their links - the shape of CNCVerse Bridge
/// - installed; a show's page opened; Play pressed; the episode playing, and
/// the next one following from the same add-on; an episode card and a movie's
/// Play too; then the show's Continue Watching row, which keeps its add-on and
/// reopens the show's page (tapped on Home when a provider is active there:
/// Home shows Continue Watching only then).
///
/// The add-on is a fake this test serves itself, on loopback inside the app.
/// The video is any short clip, by URL:
///
/// ```
/// flutter test integration_test/stremio/direct_play_test.dart -d DEVICE \
///   --dart-define=STREMIO_TEST_CLIP=http://HOST:PORT/clip.mp4
/// ```
///
/// A clip of 35 to 60 seconds brings the next episode quickly: the player
/// records progress, and so offers and plays the next episode, only for a
/// video of 30 seconds or more. Lines starting `STREMIO-PLAY` report
/// progress.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_meta.dart'
    show kAddonItemSource;
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/core/storage/episode_watch_repository.dart';
import 'package:skystream/features/home/presentation/widgets/continue_watching_card.dart';
import 'package:skystream/features/library/presentation/history_provider.dart';
import 'package:skystream/shared/widgets/custom_widgets.dart';
import 'package:vlc_player/vlc_player.dart';

import '../cloudstream/support.dart';

const _clip = String.fromEnvironment('STREMIO_TEST_CLIP');

/// A Stremio add-on with a catalog, meta and links, on loopback: a movie and
/// a two-episode show, both published as `other` the way CNCVerse publishes
/// them. Every link is the clip, after a donation link that only opens
/// elsewhere, as CNCVerse's answers start. Notes each id it is asked links
/// for.
class _FakeBridge {
  late final HttpServer _server;
  final streamsAsked = <String>[];

  String get manifestUrl => 'http://127.0.0.1:${_server.port}/manifest.json';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  static const _manifest = {
    'id': 'test.stremio.bridge',
    'name': 'Test Bridge',
    'version': '1.0.0',
    'description': 'Catalog, meta and links, like CNCVerse Bridge.',
    'types': ['movie', 'series', 'other'],
    'idPrefixes': ['tsb:'],
    'resources': ['catalog', 'meta', 'stream'],
    'catalogs': [
      {'type': 'other', 'id': 'tsb_all', 'name': 'Test Bridge'},
    ],
  };

  static const _movie = {
    'id': 'tsb:movie',
    'type': 'other',
    'name': 'Bridge Movie',
    'description': 'A film the add-on describes and links.',
    'releaseInfo': '2026',
  };

  static const _show = {
    'id': 'tsb:show',
    'type': 'other',
    'name': 'Bridge Show',
    'description': 'A show the add-on publishes as other.',
    'releaseInfo': '2026',
    'videos': [
      {'id': 'tsb:show:e1', 'title': 'First', 'season': 1, 'episode': 1},
      {'id': 'tsb:show:e2', 'title': 'Second', 'season': 1, 'episode': 2},
    ],
  };

  void _handle(HttpRequest request) {
    final path = Uri.decodeComponent(request.uri.path);
    Object? body;
    if (path == '/manifest.json') {
      body = _manifest;
    } else if (path.startsWith('/catalog/')) {
      body = {
        'metas': [_movie, _show],
      };
    } else if (path == '/meta/other/tsb:movie.json') {
      body = {'meta': _movie};
    } else if (path == '/meta/other/tsb:show.json') {
      body = {'meta': _show};
    } else if (path.startsWith('/stream/other/') && path.endsWith('.json')) {
      final id = path.substring(
        '/stream/other/'.length,
        path.length - '.json'.length,
      );
      streamsAsked.add(id);
      body = {
        'streams': [
          {
            'name': 'Support',
            'title': 'Donate to the project',
            'externalUrl': 'https://example.com/',
          },
          {'name': 'Test Bridge', 'title': 'Auto • $id', 'url': _clip},
        ],
      };
    }
    request.response.headers.contentType = ContentType.json;
    if (body == null) {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.write(jsonEncode(body));
    }
    request.response.close();
  }
}

/// The page's Play button labelled [label], once it is there.
Finder _play(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(CustomButton));

/// Waits for the player to be playing between [from] and [to] into the
/// video, and returns its controller.
Future<VlcPlayerController> _playing(
  WidgetTester tester,
  void Function(String) step,
  String what, {
  Duration from = const Duration(seconds: 3),
  Duration to = const Duration(hours: 1),
}) async {
  await waitFor(
    tester,
    find.byType(VlcPlayer),
    timeout: const Duration(minutes: 2),
  );
  late VlcPlayerController controller;
  await pumpUntil(
    tester,
    () {
      final players = find.byType(VlcPlayer).evaluate();
      if (players.isEmpty) return false;
      controller = (players.first.widget as VlcPlayer).controller;
      final v = controller.value;
      return v.state == VlcPlaybackState.playing &&
          v.position > from &&
          v.position < to;
    },
    what: '$what playing',
    timeout: const Duration(minutes: 2),
  );
  step('$what PLAYING at ${controller.value.position.inSeconds}s');
  return controller;
}

/// Leaves the player the way a user does: the bars, then Back.
Future<void> _leave(WidgetTester tester) async {
  if (find.byTooltip('Back').hitTestable().evaluate().isEmpty) {
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    await tester.tapAt(Offset(screen.width / 2, screen.height / 3));
    await pumpUntil(
      tester,
      () => find.byTooltip('Back').hitTestable().evaluate().isNotEmpty,
      what: "the player's bars",
      timeout: const Duration(seconds: 5),
    );
  }
  await tester.pageBack();
  await pumpUntil(
    tester,
    () => find.byType(VlcPlayer).evaluate().isEmpty,
    what: 'the player to close',
    timeout: const Duration(seconds: 20),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a Stremio title whose add-on brings its links plays from its page, '
      'and the next episode follows from the same add-on', (tester) async {
    final started = DateTime.now();
    void step(String message) => print(
      'STREMIO-PLAY ${DateTime.now().difference(started).inSeconds}s $message',
    );
    final bridge = _FakeBridge();
    await bridge.start();
    addTearDown(bridge.stop);

    await withApp(tester, (container) async {
      final addons = container.read(addonRepositoryProvider.notifier);
      // A run stopped half-way left its add-on installed, on a port long
      // gone.
      for (final stale in container.read(addonRepositoryProvider).addons) {
        if (stale.id == 'test.stremio.bridge') {
          await whilePumping(tester, addons.remove(stale.manifestUrl));
        }
      }
      // And left its titles in history, with the show's first episode marked
      // watched: the show's Play would offer the episode that run stopped at.
      final history = container.read(watchHistoryProvider.notifier);
      for (final id in ['tsb:show', 'tsb:movie']) {
        await whilePumping(tester, history.removeFromHistory(id));
      }
      await whilePumping(
        tester,
        container.read(episodeWatchRepositoryProvider).setManyWatched(
          'tsb:show',
          [
            Episode(name: 'First', url: 'tsb:show:e1', season: 1, episode: 1),
            Episode(name: 'Second', url: 'tsb:show:e2', season: 1, episode: 2),
          ],
          false,
        ),
      );
      await whilePumping(tester, addons.install(bridge.manifestUrl));
      step('installed ${bridge.manifestUrl}');
      try {
        // A show: Play plays its first episode from the add-on, and the
        // player goes on to the second from the same add-on.
        go(
          tester,
          AddonDetailRoute(
            type: 'other',
            id: 'tsb:show',
            addonUrl: bridge.manifestUrl,
          ).location,
        );
        await waitFor(tester, _play('Play E1'));
        step('show page: Play E1');
        await tester.tap(_play('Play E1').first);
        await _playing(tester, step, 'E1');
        await pumpUntil(
          tester,
          () => bridge.streamsAsked.contains('tsb:show:e2'),
          what: 'the next episode asked of the add-on',
          timeout: const Duration(minutes: 2),
        );
        step('next episode asked: ${bridge.streamsAsked}');
        await _playing(
          tester,
          step,
          'E2 (next episode)',
          to: const Duration(seconds: 15),
        );
        await _leave(tester);

        // An episode card plays straight from the add-on too.
        final second = find.text('2. SECOND');
        await waitFor(tester, second);
        await reveal(tester, second);
        await tester.tap(second.first);
        await _playing(tester, step, 'E2 (card)');
        await _leave(tester);

        // A movie: Play.
        go(
          tester,
          AddonDetailRoute(
            type: 'other',
            id: 'tsb:movie',
            addonUrl: bridge.manifestUrl,
          ).location,
        );
        await waitFor(tester, _play('Play'));
        step('movie page: Play');
        await tester.tap(_play('Play').first);
        await _playing(tester, step, 'movie');
        await _leave(tester);

        // Continue Watching: the show's row, read back from history, keeps
        // the add-on it came from and the type it published, and reopens
        // the show's page through them.
        final row = container
            .read(watchHistoryProvider)
            .firstWhere((h) => h.item.url == 'tsb:show');
        expect(row.item.source, kAddonItemSource);
        expect(row.item.addonUrl, bridge.manifestUrl);
        expect(row.item.addonType, 'other');
        step("history keeps the show's add-on and type");
        if (container.read(activeProviderProvider) == null) {
          step('no provider on Home, so no Continue Watching row to tap');
        } else {
          go(tester, const HomeRoute().location);
          final card = find.widgetWithText(ContinueWatchingCard, 'Bridge Show');
          await waitFor(tester, card);
          await reveal(tester, card);
          await tester.tap(card.first);
          final again = find.byWidgetPredicate(
            (w) =>
                w is Text &&
                RegExp(r'^(Play|Resume) E2$').hasMatch(w.data ?? ''),
          );
          await waitFor(tester, again);
          step(
            'Continue Watching reopened the show: '
            '"${tester.widget<Text>(again.first).data}"',
          );
        }
        step('RESULT passed, links asked for ${bridge.streamsAsked}');
      } finally {
        await whilePumping(tester, addons.remove(bridge.manifestUrl));
        step('removed the add-on');
      }
    });
  }, skip: _clip.isEmpty);
}
