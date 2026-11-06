import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/torrent_file_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'fake_vlc_engine.dart';

/// The Quality tab: Auto and the heights an HLS stream offers, the row in
/// effect ticked, a pick reported with the panel closed, and a remote that
/// lands on the ticked row.
const Size _tv = Size(2560, 1440);

/// A 1080p television at the density Android TV reports.
const Size _googleTv = Size(960, 540);

/// A snapshot that keeps the controller's stall watchdog unarmed.
const Map<String, Object?> _paused = <String, Object?>{'state': 'paused'};

const StreamResult _master = StreamResult(
  url: 'https://cdn.test/master.m3u8',
  source: 'Server',
  providerName: 'A',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Opens the panel over a bare page and hands back the engine, the data
  /// the screen would publish, and the picks the panel reported.
  Future<
    ({FakeVlcEngine engine, ValueNotifier<PanelData> data, List<int?> picks})
  >
  open(
    WidgetTester tester, {
    PanelData? data,
    List<int> ladder = const [1080, 720, 480],
    int? pick,
    bool isTv = false,
    Size size = _tv,
    Locale locale = const Locale('en'),
    PlayerPanelTab tab = PlayerPanelTab.quality,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = FakeVlcEngine()..install();
    // The controller goes first, while its channel still has a handler.
    addTearDown(engine.dispose);
    final controller = await engine.attach();
    addTearDown(controller.dispose);
    await engine.emit(_paused);

    final notifier = ValueNotifier<PanelData>(
      data ??
          PanelData(
            sources: const [_master],
            currentSourceIndex: 0,
            qualityLadder: ladder,
            qualityPick: pick,
          ),
    );
    addTearDown(notifier.dispose);
    final picks = <int?>[];

    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
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
                  initialTab: tab,
                  isTv: isTv,
                  focusOnOpen: isTv,
                  data: notifier,
                  onPickQuality: picks.add,
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
    return (engine: engine, data: notifier, picks: picks);
  }

  List<String> rows(WidgetTester tester) => [
    for (final row in tester.widgetList<PanelRow>(
      find.byType(PanelRow, skipOffstage: false),
    ))
      row.label,
  ];

  List<String> ticked(WidgetTester tester) => [
    for (final row in tester.widgetList<PanelRow>(
      find.byType(PanelRow, skipOffstage: false),
    ))
      if (row.selected) row.label,
  ];

  String? focusedRow() => FocusManager.instance.primaryFocus?.context
      ?.findAncestorWidgetOfExactType<PanelRow>()
      ?.label;

  testWidgets('Auto first, then each height, tallest first, labelled as the '
      'sources are', (tester) async {
    await open(tester, ladder: const [2160, 1440, 1080, 720]);

    expect(rows(tester), ['Auto', '4K', '2K', '1080p', '720p']);
  });

  testWidgets('Auto names the height it plays: the rung nearest the picture', (
    tester,
  ) async {
    final opened = await open(tester);

    await opened.engine.emit(<String, Object?>{
      ..._paused,
      'videoSize': <String, Object?>{'width': 1920, 'height': 1088},
    });
    await tester.pump();
    expect(rows(tester).first, 'Auto · 1080p');

    // Under a pick Auto is not what plays, so it names nothing.
    opened.data.value = opened.data.value.copyWith(qualityPick: 720);
    await tester.pump();
    expect(rows(tester).first, 'Auto');
  });

  testWidgets('the row in effect is ticked: Auto, the pick, or what plays '
      'under it', (tester) async {
    final opened = await open(tester);
    expect(ticked(tester), ['Auto']);

    opened.data.value = opened.data.value.copyWith(qualityPick: 720);
    await tester.pump();
    expect(ticked(tester), ['720p']);

    // A step-down can lower a pick to a height the stream lacks.
    opened.data.value = opened.data.value.copyWith(qualityPick: 900);
    await tester.pump();
    expect(ticked(tester), ['720p']);

    opened.data.value = opened.data.value.copyWith(qualityPick: 240);
    await tester.pump();
    expect(ticked(tester), ['480p'], reason: 'the lowest plays under 240');
  });

  testWidgets('a pick closes the panel and reports the height; Auto reports '
      'none', (tester) async {
    final opened = await open(tester);

    await tester.tap(find.widgetWithText(PanelRow, '480p'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPanel), findsNothing);
    expect(opened.picks, [480]);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PanelRow, 'Auto'));
    await tester.pumpAndSettle();
    expect(opened.picks, [480, null]);
  });

  testWidgets('on a television it opens focused on the row in effect, and '
      'Back closes it', (tester) async {
    await open(tester, pick: 720, isTv: true);

    expect(focusedRow(), '720p');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PlayerPanel), findsNothing);
  });

  for (final locale in const [Locale('en'), Locale('hi'), Locale('kn')]) {
    testWidgets('six tabs do not cut a label short at 960x540 in '
        '${locale.languageCode}', (tester) async {
      final l10n = await AppLocalizations.delegate.load(locale);
      final episodes = [
        for (var n = 1; n <= 2; n++)
          Episode(name: 'Episode $n', url: 'https://series.test/$n'),
      ];
      await open(
        tester,
        size: _googleTv,
        isTv: true,
        locale: locale,
        tab: PlayerPanelTab.sources,
        data: PanelData(
          sources: const [_master],
          currentSourceIndex: 0,
          qualityLadder: const [1080, 720],
          episodes: episodes,
          currentEpisode: episodes.first,
          files: const [
            TorrentFile(index: 3, name: 'a.mkv', sizeBytes: 1),
            TorrentFile(index: 7, name: 'b.mkv', sizeBytes: 1),
          ],
          currentFileIndex: 3,
        ),
      );

      for (final label in [
        l10n.sources,
        l10n.playerQuality,
        l10n.audio,
        l10n.subtitles,
        l10n.episodes,
        l10n.playerFiles,
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'tab "$label"');
        expect(
          tester
              .renderObject<RenderParagraph>(find.text(label))
              .didExceedMaxLines,
          isFalse,
          reason: 'the tab label "$label" is cut off on a television',
        );
      }
    });
  }
}
