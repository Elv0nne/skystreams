import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_anchored_list.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_episodes_tab.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_data.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_metrics.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_files_tab.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_sources_tab.dart';
import 'package:skystream/features/player/presentation/vlc/torrent_file_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// What is pinned here is where a panel list *opens*: on the row that matters,
/// mid-viewport, on every form factor, with the focused row (when there is one)
/// inside the viewport rather than somewhere the estimate happened to put it.
/// And what a list must never do once open: scroll or refocus because live
/// data changed underneath the viewer, or strand the remote when the row it
/// was on disappears.
const double _kViewport = 400;

/// Rows alternating 60/120 px: tall enough that an 84 px estimate is wrong
/// for every single row, so the centring has to come from real geometry.
double _alternating(int index) => index.isEven ? 60 : 120;

/// Rows uniformly shorter than the estimate: the seed over-shoots by 24 px a
/// row, which at row 30 puts the anchor 720 px *above* the fold - inside the
/// 800 px cache, so it is built and takes focus, and off screen.
double _short(int index) => 60;

/// Host that lets a test change the list's inputs in place, the way the panel
/// rebuilds its tabs when live data arrives.
class _Host extends StatefulWidget {
  const _Host({
    required this.anchorIndex,
    required this.itemCount,
    required this.autofocus,
    required this.rowHeight,
    this.estimatedRowExtent = 84,
    super.key,
  });

  final int anchorIndex;
  final int itemCount;
  final bool autofocus;
  final double Function(int index) rowHeight;
  final double estimatedRowExtent;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late int anchorIndex = widget.anchorIndex;
  late int itemCount = widget.itemCount;

  void update({int? anchorIndex, int? itemCount}) {
    setState(() {
      this.anchorIndex = anchorIndex ?? this.anchorIndex;
      this.itemCount = itemCount ?? this.itemCount;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 320,
        height: _kViewport,
        // The panel's route scope stands in for this one: focus falling out of
        // a row lands on the scope or the root, never on a sibling.
        child: FocusScope(
          child: PanelAnchoredList(
            anchorIndex: anchorIndex,
            itemCount: itemCount,
            estimatedRowExtent: widget.estimatedRowExtent,
            autofocus: widget.autofocus,
            itemBuilder: (context, index) => Focus(
              debugLabel: 'row $index',
              autofocus: widget.autofocus && index == widget.anchorIndex,
              child: SizedBox(
                key: ValueKey<String>('row-$index'),
                height: widget.rowHeight(index),
                child: Text('row $index'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<GlobalKey<_HostState>> _pumpList(
  WidgetTester tester, {
  required int anchorIndex,
  int itemCount = 40,
  bool autofocus = false,
  double Function(int index) rowHeight = _alternating,
  double estimatedRowExtent = 84,
  int pumps = 2,
}) async {
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    MaterialApp(
      home: _Host(
        key: key,
        anchorIndex: anchorIndex,
        itemCount: itemCount,
        autofocus: autofocus,
        rowHeight: rowHeight,
        estimatedRowExtent: estimatedRowExtent,
      ),
    ),
  );
  for (var i = 1; i < pumps; i++) {
    await tester.pump();
  }
  return key;
}

/// Rows built into the cache extent are offstage; they still have a rect.
Rect _rowRect(WidgetTester tester, int index) => tester.getRect(
  find.byKey(ValueKey<String>('row-$index'), skipOffstage: false),
);

/// [Rect.contains] excludes the far edges, which a full-width row always
/// shares with its viewport.
bool _inside(Rect outer, Rect inner) =>
    inner.top >= outer.top &&
    inner.bottom <= outer.bottom &&
    inner.left >= outer.left &&
    inner.right <= outer.right;

Rect _listRect(WidgetTester tester) =>
    tester.getRect(find.byType(PanelAnchoredList));

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable)).position;

/// The row holding primary focus, by its debug label, or null.
String? _focusedRow() {
  final label = FocusManager.instance.primaryFocus?.debugLabel;
  return label != null && label.startsWith('row ') ? label : null;
}

void main() {
  group('opens centred on the anchor', () {
    for (final autofocus in <bool>[false, true]) {
      testWidgets(
        autofocus ? 'on a remote (autofocus)' : 'on a touch screen (no focus)',
        (tester) async {
          await _pumpList(tester, anchorIndex: 30, autofocus: autofocus);

          final row = _rowRect(tester, 30);
          final list = _listRect(tester);
          expect(
            (row.center.dy - list.center.dy).abs(),
            lessThanOrEqualTo(row.height / 2),
            reason: 'row 30 is centred on real geometry, not the estimate',
          );
          expect(_inside(list, row), isTrue);
          expect(_focusedRow(), autofocus ? 'row 30' : isNull);
        },
      );
    }

    testWidgets('an over-shooting estimate no longer leaves the focused row '
        'above the fold', (tester) async {
      await _pumpList(
        tester,
        anchorIndex: 30,
        autofocus: true,
        rowHeight: _short,
      );

      final row = _rowRect(tester, 30);
      final list = _listRect(tester);
      expect(_focusedRow(), 'row 30');
      expect(
        _inside(list, row),
        isTrue,
        reason:
            'a 60 px row seeded at 84 px sat 720 px above the viewport; the '
            'focused row must be on screen',
      );
      expect(
        (row.center.dy - list.center.dy).abs(),
        lessThanOrEqualTo(row.height / 2),
      );
    });

    testWidgets('an anchor near the end pins to maxScrollExtent on the first '
        'frame with no spring-back', (tester) async {
      await _pumpList(tester, anchorIndex: 39, pumps: 1);

      final position = _position(tester);
      expect(
        position.pixels,
        lessThanOrEqualTo(position.maxScrollExtent),
        reason: 'the seed over-ran the end; the jump clamped it',
      );
      expect(position.isScrollingNotifier.value, isFalse);

      await tester.pump();
      expect(position.pixels, position.maxScrollExtent);
      expect(_inside(_listRect(tester), _rowRect(tester, 39)), isTrue);
    });

    testWidgets('anchor zero opens at the top', (tester) async {
      await _pumpList(tester, anchorIndex: 0);
      expect(_position(tester).pixels, 0);
    });

    testWidgets('a list that fits stays at the top whatever the anchor', (
      tester,
    ) async {
      await _pumpList(tester, anchorIndex: 2, itemCount: 3, autofocus: true);
      expect(_position(tester).pixels, 0);
      expect(_position(tester).maxScrollExtent, 0);
      expect(_focusedRow(), 'row 2');
    });
  });

  group('live updates', () {
    testWidgets('a later anchorIndex neither scrolls nor moves focus', (
      tester,
    ) async {
      final host = await _pumpList(tester, anchorIndex: 30, autofocus: true);
      final before = _position(tester).pixels;
      expect(_focusedRow(), 'row 30');

      host.currentState!.update(anchorIndex: 35);
      await tester.pump();
      await tester.pump();

      expect(_position(tester).pixels, before);
      expect(_focusedRow(), 'row 30');
      // The row that is the anchor now must not have inherited the old
      // anchor's element: its text and its position both belong to row 35.
      expect(find.text('row 35', skipOffstage: false), findsOneWidget);
      expect(_rowRect(tester, 35).top, greaterThan(_rowRect(tester, 30).top));
    });

    testWidgets(
      'the list shrinking under the focused row puts focus back in the list',
      (tester) async {
        final host = await _pumpList(tester, anchorIndex: 30, autofocus: true);
        expect(_focusedRow(), 'row 30');

        host.currentState!.update(itemCount: 20);
        await tester.pump();
        await tester.pump();

        final focused = _focusedRow();
        expect(focused, isNotNull, reason: 'focus fell to the root scope');
        final index = int.parse(focused!.substring('row '.length));
        expect(index, lessThan(20));
        expect(
          _inside(_listRect(tester), _rowRect(tester, index)),
          isTrue,
          reason: 'the rescued row is on screen, not somewhere in the cache',
        );
      },
    );

    testWidgets('the list shrinking does not create focus on a touch screen', (
      tester,
    ) async {
      final host = await _pumpList(tester, anchorIndex: 30, autofocus: false);
      final before = FocusManager.instance.primaryFocus;
      expect(_focusedRow(), isNull);

      host.currentState!.update(itemCount: 20);
      await tester.pump();
      await tester.pump();

      expect(_focusedRow(), isNull);
      expect(FocusManager.instance.primaryFocus, same(before));
    });
  });

  group('tabs anchor on the right row', () {
    Widget app(Widget body) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        // Wide enough that the test font's 1 em glyphs do not wrap the
        // badge row, which Roboto never does at the panel's real width.
        body: SizedBox(width: 600, height: _kViewport, child: body),
      ),
    );

    List<StreamResult> sources(int count) => List<StreamResult>.generate(
      count,
      (i) => StreamResult(
        url: 'https://s.test/$i',
        source: '${1080 - i}p · 2.1 GB · 👤 ${40 - i}',
        providerName: 'Provider $i',
      ),
    );

    List<Episode> episodes(int count) => List<Episode>.generate(
      count,
      (i) => Episode(
        name: 'Episode ${i + 1}',
        url: 'https://e.test/${i + 1}',
        season: 1,
        episode: i + 1,
        runtime: 42,
        airDate: '2024-01-0${(i % 9) + 1}',
      ),
    );

    /// Server ids 3, 7, 11, ...: never equal to the position.
    /// The heaviest episode row: a dub badge to share the wrap with the
    /// `Watched` chip watch progress adds.
    List<Episode> watchedEpisodes(int count) => List<Episode>.generate(
      count,
      (i) => Episode(
        name: 'Episode ${i + 1}',
        url: 'https://e.test/${i + 1}',
        season: 1,
        episode: i + 1,
        runtime: 42,
        airDate: '2024-01-0${(i % 9) + 1}',
        dubStatus: DubStatus.dubbed,
      ),
    );

    List<TorrentFile> files(int count) => List<TorrentFile>.generate(
      count,
      (i) => TorrentFile(
        index: 3 + 4 * i,
        name: 'S01E${(i + 1).toString().padLeft(2, '0')}.mkv',
        sizeBytes: 1400 * 1024 * 1024,
      ),
    );

    PanelAnchoredList list(WidgetTester tester) =>
        tester.widget<PanelAnchoredList>(find.byType(PanelAnchoredList));

    testWidgets('Files anchors on the playing id, not the id as a position', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          PlayerFilesTab(
            files: files(12),
            currentIndex: 43, // position 10
            autofocus: true,
            onPick: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(list(tester).anchorIndex, 10);
      expect(list(tester).autofocus, isTrue);
      final rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      final focused = rows.where((row) => row.autofocus).toList();
      expect(focused, hasLength(1));
      expect(focused.single.label, 'S01E11.mkv');
      expect(focused.single.selected, isTrue);
    });

    testWidgets('Files with an unknown current id opens on the first row', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          PlayerFilesTab(
            files: files(5),
            currentIndex: 999,
            autofocus: true,
            onPick: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(list(tester).anchorIndex, 0);
      final rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      expect(rows.first.autofocus, isTrue);
      expect(rows.where((row) => row.selected), isEmpty);
    });

    testWidgets('Files: anchorIndex is an id and freezes the anchor while the '
        'tick follows currentIndex', (tester) async {
      await tester.pumpWidget(
        app(
          PlayerFilesTab(
            files: files(5),
            currentIndex: 19, // position 4, playing now
            anchorIndex: 7, // position 1, what the panel saw at open
            autofocus: true,
            onPick: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(list(tester).anchorIndex, 1);
      final rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      expect(rows[1].autofocus, isTrue);
      expect(rows[1].selected, isFalse);
      expect(rows[4].selected, isTrue);
      expect(rows[4].autofocus, isFalse);
    });

    testWidgets('Sources: anchorIndex defaults to currentIndex and, when '
        'given, wins the anchor but not the tick', (tester) async {
      await tester.pumpWidget(
        app(
          PlayerSourcesTab(
            sources: sources(4),
            currentIndex: 2,
            autofocus: true,
            onPick: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(list(tester).anchorIndex, 2);
      var rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      expect(rows[2].autofocus, isTrue);
      expect(rows[2].selected, isTrue);

      await tester.pumpWidget(
        app(
          PlayerSourcesTab(
            sources: sources(4),
            currentIndex: 3,
            anchorIndex: 1,
            autofocus: true,
            onPick: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(list(tester).anchorIndex, 1);
      rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      expect(rows[1].autofocus, isTrue);
      expect(rows[1].selected, isFalse);
      expect(rows[3].selected, isTrue);
      expect(rows[3].autofocus, isFalse);
    });

    testWidgets('Sources: the fallback banner shifts the anchor by one row', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          PlayerSourcesTab(
            sources: sources(4),
            currentIndex: 2,
            qualityFilteredFallback: true,
            onPick: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(list(tester).anchorIndex, 3);
      expect(list(tester).itemCount, 5);
    });

    testWidgets('Sources: an out-of-range anchor falls back to the first row', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          PlayerSourcesTab(
            sources: sources(4),
            currentIndex: -1,
            anchorIndex: 9,
            autofocus: true,
            onPick: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(list(tester).anchorIndex, 0);
      final rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      expect(rows.first.autofocus, isTrue);
      expect(rows.where((row) => row.selected), isEmpty);
    });

    testWidgets('Episodes: anchorIndex defaults to the current episode and, '
        'when given, wins the anchor but not the tick', (tester) async {
      final list3 = episodes(3);
      await tester.pumpWidget(
        app(
          PlayerEpisodesTab(
            episodes: list3,
            currentEpisode: list3[2],
            autofocus: true,
            onPick: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(list(tester).anchorIndex, 2);
      var rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      expect(rows[2].autofocus, isTrue);
      expect(rows[2].selected, isTrue);

      await tester.pumpWidget(
        app(
          PlayerEpisodesTab(
            episodes: list3,
            currentEpisode: list3[2],
            anchorIndex: 1,
            autofocus: true,
            onPick: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(list(tester).anchorIndex, 1);
      rows = tester.widgetList<PanelRow>(find.byType(PanelRow)).toList();
      expect(rows[1].autofocus, isTrue);
      expect(rows[1].selected, isFalse);
      expect(rows[2].selected, isTrue);
    });

    testWidgets('estimated row extents track the measured PanelRow heights', (
      tester,
    ) async {
      final measured = <String, (double estimate, double actual)>{};

      Future<void> measure(String tab, Widget body) async {
        await tester.pumpWidget(app(body));
        await tester.pump();
        final rows = find.byType(PanelRow);
        expect(rows, findsWidgets);
        final heights = <double>[
          for (final element in rows.evaluate())
            (element.renderObject! as RenderBox).size.height,
        ];
        final actual = heights.reduce((a, b) => a + b) / heights.length;
        measured[tab] = (list(tester).estimatedRowExtent, actual);
      }

      await measure(
        'sources',
        PlayerSourcesTab(sources: sources(3), currentIndex: 1, onPick: (_) {}),
      );
      final eps = episodes(3);
      await measure(
        'episodes',
        PlayerEpisodesTab(
          episodes: eps,
          currentEpisode: eps[1],
          onPick: (_) {},
        ),
      );
      await measure(
        'files',
        PlayerFilesTab(files: files(3), currentIndex: 7, onPick: (_) {}),
      );
      // The heaviest episode row there is: a dub badge and a `Watched` chip
      // sharing the badge wrap, over a dimmed still. If watch progress pushed
      // a row onto another line, the estimate would be the thing that noticed.
      final dubbed = watchedEpisodes(3);
      await measure(
        'episodes (watched, dubbed)',
        PlayerEpisodesTab(
          episodes: dubbed,
          currentEpisode: dubbed[1],
          episodeProgress: (episode) => const EpisodeProgress(watched: true),
          onPick: (_) {},
        ),
      );
      // And the same row on the television ramp, where W2.2's type scale makes
      // every line taller. The estimate is a seed for the opening offset, not
      // a layout constraint, so it is allowed to be short here - what is
      // pinned is that the extra chip did not double the row's height.
      final tvHeights = <double>[];
      await tester.pumpWidget(
        app(
          PlayerPanelMetricsScope(
            metrics: PlayerPanelMetrics.tv,
            child: PlayerEpisodesTab(
              episodes: dubbed,
              currentEpisode: dubbed[1],
              episodeProgress: (episode) =>
                  const EpisodeProgress(watched: true),
              onPick: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      for (final element in find.byType(PanelRow).evaluate()) {
        tvHeights.add((element.renderObject! as RenderBox).size.height);
      }
      final tvActual = tvHeights.reduce((a, b) => a + b) / tvHeights.length;
      debugPrint(
        'PanelRow episodes (watched, dubbed, television): '
        'measured ${tvActual.toStringAsFixed(1)} px (test font)',
      );
      expect(
        tvActual,
        lessThan(2 * 84),
        reason:
            'the Watched chip must not wrap an episode row onto a second '
            'line even at ten-foot type',
      );

      for (final MapEntry(key: tab, value: (estimate, actual))
          in measured.entries) {
        // Printed so the constants can be re-derived when a row changes shape.
        debugPrint(
          'PanelRow $tab: estimatedRowExtent $estimate, '
          'measured ${actual.toStringAsFixed(1)} px (test font)',
        );
        // The estimate only has to land the anchor inside the 800 px cache;
        // what this guards is gross drift like the 96 px episodes carried.
        expect(
          (estimate - actual).abs(),
          lessThanOrEqualTo(estimate * 0.15),
          reason: '$tab estimate $estimate vs measured $actual',
        );
      }
    });
  });
}
