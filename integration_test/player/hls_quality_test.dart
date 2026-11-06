/// Choosing an HLS stream's quality on a real platform:
///  * the player's Quality tab over Mux's test stream (audio muxed into each
///    variant) and Apple's (audio a separate rendition);
///  * Auto under a 480p preference;
///  * CloudStream extensions measured to hand out multi-quality masters
///    (docs/superpowers/research/2026-10-12-hls-quality): ARD (audio muxed,
///    labelled 1080), Arte (audio separate, labelled 720), IPTV-Org and
///    TVGarden (live, audio separate, no quality of their own) and AnimeUnity
///    (muxed, no quality of its own).
///
/// ```
/// flutter test integration_test/player/hls_quality_test.dart -d DEVICE \
///   --dart-define=HLS_QUALITY_E2E=true \
///   [--dart-define=CS3_E2E=true] [--dart-define=HLS_QUALITY_TV=true]
/// ```
///
/// HLS_QUALITY_TV moves through the panel with a remote's keys instead of
/// taps. Each test prints one `HLS-QUALITY {json}` line: the rows the tab
/// listed, the picture's height after each pick, and the audio tracks.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/router/app_router.dart';
import 'package:skystream/features/player/domain/hls_quality.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import '../cloudstream/support.dart';

const _run = bool.fromEnvironment('HLS_QUALITY_E2E');
const _tv = bool.fromEnvironment('HLS_QUALITY_TV');

/// Mux's test stream: five heights, audio muxed into each.
const _mux = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

/// Apple's advanced sample: six heights, audio in three separate renditions.
const _apple =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8';

/// The CloudStream repositories the measured extensions come from.
const _germanProviders =
    'https://raw.githubusercontent.com/Bnyro/GermanProviders/builds/plugins.json';
const _csKarma =
    'https://raw.githubusercontent.com/Kraptor123/Cs-Karma/builds/plugins.json';
const _italiaInStreaming =
    'https://raw.githubusercontent.com/DieGon7771/ItaliaInStreaming/builds/plugins.json';

/// The extensions, and what the research searched each for.
const _extensions = <({String name, String repository, String query})>[
  (name: 'ARD', repository: _germanProviders, query: 'news'),
  (name: 'Arte', repository: _germanProviders, query: 'batman'),
  (name: 'IptvOrg', repository: _germanProviders, query: 'news'),
  (name: 'TVGarden', repository: _csKarma, query: 'news'),
  (name: 'AnimeUnity', repository: _italiaInStreaming, query: 'One Piece'),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Mux, audio muxed: each pick plays its height, with sound',
    skip: !_run,
    (tester) async {
      await withApp(tester, (container) async {
        final l10n = _l10n(tester);
        final controller = await _open(tester, _direct(_mux));
        final rows = await _qualityRows(tester, l10n);
        expect(rows.skip(1), ['1080p', '720p', '480p', '288p', '184p']);
        final report = <String, Object?>{'stream': 'mux', 'rows': rows};
        for (final (row, height) in const [('480p', 480), ('288p', 288)]) {
          await _pick(tester, l10n, row);
          await _waitForHeight(tester, controller, height, _ladderOf(rows));
          report[row] = await _audio(tester, controller);
        }
        await _pick(tester, l10n, l10n.playerQualityAuto);
        await pumpUntil(
          tester,
          () => (controller.value.videoSize?.height ?? 0) > 288,
          what: 'Auto above the last pick',
        );
        report['auto'] = controller.value.videoSize?.height;
        print('HLS-QUALITY ${asciiJson(report)}');
        await _leave(tester);
      });
    },
  );

  testWidgets('Apple, audio separate: a pick keeps the audio', skip: !_run, (
    tester,
  ) async {
    await withApp(tester, (container) async {
      final l10n = _l10n(tester);
      final controller = await _open(tester, _direct(_apple));
      final rows = await _qualityRows(tester, l10n);
      expect(rows.skip(1), ['1080p', '720p', '540p', '432p', '360p', '270p']);
      await _pick(tester, l10n, '540p');
      await _waitForHeight(tester, controller, 540, _ladderOf(rows));
      final audio = await _audio(tester, controller);
      expect(
        audio['tracks'],
        greaterThanOrEqualTo(1),
        reason: 'a split 540p link would be silent; the master keeps its audio',
      );
      print(
        'HLS-QUALITY ${asciiJson({'stream': 'apple', 'rows': rows, '540p': audio})}',
      );
      await _leave(tester);
    });
  });

  testWidgets(
    'Auto under a 480p preference, in a new player that starts on Auto',
    skip: !_run,
    (tester) async {
      await withApp(tester, (container) async {
        final l10n = _l10n(tester);
        final settings = container.read(playerSettingsProvider.notifier);
        final before = container.read(playerSettingsProvider).requireValue;
        await tester.runAsync(() async {
          await settings.setWifiQuality(QualityPreference.q480);
          await settings.setMobileQuality(QualityPreference.q480);
        });
        try {
          final controller = await _open(tester, _direct(_mux));
          await _waitForHeight(tester, controller, 480, const [
            1080,
            720,
            480,
            288,
            184,
          ]);
          await _openQualityTab(tester, l10n);
          final ticked = [
            for (final row in tester.widgetList<PanelRow>(
              find.byType(PanelRow),
            ))
              if (row.selected) row.label,
          ];
          expect(ticked.single, startsWith(l10n.playerQualityAuto));
          await tester.binding.handlePopRoute();
          await pumpFor(tester, const Duration(milliseconds: 600));
          print(
            'HLS-QUALITY ${asciiJson({'stream': 'mux', 'preference': 480, 'height': controller.value.videoSize?.height, 'ticked': ticked})}',
          );
          await _leave(tester);
        } finally {
          await tester.runAsync(() async {
            await settings.setWifiQuality(before.wifiQuality);
            await settings.setMobileQuality(before.mobileQuality);
          });
        }
      });
    },
  );

  testWidgets(
    "CloudStream extensions' masters",
    skip: !(_run && cloudStreamTests),
    (tester) async {
      await withApp(tester, (container) async {
        final l10n = _l10n(tester);
        final changes = await CloudStreamChanges.note(tester, container);
        final played = <String>[];
        try {
          for (final extension in _extensions) {
            final report = <String, Object?>{'extension': extension.name};
            // What a site offers today is the site's business: no links, a
            // channel that is down or a link with one height skip to the next
            // link. What the player does with a link that offers a choice is
            // ours, and a failure there fails the test.
            List<StreamResult> links;
            try {
              links = await _hlsLinks(tester, container, extension);
            } catch (e) {
              report['error'] = '$e'.split('\n').first;
              print('HLS-QUALITY ${asciiJson(report)}');
              continue;
            }
            report['links'] = links.length;
            report['adaptive'] = links
                .where((link) => link.quality == 0)
                .length;
            for (final link in links.take(3)) {
              VlcPlayerController controller;
              List<String> rows;
              try {
                controller = await _open(
                  tester,
                  MultimediaItem(
                    title: extension.name,
                    url: link.url,
                    posterUrl: '',
                  ),
                  streams: [link],
                );
                rows = await _qualityRows(tester, l10n);
              } on TestFailure catch (e) {
                report['skipped'] =
                    '${report['skipped'] ?? ''}${'$e'.split('\n').first}; ';
                await _leave(tester);
                continue;
              }
              if (rows.length < 3) {
                report['skipped'] = '${report['skipped'] ?? ''}rows $rows; ';
                await _leave(tester);
                continue;
              }
              final lowest = rows.last;
              await _pick(tester, l10n, lowest);
              await _waitForHeight(
                tester,
                controller,
                _heightOf(lowest),
                _ladderOf(rows),
              );
              final audio = await _audio(tester, controller);
              expect(
                audio['tracks'],
                greaterThanOrEqualTo(1),
                reason: '${extension.name}: the master keeps its audio',
              );
              report['rows'] = rows;
              report[lowest] = audio;
              played.add(extension.name);
              await _leave(tester);
              break;
            }
            print('HLS-QUALITY ${asciiJson(report)}');
          }
        } finally {
          await changes.undo(tester, container);
        }
        expect(
          played.length,
          greaterThanOrEqualTo(2),
          reason: 'extensions that offered a choice today: $played',
        );
      });
    },
  );
}

/// [extension]'s HLS links: installed from its repository, searched for its
/// query, and each of the first titles' first episode asked for links until
/// three are in hand.
Future<List<StreamResult>> _hlsLinks(
  WidgetTester tester,
  ProviderContainer container,
  ({String name, String repository, String query}) extension,
) async {
  await ensureInstalled(
    tester,
    container,
    repository: extension.repository,
    internalName: extension.name,
  );
  final plugin = container
      .read(cloudStreamRepositoryProvider)
      .installed
      .firstWhere((p) => p.info.internalName == extension.name);
  final provider = CloudStreamProvider(
    plugin: plugin,
    pluginKey: CloudStreamRepository.keyOf(plugin.info),
    info: plugin.providers.first,
    host: container.read(cloudStreamEngineHostProvider),
  );
  final links = <StreamResult>[];
  await tester.runAsync(() async {
    for (final item in (await provider.search(extension.query)).take(4)) {
      try {
        final details = await provider.getDetails(item.url);
        final episode = details.episodes?.firstOrNull;
        if (episode == null) continue;
        links.addAll(
          (await provider.loadStreams(episode.url)).where(
            (s) => s.quality == 0 || s.url.toLowerCase().contains('.m3u8'),
          ),
        );
      } catch (_) {
        continue;
      }
      if (links.length >= 3) return;
    }
  });
  return links;
}

/// The height a Quality row names.
int _heightOf(String label) => switch (label) {
  '4K' => 2160,
  '2K' => 1440,
  _ => int.parse(label.replaceAll('p', '')),
};

/// The app's own strings, in whatever language it is running in.
AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first))!;

MultimediaItem _direct(String url) => MultimediaItem(
  title: 'HLS quality',
  url: url,
  posterUrl: '',
  provider: 'Remote',
);

/// Opens the player on [item] - its own address, or [streams] when given -
/// and waits for its picture and the Quality tab's read.
Future<VlcPlayerController> _open(
  WidgetTester tester,
  MultimediaItem item, {
  List<StreamResult>? streams,
}) async {
  unawaited(
    PlayerRoute(
      $extra: PlayerRouteExtra(
        item: item,
        videoUrl: item.url,
        preloadedStreams: streams,
      ),
    ).push<void>(tester.element(find.byType(Scaffold).first)),
  );
  await waitFor(tester, find.byType(VlcPlayer));
  final controller = tester
      .widget<VlcPlayer>(find.byType(VlcPlayer))
      .controller;
  await pumpUntil(
    tester,
    () =>
        controller.value.videoSize != null &&
        controller.value.position > Duration.zero,
    what: 'a picture',
    timeout: const Duration(minutes: 1),
  );
  await pumpFor(tester, const Duration(seconds: 3));
  return controller;
}

/// Options, then the Quality tab: taps, or a remote's keys in the panel.
Future<void> _openQualityTab(WidgetTester tester, AppLocalizations l10n) async {
  // Hidden bars stay mounted, at no opacity and behind an IgnorePointer: only
  // an Options button that answers a tap is one a viewer can press.
  final options = find.byTooltip(l10n.options).hitTestable();
  if (options.evaluate().isEmpty) {
    // The bars come up for a tap on the picture, or Select on a remote.
    if (_tv) {
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
    } else {
      await tester.tapAt(tester.getCenter(find.byType(VlcPlayer)));
    }
    await waitFor(tester, options, timeout: const Duration(seconds: 10));
  }
  await tester.tap(options);
  await waitFor(
    tester,
    find.byType(PlayerPanel),
    timeout: const Duration(seconds: 10),
  );
  await pumpFor(tester, const Duration(milliseconds: 600));
  if (_tv) {
    // The panel opens focused on the playing source. Up reaches the tab
    // strip, Left walks it to Sources, Right to Quality, and Select opens it.
    final tabs = {
      l10n.sources,
      l10n.playerQuality,
      l10n.audio,
      l10n.subtitles,
      l10n.episodes,
      l10n.playerFiles,
    };
    for (var i = 0; i < 6 && !tabs.contains(_focusedText()); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await pumpFor(tester, const Duration(milliseconds: 300));
    }
    await _keyTo(tester, LogicalKeyboardKey.arrowLeft, l10n.sources);
    await _keyTo(tester, LogicalKeyboardKey.arrowRight, l10n.playerQuality);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
  } else {
    final quality = find.text(l10n.playerQuality);
    if (quality.evaluate().isEmpty) throw TestFailure('no Quality tab');
    await tester.tap(quality);
  }
  await pumpFor(tester, const Duration(milliseconds: 600));
}

/// The Quality tab's rows, Auto's first; the panel closed again after.
Future<List<String>> _qualityRows(
  WidgetTester tester,
  AppLocalizations l10n,
) async {
  await _openQualityTab(tester, l10n);
  final rows = [
    for (final row in tester.widgetList<PanelRow>(
      find.byType(PanelRow, skipOffstage: false),
    ))
      row.label,
  ];
  await tester.binding.handlePopRoute();
  await pumpFor(tester, const Duration(milliseconds: 600));
  return rows;
}

/// Picks [row] in the Quality tab: a tap, or the remote's Down and Select.
Future<void> _pick(
  WidgetTester tester,
  AppLocalizations l10n,
  String row,
) async {
  await _openQualityTab(tester, l10n);
  if (_tv) {
    await _keyTo(tester, LogicalKeyboardKey.arrowDown, row);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
  } else {
    // A phone's panel can be shorter than the list.
    final target = find.widgetWithText(PanelRow, row);
    await tester.ensureVisible(target);
    await pumpFor(tester, const Duration(milliseconds: 300));
    await tester.tap(target);
  }
  // The panel slides away in a quarter of a second, longer on a television
  // emulator busy decoding: waited for, not timed.
  await pumpUntil(
    tester,
    () => find.byType(PlayerPanel).evaluate().isEmpty,
    what: 'a pick to close the panel',
    timeout: const Duration(seconds: 10),
  );
}

/// The text of what has focus: a row's label, a tab's name.
String? _focusedText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context is! Element) return null;
  String? text;
  void visit(Element element) {
    if (text != null) return;
    final widget = element.widget;
    if (widget is Text && widget.data != null) {
      text = widget.data;
      return;
    }
    element.visitChildren(visit);
  }

  context.visitChildren(visit);
  return text;
}

/// Presses [key] until [wanted] has focus, as a remote would.
Future<void> _keyTo(
  WidgetTester tester,
  LogicalKeyboardKey key,
  String wanted,
) async {
  for (var i = 0; i < 12 && _focusedText() != wanted; i++) {
    await tester.sendKeyEvent(key);
    await pumpFor(tester, const Duration(milliseconds: 300));
  }
  expect(_focusedText(), wanted, reason: 'a remote reaches "$wanted"');
}

/// The heights the Quality tab's [rows] list, Auto's row aside.
List<int> _ladderOf(List<String> rows) => [
  for (final row in rows.skip(1)) _heightOf(row),
];

/// Waits until the picture plays [ladder]'s [height], read as the player
/// reads it: the ladder height nearest the picture's. Windows and Linux can
/// publish the decoder's padded buffer instead of the picture - for H.264 the
/// height aligned to 32 lines, plus 2: 290 for 270, 738 for 720 - so exact
/// pixels would fail a picture that is right. A neighbouring rung is never
/// that near.
Future<void> _waitForHeight(
  WidgetTester tester,
  VlcPlayerController controller,
  int height,
  List<int> ladder,
) async {
  try {
    await pumpUntil(
      tester,
      () =>
          nearestLadderHeight(controller.value.videoSize?.height, ladder) ==
          height,
      what: 'the ${height}p picture',
      timeout: const Duration(minutes: 1),
    );
  } on TestFailure catch (e) {
    // Says what plays instead, which the screen's text does not.
    throw TestFailure(
      '${e.message} The picture: ${controller.value.videoSize}.',
    );
  }
}

/// The audio the engine lists for what plays now, Disable aside, and the
/// track that is on.
Future<Map<String, Object?>> _audio(
  WidgetTester tester,
  VlcPlayerController controller,
) async {
  await pumpUntil(
    tester,
    () => controller.value.activeAudioTrackId != null,
    what: 'an audio track on',
    timeout: const Duration(seconds: 30),
  );
  final tracks = await whilePumping(tester, controller.getAudioTracks());
  return {
    'tracks': tracks.where((t) => t.id >= 0).length,
    'on': controller.value.activeAudioTrackId,
  };
}

/// Back out of the player: the first Back can be spent putting the bars away.
Future<void> _leave(WidgetTester tester) async {
  for (var i = 0; i < 3 && find.byType(VlcPlayer).evaluate().isNotEmpty; i++) {
    await tester.binding.handlePopRoute();
    await pumpFor(tester, const Duration(seconds: 1));
  }
}
