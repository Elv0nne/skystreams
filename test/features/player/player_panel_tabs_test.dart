import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_files_tab.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_sources_tab.dart';
import 'package:skystream/features/player/presentation/vlc/torrent_file_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'fake_vlc_engine.dart';

/// Which tabs exist, and which one is on screen when the data keeps changing
/// its mind. Two facts live here that player_panel_test.dart does not pin:
///
///   * [availablePanelTabs] at its thresholds. The helper is shared by the
///     panel strip and the bottom bar precisely so a button can never open a
///     tab that is not there, and both of its `> 1` cuts - one episode is a
///     film, one file is not a pack - are boundaries nothing else asserts.
///   * A tab press that lands on the tab live data substituted in. That press
///     is the one the panel used to drop, so the tab it had taken away came
///     back and pulled the viewer - and, on a remote, the focus - with it.
const Size _tv = Size(2560, 1440);

/// A snapshot that moves nothing but keeps the controller's stall watchdog
/// unarmed: a playing snapshot leaves a 1 s timer pending, and flutter_test
/// checks pending timers before any tear-down runs.
const Map<String, Object?> _paused = <String, Object?>{'state': 'paused'};

List<StreamResult> _sources() => <StreamResult>[
  const StreamResult(
    url: 'https://a.test/one',
    source: '1080p',
    providerName: 'Torrentio',
  ),
  const StreamResult(
    url: 'https://b.test/two',
    source: '720p',
    providerName: 'Vidsrc',
  ),
];

/// Server ids 3, 7, 11, ... - the ids a filtered pack really has, none of them
/// a list position.
List<TorrentFile> _packFiles(int count) => List<TorrentFile>.generate(
  count,
  (i) => TorrentFile(
    index: 3 + 4 * i,
    name: 'Pack.S01E${(i + 1).toString().padLeft(2, '0')}.mkv',
    sizeBytes: 700 * 1024 * 1024,
  ),
);

Episode _episode(int number) => Episode(
  name: 'Episode $number',
  url: 'https://series.test/$number',
  season: 1,
  episode: number,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('availablePanelTabs', () {
    Set<PlayerPanelTab> tabs({
      int sourceCount = 0,
      int episodeCount = 0,
      int fileCount = 0,
      int qualityCount = 0,
    }) => availablePanelTabs(
      sourceCount: sourceCount,
      episodeCount: episodeCount,
      fileCount: fileCount,
      qualityCount: qualityCount,
    );

    test('Audio and Subtitles are there with nothing else at all', () {
      expect(tabs(), <PlayerPanelTab>{
        PlayerPanelTab.audio,
        PlayerPanelTab.subtitles,
      });
    });

    test('one source is a source list: the tab is a chance to fail over', () {
      expect(tabs(sourceCount: 0), isNot(contains(PlayerPanelTab.sources)));
      expect(tabs(sourceCount: 1), contains(PlayerPanelTab.sources));
      expect(tabs(sourceCount: 2), contains(PlayerPanelTab.sources));
    });

    test('one episode is a film, so no Episodes tab', () {
      expect(tabs(episodeCount: 0), isNot(contains(PlayerPanelTab.episodes)));
      expect(
        tabs(episodeCount: 1),
        isNot(contains(PlayerPanelTab.episodes)),
        reason: 'a one-row Episodes list is a dead D-pad stop',
      );
      expect(tabs(episodeCount: 2), contains(PlayerPanelTab.episodes));
    });

    test('one file is not a pack, so no Files tab', () {
      expect(tabs(fileCount: 0), isNot(contains(PlayerPanelTab.files)));
      expect(
        tabs(fileCount: 1),
        isNot(contains(PlayerPanelTab.files)),
        reason: 'a one-row Files list is a dead D-pad stop',
      );
      expect(tabs(fileCount: 2), contains(PlayerPanelTab.files));
    });

    test('one quality is not a choice, so no Quality tab', () {
      expect(tabs(sourceCount: 1), isNot(contains(PlayerPanelTab.quality)));
      expect(
        tabs(sourceCount: 1, qualityCount: 1),
        isNot(contains(PlayerPanelTab.quality)),
        reason: 'a one-row Quality list is a dead D-pad stop',
      );
      expect(
        tabs(sourceCount: 1, qualityCount: 2),
        contains(PlayerPanelTab.quality),
      );
    });

    test('Quality comes right after Sources', () {
      expect(PlayerPanelTab.values.take(2), [
        PlayerPanelTab.sources,
        PlayerPanelTab.quality,
      ]);
    });

    test('the boundaries are the same ones PanelData reads', () {
      // The panel strip and the bottom bar both come through this getter, so
      // the thresholds have to hold on the value type too.
      expect(
        PanelData(
          episodes: <Episode>[_episode(1)],
          files: _packFiles(1),
          qualityLadder: const <int>[720],
        ).tabs,
        <PlayerPanelTab>{PlayerPanelTab.audio, PlayerPanelTab.subtitles},
      );
      expect(
        PanelData(
          sources: _sources().take(1).toList(),
          episodes: <Episode>[_episode(1), _episode(2)],
          files: _packFiles(2),
          qualityLadder: const <int>[1080, 720],
        ).tabs,
        PlayerPanelTab.values.toSet(),
      );
    });
  });

  group('a tab press after live data substituted a tab', () {
    /// Opens the panel over a bare host page on the Files tab and hands back
    /// the notifier the screen publishes through.
    Future<ValueNotifier<PanelData>> pumpFilesPanel(WidgetTester tester) async {
      tester.view.physicalSize = _tv;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final fake = FakeVlcEngine();
      fake.install();
      // Tear-downs run last-in first-out: the controller goes first, while the
      // channel it sends `dispose` on still has a handler.
      addTearDown(fake.dispose);
      final controller = await fake.attach();
      addTearDown(controller.dispose);
      await fake.emit(_paused);

      final data = ValueNotifier<PanelData>(
        PanelData(
          sources: _sources(),
          currentSourceIndex: 0,
          files: _packFiles(3),
          currentFileIndex: 7,
        ),
      );
      addTearDown(data.dispose);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              backgroundColor: Colors.black,
              body: Center(
                child: GestureDetector(
                  onTap: () => showPlayerPanel(
                    context,
                    controller: controller,
                    initialTab: PlayerPanelTab.files,
                    isTv: true,
                    focusOnOpen: true,
                    data: data,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerFilesTab), findsOneWidget);
      return data;
    }

    testWidgets('pressing the substituted-in tab makes it the viewer\'s', (
      tester,
    ) async {
      // A torrent poll that lists one file for a moment - an episode advance,
      // a pack still being read - takes the Files tab away and the panel
      // substitutes the first tab left. The viewer presses Sources to confirm
      // where they are. When the files come back, that press has to hold: the
      // panel switching itself to Files would move the highlight on a remote.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final data = await pumpFilesPanel(tester);

      data.value = data.value.copyWith(
        files: _packFiles(1),
        currentFileIndex: 3,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSourcesTab), findsOneWidget);
      expect(find.text(l10n.playerFiles), findsNothing, reason: 'no such tab');

      await tester.tap(find.text(l10n.sources));
      await tester.pumpAndSettle();

      data.value = data.value.copyWith(
        files: _packFiles(3),
        currentFileIndex: 7,
      );
      await tester.pumpAndSettle();

      expect(
        find.text(l10n.playerFiles),
        findsOneWidget,
        reason: 'tab is back',
      );
      expect(
        find.byType(PlayerFilesTab),
        findsNothing,
        reason: 'the viewer chose Sources; the data does not overrule them',
      );
      expect(find.byType(PlayerSourcesTab), findsOneWidget);
    });

    testWidgets('a substituted tab still comes back if it was not pressed', (
      tester,
    ) async {
      // The other half of the same rule, so the fix cannot be "never restore":
      // with no press in between, the viewer's own tab returns with the data.
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      final data = await pumpFilesPanel(tester);

      data.value = data.value.copyWith(
        files: _packFiles(1),
        currentFileIndex: 3,
      );
      await tester.pumpAndSettle();
      expect(find.byType(PlayerSourcesTab), findsOneWidget);

      data.value = data.value.copyWith(
        files: _packFiles(3),
        currentFileIndex: 7,
      );
      await tester.pumpAndSettle();

      expect(find.byType(PlayerFilesTab), findsOneWidget);
      expect(find.text(l10n.playerFiles), findsOneWidget);
    });
  });
}
