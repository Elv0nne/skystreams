/// Online subtitle search, as the side panel's second step: opened from the
/// Subtitles tab's Search online row in the panel's own place, the way the
/// player opens it - by remote on a television, by a tap elsewhere - handed a
/// [SubtitleSearchTarget] and a controller on a fake engine.
///
/// What is pinned is the hand-off - which arguments reach the providers and
/// when - and the way in and out: every control is a stop a remote reaches,
/// and Back walks one step. The real [SubtitleSearch] notifier runs, over
/// `SubtitleSearch.debugProviders`, so the id -> title fallback and the
/// repeat-search guard are the production ones; only the download, which
/// would need Dio and a temp directory, is stubbed on a subclass.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shimmer/shimmer.dart';
import 'package:skystream/features/player/domain/entity/subtitle_model.dart';
import 'package:skystream/features/player/domain/side_car_subtitles.dart';
import 'package:skystream/features/player/domain/subtitle_search_target.dart';
import 'package:skystream/features/player/presentation/subtitle_search_provider.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_subtitle_search_page.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'fake_vlc_engine.dart';

const Size _tv = Size(2560, 1440);

/// A snapshot that moves nothing but keeps the controller's stall watchdog
/// unarmed: a playing snapshot leaves a 1 s timer pending, and flutter_test
/// checks pending timers before any tear-down runs.
const Map<String, Object?> _paused = <String, Object?>{'state': 'paused'};

const SubtitleSearchTarget _episode = SubtitleSearchTarget(
  title: 'The Show',
  imdbId: 'tt0903747',
  tmdbId: 1396,
  season: 2,
  episode: 5,
);

/// The same episode as [_episode] with no ids on it - a plugin-sourced series
/// the catalogue had no IMDb/TMDb match for. Season and episode still ride
/// along, so the season widening is reachable without an id ever being sent.
const SubtitleSearchTarget _episodeNoId = SubtitleSearchTarget(
  title: 'The Show',
  season: 2,
  episode: 5,
);

const SubtitleSearchTarget _localFile = SubtitleSearchTarget(
  title: 'Home.Video.2019.mkv',
);

typedef _Call = ({
  String query,
  String? imdbId,
  int? tmdbId,
  int? season,
  int? episode,
  String? language,
});

/// Stands in for the three providers: records every `search` and answers
/// through [respond], which sees the 1-based call number.
class _RecordingProvider extends SubtitleProvider {
  @override
  String get name => 'Fake';

  @override
  String get idPrefix => 'fake';

  final List<_Call> calls = <_Call>[];

  Future<List<OnlineSubtitle>> Function(int callNumber) respond = (_) async =>
      <OnlineSubtitle>[_result('1')];

  @override
  Future<List<OnlineSubtitle>> search({
    required String query,
    String? imdbId,
    int? tmdbId,
    int? season,
    int? episode,
    String? language,
    CancelToken? cancelToken,
  }) {
    calls.add((
      query: query,
      imdbId: imdbId,
      tmdbId: tmdbId,
      season: season,
      episode: episode,
      language: language,
    ));
    return respond(calls.length);
  }

  @override
  Future<String?> getDownloadUrl(OnlineSubtitle subtitle) async => null;
}

/// The production notifier with the one method that would touch the network
/// and the file system replaced: the download either "lands" at [path] or
/// fails, and every request is recorded.
class _StubDownload extends SubtitleSearch {
  _StubDownload(this.downloads, this.path, this.episodes);

  final List<OnlineSubtitle> downloads;
  final String? path;

  /// The season and episode each download was asked for.
  final List<(int?, int?)> episodes;

  @override
  Future<String?> downloadAndPrepare(
    OnlineSubtitle subtitle, {
    int? season,
    int? episode,
  }) async {
    downloads.add(subtitle);
    episodes.add((season, episode));
    return path;
  }
}

/// What SkyStream draws a downloaded file with: a fetch that reads every file
/// as the same one-cue SubRip.
SideCarSubtitles _drawnBySkyStream() => SideCarSubtitles(
  fetch: (url, headers) async =>
      utf8.encode('1\n00:00:01,000 --> 00:00:04,000\nHello\n'),
);

OnlineSubtitle _result(String id) => OnlineSubtitle(
  id: id,
  name: 'The.Show.S02E05.$id.srt',
  language: 'en',
  source: 'Fake',
  downloadUrl: 'https://example.com/$id',
);

/// The widget of type [T] holding primary focus, or null.
T? _focused<T extends Widget>() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<T>();

/// The first text inside the control holding primary focus - a result's
/// release name, a language chip's label - or null.
String? _focusedText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return null;
  String? found;
  void visit(Element element) {
    if (found != null) return;
    final widget = element.widget;
    if (widget is Text) {
      found = widget.data;
      return;
    }
    element.visitChildren(visit);
  }

  (context as Element).visitChildren(visit);
  return found;
}

/// What the control holding primary focus announces itself as: the panel's
/// own buttons, Back among them, are a [Semantics] label over their focus.
String? _focusedLabel() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<Semantics>()
    ?.properties
    .label;

/// The label of the tab row holding primary focus, or null when a row does
/// not.
String? _focusedRow() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<PanelRow>()
    ?.label;

/// Whether the text [finder] finds sits inside a focus stop: a control a
/// remote lands on, rather than words it steps past.
bool _insideStop(Finder finder) {
  final node = Focus.maybeOf(finder.evaluate().single);
  return node != null && node.canRequestFocus && !node.skipTraversal;
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _down(WidgetTester tester) =>
    _press(tester, LogicalKeyboardKey.arrowDown);

/// The retired "no subtitle account is set up" advice, matched by what it
/// claimed rather than by an ARB key that no longer exists.
///
/// `subtitleAccountsNotConfigured` told a fresh install to go to Settings and
/// add an OpenSubtitles, SubDL or SubSource key before it could search online.
/// That was untrue on a default install - OpenSubtitles runs on the bundled
/// `buildTimeApiKey` and SubSource takes a keyless path - so the call site went
/// first and the key has now followed it out of all 44 ARBs.
///
/// The three cases below exist to keep that claim out of the empty state, and
/// they still do: the matcher is the claim itself - a line naming one of the
/// three providers and sending the viewer to Settings - so re-adding the
/// advice under any key, or spelling it out inline, fails them again. The
/// matcher is itself pinned by 'the retired advice is still catchable', so it
/// cannot rot into a finder that matches nothing.
final Finder _accountAdvice = find.byWidgetPredicate(
  (Widget widget) =>
      widget is Text && _accountAdviceClaim.hasMatch(widget.data ?? ''),
  description: 'text blaming an unconfigured subtitle account',
);

final RegExp _accountAdviceClaim = RegExp(
  r'(OpenSubtitles|SubDL|SubSource)[\s\S]*Settings'
  r'|Settings[\s\S]*(OpenSubtitles|SubDL|SubSource)',
  caseSensitive: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  /// Whether the panel is showing its tabs again - the search closed and the
  /// Subtitles tab it was opened from back on screen.
  bool onTheTab() =>
      find.byType(SubtitleSearchPage).evaluate().isEmpty &&
      find
          .widgetWithText(PanelRow, l10n.searchSubtitlesOnline)
          .evaluate()
          .isNotEmpty;

  /// Opens the panel on the Subtitles tab over a host page, as the player
  /// does, then Search online the way a viewer would: from a remote on a
  /// television - down the tab to the row, then Select - and by a tap
  /// elsewhere.
  ///
  /// Returns everything a test can observe: the provider's calls, the
  /// downloads asked for, the engine, and whether the panel itself closed.
  /// [settle] false leaves an in-flight search's shimmer running. [sideCars]
  /// is what draws a downloaded file, as on the player's screen; without it
  /// the file goes to the engine. [embedded] are the tracks inside the video
  /// the tab lists ahead of any file.
  Future<
    ({
      _RecordingProvider provider,
      List<OnlineSubtitle> downloads,
      List<(int?, int?)> episodes,
      FakeVlcEngine engine,
      List<bool> closed,
    })
  >
  pumpSearch(
    WidgetTester tester, {
    SubtitleSearchTarget? target,
    bool isTv = true,
    PlayerSettings settings = const PlayerSettings(),
    _RecordingProvider? provider,
    String? downloadPath,
    SideCarSubtitles? sideCars,
    List<Map<String, Object?>> embedded = const <Map<String, Object?>>[],
    Size size = _tv,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = FakeVlcEngine()
      ..subtitle = embedded
      ..install();
    addTearDown(engine.dispose);
    final controller = await engine.attach();
    addTearDown(controller.dispose);
    await engine.emit(_paused);

    final recorder = provider ?? _RecordingProvider();
    SubtitleSearch.debugProviders = <SubtitleProvider>[recorder];
    addTearDown(() => SubtitleSearch.debugProviders = null);

    final data = ValueNotifier<PanelData>(PanelData(subtitleTarget: target));
    addTearDown(data.dispose);

    final downloads = <OnlineSubtitle>[];
    final episodes = <(int?, int?)>[];
    final closed = <bool>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerSettingsProvider.overrideWithBuild((_, _) => settings),
          subtitleSearchProvider.overrideWith(
            () => _StubDownload(downloads, downloadPath, episodes),
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Align(
              alignment: Alignment.centerLeft,
              child: Builder(
                builder: (context) => TextButton(
                  onPressed: () => unawaited(
                    showPlayerPanel(
                      context,
                      controller: controller,
                      initialTab: PlayerPanelTab.subtitles,
                      data: data,
                      isTv: isTv,
                      focusOnOpen: isTv,
                      sideCars: sideCars,
                    ).then((_) => closed.add(true)),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    if (isTv) {
      for (var i = 0; _focusedRow() != l10n.searchSubtitlesOnline; i++) {
        expect(i, lessThan(8), reason: 'Search online is reachable');
        await _down(tester);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
    } else {
      await tester.tap(find.text(l10n.searchSubtitlesOnline));
    }
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // The seed, the page's first frame, then its post-frame auto-search.
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.byType(SubtitleSearchPage), findsOneWidget);
    return (
      provider: recorder,
      downloads: downloads,
      episodes: episodes,
      engine: engine,
      closed: closed,
    );
  }

  group('what gets searched', () {
    testWidgets('a target with an id searches on open, ids and episode along', (
      tester,
    ) async {
      final page = await pumpSearch(tester, target: _episode);

      expect(page.provider.calls, hasLength(1), reason: 'zero presses');
      expect(page.provider.calls.single, (
        query: 'The Show',
        imdbId: 'tt0903747',
        tmdbId: 1396,
        season: 2,
        episode: 5,
        language: 'en',
      ));
      expect(find.text(_result('1').name), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'The Show'),
        findsOneWidget,
        reason: 'the field shows the bare title, never "Show S02E05"',
      );
    });

    testWidgets('a title-only target waits for the viewer', (tester) async {
      final page = await pumpSearch(tester, target: _localFile);

      expect(
        page.provider.calls,
        isEmpty,
        reason: 'a filename is a guess, not worth a network call per open',
      );
      expect(find.text(l10n.subtitleSearchPrompt), findsOneWidget);
      expect(find.widgetWithText(TextField, _localFile.title), findsOneWidget);

      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();
      expect(page.provider.calls.single.query, _localFile.title);
      expect(page.provider.calls.single.imdbId, isNull);
      expect(page.provider.calls.single.season, isNull);
    });

    testWidgets('editing the title drops the ids; restoring it brings them '
        'back', (tester) async {
      // The auto-search stays in flight, so the guard against repeating a
      // completed request does not swallow the restored-title press below.
      final pending = Completer<List<OnlineSubtitle>>();
      final provider = _RecordingProvider()
        ..respond = (n) => n == 1
            ? pending.future
            : Future.value(<OnlineSubtitle>[_result('$n')]);
      final page = await pumpSearch(
        tester,
        target: _episode,
        provider: provider,
        settle: false,
      );
      expect(page.provider.calls, hasLength(1));

      await tester.enterText(find.byType(TextField), 'Another Show');
      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();

      expect(page.provider.calls, hasLength(2));
      expect(page.provider.calls[1], (
        query: 'Another Show',
        imdbId: null,
        tmdbId: null,
        season: 2,
        episode: 5,
        language: 'en',
      ), reason: 'the viewer\'s words, not the id the providers would prefer');

      await tester.enterText(find.byType(TextField), '  The Show ');
      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();

      expect(page.provider.calls, hasLength(3));
      expect(page.provider.calls[2].imdbId, 'tt0903747');
      expect(page.provider.calls[2].tmdbId, 1396);
      expect(page.provider.calls[2].query, 'The Show');
    });
  });

  group('what the notes say', () {
    testWidgets(
      'an id that missed and a title that hit is said once, as text',
      (tester) async {
        final provider = _RecordingProvider()
          ..respond = (n) async => n == 1
              ? const <OnlineSubtitle>[]
              : <OnlineSubtitle>[_result('title')];
        await pumpSearch(tester, target: _episode, provider: provider);

        expect(provider.calls, hasLength(2));
        expect(provider.calls[1].imdbId, isNull);
        expect(find.text(l10n.subtitleSearchTitleFallback), findsOneWidget);
        expect(
          find.text(l10n.subtitleSearchSeasonFallback),
          findsNothing,
          reason: 'the episode still scoped the pass that hit',
        );
        expect(find.text(_result('title').name), findsOneWidget);

        expect(
          _insideStop(find.text(l10n.subtitleSearchTitleFallback)),
          isFalse,
          reason: 'the note is text a remote steps past, not a stop',
        );
        expect(_insideStop(find.text(_result('title').name)), isTrue);
        expect(_focused<IconButton>()?.tooltip, l10n.search);
        await _down(tester);
        expect(
          _focusedText(),
          'English',
          reason: 'into the languages on the one searched in',
        );
        await _down(tester);
        expect(_focusedText(), _result('title').name);
      },
    );

    testWidgets('a direct hit carries no note', (tester) async {
      await pumpSearch(tester, target: _episode);

      expect(find.text(l10n.subtitleSearchTitleFallback), findsNothing);
      expect(find.text(l10n.subtitleSearchSeasonFallback), findsNothing);
      expect(find.text(_result('1').name), findsOneWidget);
    });

    testWidgets('a season-wide list says it is the season, and never blames '
        'an ID that was never sent', (tester) async {
      // No ids on the target, so pass 1 is byTitle with the episode attached.
      // It misses, the notifier drops the episode and the whole season comes
      // back: results for S02E01..E10 against an S02E05 playback. Telling the
      // viewer "nothing matched this title's ID" is false twice over - no ID
      // was in play, and the news is that they now have to find their own
      // episode in the list or run one to nine episodes out of sync.
      final provider = _RecordingProvider()
        ..respond = (n) async => n == 1
            ? const <OnlineSubtitle>[]
            : <OnlineSubtitle>[_result('season')];
      await pumpSearch(tester, target: _episodeNoId, provider: provider);

      expect(provider.calls, isEmpty, reason: 'no id is no auto-search');
      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();

      expect(
        provider.calls,
        hasLength(2),
        reason: 'the title, then the season',
      );
      expect(provider.calls[0].imdbId, isNull);
      expect(provider.calls[0].tmdbId, isNull);
      expect(provider.calls[0].episode, 5);
      expect(provider.calls[1].season, 2);
      expect(provider.calls[1].episode, isNull, reason: 'the episode dropped');

      expect(find.text(l10n.subtitleSearchSeasonFallback), findsOneWidget);
      expect(find.text(l10n.subtitleSearchTitleFallback), findsNothing);
      expect(find.text(_result('season').name), findsOneWidget);
      expect(
        _insideStop(find.text(l10n.subtitleSearchSeasonFallback)),
        isFalse,
        reason: 'the season note is text a remote steps past, not a stop',
      );
    });

    testWidgets('an id that missed and a title that missed too still name '
        'the season, not the ID', (tester) async {
      // The full chain: byId -> byTitleAfterIdMiss -> bySeasonAfterEpisodeMiss.
      // An ID really was sent here, but it is not what the list is: these are
      // season-wide files and that is the only thing worth saying.
      final provider = _RecordingProvider()
        ..respond = (n) async => n < 3
            ? const <OnlineSubtitle>[]
            : <OnlineSubtitle>[_result('season')];
      await pumpSearch(tester, target: _episode, provider: provider);

      expect(provider.calls, hasLength(3));
      expect(provider.calls[2].episode, isNull);
      expect(find.text(l10n.subtitleSearchSeasonFallback), findsOneWidget);
      expect(find.text(l10n.subtitleSearchTitleFallback), findsNothing);
    });

    testWidgets('a fresh install with no keys says nothing was found, not '
        'that nothing is set up', (tester) async {
      // `const PlayerSettings()` is the shipping default: every key empty
      // (player_settings_provider.dart). Searching does not need one -
      // OpenSubtitles runs on the bundled `buildTimeApiKey` and SubSource
      // takes its keyless path - so the search really ran, three passes
      // deep, and came back empty. Blaming the viewer's configuration for
      // that sent them out of the player to Settings for nothing and hid
      // the only advice that helps.
      //
      // The string that did the blaming is gone now, ARB key and all, so
      // these three cases match the CLAIM rather than a key - see
      // [_accountAdvice].
      final provider = _RecordingProvider()
        ..respond = (_) async => const <OnlineSubtitle>[];
      await pumpSearch(tester, target: _episode, provider: provider);

      expect(
        provider.calls,
        hasLength(3),
        reason: 'id, title, then the season: the chain ran out',
      );
      expect(find.text(l10n.noSubtitlesFoundTryAnother), findsOneWidget);
      expect(_accountAdvice, findsNothing);
    });

    testWidgets('nothing found with a key is just nothing found', (
      tester,
    ) async {
      final provider = _RecordingProvider()
        ..respond = (_) async => const <OnlineSubtitle>[];
      await pumpSearch(
        tester,
        target: _episode,
        provider: provider,
        settings: const PlayerSettings(subdlApiKey: 'k'),
      );

      expect(find.text(l10n.noSubtitlesFoundTryAnother), findsOneWidget);
      expect(_accountAdvice, findsNothing);
    });

    testWidgets('an OpenSubtitles login changes nothing about the note', (
      tester,
    ) async {
      final provider = _RecordingProvider()
        ..respond = (_) async => const <OnlineSubtitle>[];
      await pumpSearch(
        tester,
        target: _episode,
        provider: provider,
        settings: const PlayerSettings(osUsername: 'viewer'),
      );

      expect(find.text(l10n.noSubtitlesFoundTryAnother), findsOneWidget);
      expect(_accountAdvice, findsNothing);
    });

    testWidgets('the retired advice is still catchable', (tester) async {
      // A positive control for the three findsNothing above. They lost their
      // subject when `subtitleAccountsNotConfigured` was deleted from the
      // ARBs, and a finder for a string nothing renders passes for free. This
      // renders the exact wording that was retired and requires the matcher to
      // see it, so the three cases keep failing if anyone brings the claim
      // back - under a new key, or hardcoded.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Text(
              'No subtitle account is set up. Add an OpenSubtitles, SubDL or '
              'SubSource key in Settings to search online.',
            ),
          ),
        ),
      );

      expect(_accountAdvice, findsOneWidget);
    });
  });

  group('a chosen result', () {
    /// The labels of the rows the Subtitles tab has ticked.
    List<String> ticked(WidgetTester tester) => tester
        .widgetList<PanelRow>(find.byType(PanelRow))
        .where((row) => row.selected)
        .map((row) => row.label)
        .toList();

    testWidgets('is downloaded and drawn by SkyStream, and the panel is back '
        'on the tab with it ticked', (tester) async {
      final page = await pumpSearch(
        tester,
        target: _episode,
        downloadPath: '/tmp/subs/The.Show.S02E05.srt',
        sideCars: _drawnBySkyStream(),
      );

      await tester.tap(find.text(_result('1').name));
      await tester.pumpAndSettle();

      expect(page.downloads.map((s) => s.id), <String>['1']);
      expect(page.episodes, <(int?, int?)>[
        (2, 5),
      ], reason: 'the episode on screen picks its file out of a season pack');
      expect(page.engine.callsTo('addSubtitle'), isEmpty);
      expect(onTheTab(), isTrue, reason: 'back on the list, not out of it');
      expect(page.closed, isEmpty, reason: 'the panel itself stays up');
      expect(ticked(tester), <String>[
        _result('1').name,
      ], reason: 'the file the search added is the subtitle that is on');
    });

    testWidgets('with nothing to draw it, goes to the engine, and is ticked '
        'once the engine announces it', (tester) async {
      final page = await pumpSearch(
        tester,
        target: _episode,
        downloadPath: '/tmp/subs/The.Show.S02E05.srt',
      );

      await tester.tap(find.text(_result('1').name));
      await tester.pumpAndSettle();

      final added = page.engine.callsTo('addSubtitle');
      expect(added, hasLength(1));
      expect(
        (added.single.arguments as Map<Object?, Object?>)['uri'],
        Uri.file('/tmp/subs/The.Show.S02E05.srt').toString(),
      );
      expect(onTheTab(), isTrue);

      // ESAdded: the snapshot every native sends once the track exists.
      await page.engine.emit(_paused);
      await tester.pumpAndSettle();
      expect(ticked(tester), <String>['The.Show.S02E05.srt']);
    });

    testWidgets('picked by remote hands focus back to Search online, though '
        'the file it added is now listed ahead of it', (tester) async {
      await pumpSearch(
        tester,
        target: _episode,
        downloadPath: '/tmp/subs/The.Show.S02E05.srt',
        sideCars: _drawnBySkyStream(),
        // A track already listed, so the file's row is a row more ahead of
        // Search online rather than the "nothing found" note's place.
        embedded: const <Map<String, Object?>>[
          <String, Object?>{'id': 3, 'name': 'English'},
          <String, Object?>{'id': 4, 'name': 'SDH'},
        ],
        // A 1080p television at the density Android TV reports: a list short
        // enough that one more row pushes the last ones past the fold.
        size: const Size(960, 540),
      );
      final before = tester.getTopLeft(
        find.widgetWithText(
          PanelRow,
          l10n.loadSubtitleFile,
          skipOffstage: false,
        ),
      );

      await _down(tester);
      await _down(tester);
      expect(_focusedText(), _result('1').name);
      await _press(tester, LogicalKeyboardKey.select);

      expect(onTheTab(), isTrue);
      expect(find.widgetWithText(PanelRow, _result('1').name), findsOneWidget);
      expect(
        tester.getTopLeft(find.widgetWithText(PanelRow, l10n.loadSubtitleFile)),
        isNot(before),
        reason: 'the list really did move under the page',
      );
      expect(
        _focusedRow(),
        l10n.searchSubtitlesOnline,
        reason:
            'the row the search was opened from, not the one now in its '
            'old place',
      );
      final row = tester.getRect(
        find.widgetWithText(PanelRow, l10n.searchSubtitlesOnline),
      );
      final list = tester.getRect(
        find
            .ancestor(
              of: find.widgetWithText(PanelRow, l10n.searchSubtitlesOnline),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        row.top >= list.top && row.bottom <= list.bottom,
        isTrue,
        reason:
            'all of the row on screen, not a ring below the fold: $row in '
            '$list',
      );
    });

    testWidgets('that fails to download says so and stays open', (
      tester,
    ) async {
      final page = await pumpSearch(tester, target: _episode);

      await tester.tap(find.text(_result('1').name));
      await tester.pumpAndSettle();

      expect(find.text(l10n.subtitleDownloadFailed), findsOneWidget);
      expect(page.engine.callsTo('addSubtitle'), isEmpty);
      expect(find.byType(SubtitleSearchPage), findsOneWidget);
    });

    testWidgets('that the engine refuses says so, stops the progress bar and '
        'leaves the list usable', (tester) async {
      final page = await pumpSearch(
        tester,
        target: _episode,
        downloadPath: '/tmp/subs/The.Show.S02E05.srt',
      );

      // The file downloaded fine; the *engine* said no. Every native can:
      // Android when `addSlave` returns false or the player is not active,
      // macOS/iOS on a non-zero `addPlaybackSlave` status, and the Dart side
      // on a disposed controller. It arrives as a PlatformException over the
      // same channel the fake answers on.
      final refused = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FakeVlcEngine.channel, (call) async {
            refused.add(call);
            if (call.method == 'addSubtitle') {
              throw PlatformException(
                code: 'add_subtitle_failed',
                message: 'addSlave returned false',
              );
            }
            return null;
          });

      await tester.tap(find.text(_result('1').name));
      await tester.pumpAndSettle();

      expect(refused.map((call) => call.method), contains('addSubtitle'));
      expect(find.text(l10n.subtitleDownloadFailed), findsOneWidget);
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'the download is over, refused or not',
      );
      expect(find.byType(SubtitleSearchPage), findsOneWidget);
      expect(
        _insideStop(find.text(_result('1').name)),
        isTrue,
        reason: 'an unfocusable list on a remote has no exit but Back',
      );

      // And it takes the next press.
      final before = page.downloads.length;
      await tester.tap(find.text(_result('1').name));
      await tester.pumpAndSettle();
      expect(page.downloads.length, before + 1);
    });
  });

  group('every control answers a remote, a keyboard, a mouse and a tap', () {
    testWidgets('a language chip searches again in its language, pressed or '
        'selected from a remote', (tester) async {
      final page = await pumpSearch(tester, target: _episode);
      expect(page.provider.calls.single.language, 'en');

      // From the search button into the row, then one along.
      await _down(tester);
      expect(_focusedText(), 'English');
      await _press(tester, LogicalKeyboardKey.arrowRight);
      expect(_focusedText(), 'Hindi');
      await _press(tester, LogicalKeyboardKey.select);

      expect(page.provider.calls, hasLength(2));
      expect(page.provider.calls.last.language, 'hi');

      // Enter from a keyboard, the same as Select.
      await _press(tester, LogicalKeyboardKey.arrowRight);
      await _press(tester, LogicalKeyboardKey.enter);
      expect(page.provider.calls.last.language, 'bn');

      // And a tap.
      await tester.ensureVisible(find.text('Telugu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Telugu'));
      await tester.pumpAndSettle();
      expect(page.provider.calls.last.language, 'te');
    });

    testWidgets('down into the languages lands on the one searched in, and '
        'keeps it on screen', (tester) async {
      // A 1080p television at the density Android TV reports. The search
      // button sits over a chip far along the row, which is where the
      // remote's DOWN goes first: the row hands focus on to the language
      // searched in, and the chip passed through must not scroll that one out
      // of sight on its way.
      await pumpSearch(tester, target: _episode, size: const Size(960, 540));

      await _down(tester);
      expect(_focusedText(), 'English');
      final chip = tester.getRect(
        find
            .ancestor(of: find.text('English'), matching: find.byType(Focus))
            .first,
      );
      final row = tester.getRect(
        find
            .ancestor(
              of: find.text('English'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        chip.left >= row.left && chip.right <= row.right,
        isTrue,
        reason: 'the focused chip is off the row: $chip in $row',
      );
    });

    testWidgets('focus arriving on another language is handed to the one '
        'searched in, and that one stays on screen', (tester) async {
      // Where a remote's DOWN from the search button lands first, on the
      // television: the language under the button, fully in view and not the
      // one searched in. It began to scroll itself to the middle, the row
      // handed focus on to English - still in view, so its own reveal was
      // nothing to do - and the scroll carried English off the row.
      await pumpSearch(tester, target: _episode, size: const Size(960, 540));
      expect(_focused<IconButton>()?.tooltip, l10n.search);

      Focus.maybeOf(
        tester.element(find.text('Bengali')),
        createDependency: false,
      )!.requestFocus();
      await tester.pumpAndSettle();

      expect(_focusedText(), 'English');
      final chip = tester.getRect(
        find
            .ancestor(of: find.text('English'), matching: find.byType(Focus))
            .first,
      );
      final row = tester.getRect(
        find
            .ancestor(
              of: find.text('English'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        chip.left >= row.left && chip.right <= row.right,
        isTrue,
        reason: 'the focused language is off the row: $chip in $row',
      );
    });

    testWidgets('with the keyboard up the arrows are the keyboard\'s, and '
        'Select brings it back once it is put away', (tester) async {
      // Android TV's keyboard walks its letter grid with the arrows. Taking
      // them while it is up moved focus out of the field and closed it
      // mid-word.
      await pumpSearch(tester);
      expect(_focused<TextField>(), isNotNull);
      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      await tester.pump();

      await _down(tester);
      expect(_focused<TextField>(), isNotNull, reason: 'the keyboard\'s key');

      // Put away - Back on a remote: the arrows leave the field again, and
      // OK is how a remote gets back into it.
      tester.view.resetViewInsets();
      tester.testTextInput.hide();
      await tester.pump();
      await _press(tester, LogicalKeyboardKey.select);
      expect(_focused<TextField>(), isNotNull);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('the keyboard\'s search key searches and leaves focus on the '
        'search button, not nowhere', (tester) async {
      final page = await pumpSearch(tester);
      await tester.enterText(find.byType(TextField), 'Inception');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(page.provider.calls.single.query, 'Inception');
      expect(_focused<IconButton>()?.tooltip, l10n.search);
    });

    testWidgets('up and down leave the field on a remote', (tester) async {
      await pumpSearch(tester);
      expect(_focused<TextField>(), isNotNull);

      await _down(tester);
      expect(_focusedText(), 'English');

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focused<TextField>(), isNotNull);
    });

    testWidgets('up from the field is the page\'s Back, and down from Back is '
        'the field', (tester) async {
      await pumpSearch(tester, target: _episode);
      final back = MaterialLocalizations.of(
        tester.element(find.byType(SubtitleSearchPage)),
      ).backButtonTooltip;

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusedLabel(), back);

      await _down(tester);
      expect(_focused<TextField>(), isNotNull);

      await _press(tester, LogicalKeyboardKey.arrowUp);
      expect(_focusedLabel(), back);
    });

    testWidgets('a result takes Enter as well as a tap', (tester) async {
      final page = await pumpSearch(
        tester,
        target: _episode,
        downloadPath: '/tmp/subs/The.Show.S02E05.srt',
      );

      await _down(tester);
      await _down(tester);
      expect(_focusedText(), _result('1').name);
      await _press(tester, LogicalKeyboardKey.enter);

      expect(page.downloads.map((s) => s.id), <String>['1']);
      expect(onTheTab(), isTrue);
    });

    testWidgets('Tab walks every control, results included', (tester) async {
      await pumpSearch(tester, target: _episode, isTv: false);

      final seen = <String?>{};
      final start = FocusManager.instance.primaryFocus;
      for (var i = 0; i < 120; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        seen.add(
          _focused<IconButton>()?.tooltip ??
              (_focused<TextField>() != null ? 'field' : null) ??
              _focusedText() ??
              _focusedLabel(),
        );
        if (FocusManager.instance.primaryFocus == start) break;
      }

      final material = MaterialLocalizations.of(
        tester.element(find.byType(SubtitleSearchPage)),
      );
      expect(seen, contains(material.backButtonTooltip));
      expect(seen, contains('field'));
      expect(seen, contains(material.clearButtonTooltip));
      expect(seen, contains(l10n.search));
      expect(seen, containsAll(<String>['English', 'Hindi']));
      expect(seen, contains(_result('1').name));
      expect(
        seen,
        isNot(contains(l10n.searchSubtitlesOnline)),
        reason: 'the tab under the page is out of reach while it is up',
      );
    });

    testWidgets('Clear empties the field and takes the ids with it', (
      tester,
    ) async {
      final page = await pumpSearch(tester, target: _episode, isTv: false);
      final clear = MaterialLocalizations.of(
        tester.element(find.byType(SubtitleSearchPage)),
      ).clearButtonTooltip;

      await tester.tap(find.byTooltip(clear));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'The Show'), findsNothing);
      expect(find.byTooltip(clear), findsNothing, reason: 'nothing to clear');
      expect(
        _focused<TextField>(),
        isNotNull,
        reason: 'the button went with the text; focus waits for the next title',
      );

      // An empty field with the ids gone is nothing to search for.
      await tester.tap(find.byTooltip(l10n.search));
      await tester.pumpAndSettle();
      expect(page.provider.calls, hasLength(1), reason: 'only the open');
    });
  });

  group('Back walks one step', () {
    testWidgets('the page\'s Back button takes the panel back to the tab', (
      tester,
    ) async {
      final page = await pumpSearch(tester, target: _episode, isTv: false);
      final back = MaterialLocalizations.of(
        tester.element(find.byType(SubtitleSearchPage)),
      ).backButtonTooltip;

      await tester.tap(find.byTooltip(back));
      await tester.pumpAndSettle();

      expect(onTheTab(), isTrue);
      expect(page.closed, isEmpty);
    });

    testWidgets('Android\'s Back, and a remote\'s, step back to the Search '
        'online row; the next closes the panel', (tester) async {
      final page = await pumpSearch(tester, target: _episode);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(onTheTab(), isTrue);
      expect(page.closed, isEmpty, reason: 'one step, not the whole panel');
      expect(_focusedRow(), l10n.searchSubtitlesOnline);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(page.closed, <bool>[true]);
    });

    testWidgets('Escape steps back the same way', (tester) async {
      final page = await pumpSearch(tester, target: _episode);

      await _press(tester, LogicalKeyboardKey.escape);
      expect(onTheTab(), isTrue);
      expect(page.closed, isEmpty);
      expect(_focusedRow(), l10n.searchSubtitlesOnline);

      await _press(tester, LogicalKeyboardKey.escape);
      expect(page.closed, <bool>[true]);
    });

    testWidgets('a tap beside the drawer closes the whole panel, a step in '
        'or not', (tester) async {
      final page = await pumpSearch(tester, target: _episode, isTv: false);

      await tester.tapAt(const Offset(400, 700));
      await tester.pumpAndSettle();

      expect(page.closed, <bool>[true]);
      expect(find.byType(SubtitleSearchPage), findsNothing);
    });
  });

  group('on a television', () {
    testWidgets('focus waits on the search button while results load, and '
        'DOWN reaches the first result', (tester) async {
      final pending = Completer<List<OnlineSubtitle>>();
      final provider = _RecordingProvider()..respond = (_) => pending.future;
      await pumpSearch(
        tester,
        target: _episode,
        provider: provider,
        settle: false,
      );

      expect(find.byType(Shimmer), findsOneWidget);
      expect(
        _focused<IconButton>()?.tooltip,
        l10n.search,
        reason: 'a visible Retry while the network is out',
      );

      pending.complete(<OnlineSubtitle>[_result('1'), _result('2')]);
      await tester.pumpAndSettle();
      expect(
        _focused<IconButton>()?.tooltip,
        l10n.search,
        reason: 'results do not steal',
      );

      await _down(tester);
      await _down(tester);
      expect(_focusedText(), _result('1').name);
    });

    testWidgets('an unseeded search starts in the field', (tester) async {
      await pumpSearch(tester);

      expect(_focused<TextField>(), isNotNull);
    });

    testWidgets('the page never opens with nothing focused, which would give '
        'the arrows nowhere to go', (tester) async {
      await pumpSearch(tester, target: _episode);
      final focused = FocusManager.instance.primaryFocus;

      expect(focused, isNotNull);
      expect(focused, isNot(isA<FocusScopeNode>()));
      expect(
        focused!.context!.findAncestorWidgetOfExactType<SubtitleSearchPage>(),
        isNotNull,
      );
    });
  });

  group('under a thumb', () {
    testWidgets('the field is left alone, so no keyboard comes up unasked', (
      tester,
    ) async {
      await pumpSearch(tester, isTv: false);

      expect(_focused<TextField>(), isNull);
      expect(
        _focusedText(),
        'English',
        reason: 'focus is still somewhere a later key press can start from',
      );
    });
  });
}
