/// The subtitle files SkyStream reads and draws itself: the list that holds
/// them ([SideCarSubtitles]), how a pick survives a reopen ([matchSideCar]),
/// the Subtitles tab's rows for them, and the overlay that draws them
/// ([SideCarSubtitleView]).
library;

import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/side_car_subtitles.dart';
import 'package:skystream/features/player/domain/subtitle_cues.dart';
import 'package:skystream/features/player/domain/subtitle_style.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_tracks_tab.dart';
import 'package:skystream/features/player/presentation/vlc/side_car_subtitle_view.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// One line, [text], from [from] to [to] seconds.
String _srt(String text, {int from = 0, int to = 36000}) {
  String at(int seconds) {
    final h = (seconds ~/ 3600).toString().padLeft(2, '0');
    final m = (seconds ~/ 60 % 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s,000';
  }

  return '1\n${at(from)} --> ${at(to)}\n$text\n';
}

/// Привет as Windows-1251 writes it - the bytes of a Russian subtitle file
/// that is not Unicode. Read as Western, Auto's code page, it is Ïðèâåò.
const List<int> _privet = <int>[0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2];

/// A SubRip file of one line, [line], on screen for the first ten hours.
List<int> _srtBytes(List<int> line) => <int>[
  ...ascii.encode('1\n00:00:00,000 --> 10:00:00,000\n'),
  ...line,
  0x0A,
];

/// The line [subtitles] has on screen five seconds in.
String _line(SideCarSubtitles subtitles) =>
    subtitles.timeline.at(const Duration(seconds: 5)).single.text;

/// Serves [files] by URL, and keeps every request.
class _Files {
  _Files(this.files);

  final Map<String, String?> files;
  final List<(Uri, Map<String, String>?)> requests = [];

  Future<List<int>?> fetch(Uri url, Map<String, String>? headers) async {
    requests.add((url, headers));
    final text = files[url.toString()];
    return text == null ? null : utf8.encode(text);
  }
}

SideCarSource _source(
  String url, {
  String? label,
  String? language,
  Map<String, String>? headers,
}) => (url: Uri.parse(url), label: label, language: language, headers: headers);

/// The labels of every ticked row.
List<String> _selectedRows(WidgetTester tester) => tester
    .widgetList<PanelRow>(find.byType(PanelRow, skipOffstage: false))
    .where((row) => row.selected)
    .map((row) => row.label)
    .toList();

final class _PickedFile extends PlatformFile {
  _PickedFile(this.uri);

  @override
  final Uri uri;

  @override
  String get name => uri.pathSegments.last;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('not needed: ${invocation.memberName}');
}

final class _FakeFilePicker extends FilePickerPlatform {
  _FakeFilePicker(this.pick);

  final Uri pick;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _PickedFile(pick);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SideCarSubtitles', () {
    test('lists files without fetching any', () {
      final files = _Files({});
      final subtitles = SideCarSubtitles(fetch: files.fetch);
      addTearDown(subtitles.dispose);

      final tracks = subtitles.replaceSourceTracks([
        _source('https://x/en.srt', label: 'English', language: 'en'),
        _source('https://x/fr.srt', label: 'French', language: 'fr'),
      ]);

      expect(tracks.map((t) => t.label), ['English', 'French']);
      expect(subtitles.tracks, tracks);
      expect(subtitles.active, isNull);
      expect(files.requests, isEmpty, reason: 'fetched when shown, not listed');
    });

    test('reads a file in the code page set when it is read', () async {
      final subtitles = SideCarSubtitles(
        fetch: (url, headers) async => _srtBytes(_privet),
        encoding: 'Windows-1251',
      );
      addTearDown(subtitles.dispose);
      final [track] = subtitles.replaceSourceTracks([
        _source('https://x/ru.srt'),
      ]);

      await subtitles.select(track);
      expect(_line(subtitles), 'Привет');
    });

    test('reads its files again when the code page changes, from the bytes '
        'it kept', () async {
      final fetched = <Uri>[];
      final subtitles = SideCarSubtitles(
        fetch: (url, headers) async {
          fetched.add(url);
          return _srtBytes(_privet);
        },
      );
      addTearDown(subtitles.dispose);
      final [track] = subtitles.replaceSourceTracks([
        _source('https://x/ru.srt'),
      ]);
      await subtitles.select(track);
      expect(_line(subtitles), 'Ïðèâåò', reason: 'Auto reads it as Western');

      var told = 0;
      subtitles.addListener(() => told++);
      subtitles.encoding = 'Windows-1251';
      await pumpEventQueue();

      expect(_line(subtitles), 'Привет', reason: 'the line on screen');
      expect(told, greaterThan(0), reason: 'the view is told to draw it');
      expect(fetched, hasLength(1), reason: 'the bytes kept, not the network');
    });

    test('reads a playlist\'s segments again too', () async {
      final fetched = <Uri>[];
      final subtitles = SideCarSubtitles(
        fetch: (url, headers) async {
          fetched.add(url);
          return url.path.endsWith('.m3u8')
              ? ascii.encode('#EXTM3U\n#EXTINF:10,\n0.vtt\n#EXT-X-ENDLIST\n')
              : <int>[
                  ...ascii.encode('WEBVTT\n\n00:00:00.000 --> 10:00:00.000\n'),
                  ..._privet,
                  0x0A,
                ];
        },
      );
      addTearDown(subtitles.dispose);
      final [track] = subtitles.replaceSourceTracks([
        _source('https://x/ru.m3u8'),
      ]);
      await subtitles.select(track);
      expect(_line(subtitles), 'Ïðèâåò');

      subtitles.encoding = 'Windows-1251';
      await pumpEventQueue();

      expect(_line(subtitles), 'Привет');
      expect(fetched, hasLength(2), reason: 'the playlist and its segment');
    });

    test('a file on its way when the code page changes is read in the new '
        'one', () async {
      final arrival = Completer<List<int>?>();
      final subtitles = SideCarSubtitles(fetch: (_, _) => arrival.future);
      addTearDown(subtitles.dispose);
      final [track] = subtitles.replaceSourceTracks([
        _source('https://x/ru.srt'),
      ]);

      final shown = subtitles.select(track);
      subtitles.encoding = 'Windows-1251';
      arrival.complete(_srtBytes(_privet));
      expect(await shown, isTrue);
      await pumpEventQueue();

      expect(_line(subtitles), 'Привет');
    });

    test(
      'fetches a file when it is first shown, with its headers, once',
      () async {
        final files = _Files({'https://x/en.srt': _srt('Hello')});
        final subtitles = SideCarSubtitles(fetch: files.fetch);
        addTearDown(subtitles.dispose);
        final [english] = subtitles.replaceSourceTracks([
          _source('https://x/en.srt', headers: {'Referer': 'https://site/'}),
        ]);

        expect(await subtitles.select(english), isTrue);
        expect(subtitles.active, english);
        expect(subtitles.statusOf(english), SideCarStatus.ready);
        expect(
          subtitles.timeline.at(const Duration(seconds: 5)).single.text,
          'Hello',
        );
        expect(files.requests.single.$2, {'Referer': 'https://site/'});

        await subtitles.select(null);
        await subtitles.select(english);
        expect(files.requests, hasLength(1), reason: 'read once, kept');
      },
    );

    test('is on at once, and fills in as the file arrives', () async {
      final arrival = Completer<List<int>?>();
      final subtitles = SideCarSubtitles(fetch: (_, _) => arrival.future);
      addTearDown(subtitles.dispose);
      final [english] = subtitles.replaceSourceTracks([
        _source('https://x/en.srt'),
      ]);
      var notified = 0;
      subtitles.addListener(() => notified++);

      final shown = subtitles.select(english);

      expect(subtitles.active, english);
      expect(subtitles.statusOf(english), SideCarStatus.loading);
      expect(subtitles.timeline.isEmpty, isTrue);

      arrival.complete(utf8.encode(_srt('Hello')));
      expect(await shown, isTrue);
      expect(subtitles.statusOf(english), SideCarStatus.ready);
      expect(subtitles.timeline.isEmpty, isFalse);
      expect(notified, greaterThanOrEqualTo(2));
    });

    test('a file that cannot be fetched goes off, says so, and is tried '
        'again when picked again', () async {
      final files = _Files({'https://x/en.srt': null});
      final subtitles = SideCarSubtitles(fetch: files.fetch);
      addTearDown(subtitles.dispose);
      final [english] = subtitles.replaceSourceTracks([
        _source('https://x/en.srt'),
      ]);

      expect(await subtitles.select(english), isFalse);
      expect(subtitles.active, isNull);
      expect(subtitles.statusOf(english), SideCarStatus.failed);

      files.files['https://x/en.srt'] = _srt('Back');
      expect(await subtitles.select(english), isTrue);
      expect(files.requests, hasLength(2));
    });

    test('a file in no format read here leaves the list for libVLC', () async {
      final handed = <SideCarTrack>[];
      final subtitles = SideCarSubtitles(
        fetch: _Files({'https://x/en.sub': '{1}{25}MicroDVD'}).fetch,
        onUnreadable: handed.add,
      );
      addTearDown(subtitles.dispose);
      final [english] = subtitles.replaceSourceTracks([
        _source('https://x/en.sub'),
      ]);

      expect(await subtitles.select(english), isFalse);

      expect(handed, [english]);
      expect(subtitles.tracks, isEmpty);
      expect(subtitles.active, isNull);
    });

    test('a new source replaces its files and keeps the viewer\'s, on if it '
        'was', () async {
      final subtitles = SideCarSubtitles(
        fetch: _Files({'file:///subs/mine.srt': _srt('Mine')}).fetch,
      );
      addTearDown(subtitles.dispose);
      subtitles.replaceSourceTracks([_source('https://x/en.srt')]);
      final mine = subtitles.addViewerTrack(Uri.file('/subs/mine.srt'));
      await subtitles.select(mine);

      final next = subtitles.replaceSourceTracks([_source('https://y/es.srt')]);

      expect(subtitles.tracks, [...next, mine]);
      expect(subtitles.active, mine);
      expect(subtitles.timeline.isEmpty, isFalse);
    });

    test('a source\'s file that was on goes with its source', () async {
      final subtitles = SideCarSubtitles(
        fetch: _Files({'https://x/en.srt': _srt('Hello')}).fetch,
      );
      addTearDown(subtitles.dispose);
      final [english] = subtitles.replaceSourceTracks([
        _source('https://x/en.srt'),
      ]);
      await subtitles.select(english);

      subtitles.replaceSourceTracks([_source('https://y/en.srt')]);

      expect(subtitles.active, isNull);
      expect(subtitles.timeline.isEmpty, isTrue);
    });

    test('a load its file outlived changes nothing', () async {
      final arrival = Completer<List<int>?>();
      final subtitles = SideCarSubtitles(fetch: (_, _) => arrival.future);
      addTearDown(subtitles.dispose);
      final [english] = subtitles.replaceSourceTracks([
        _source('https://x/en.srt'),
      ]);
      final shown = subtitles.select(english);

      subtitles.clear();
      arrival.complete(utf8.encode(_srt('Late')));

      expect(await shown, isFalse);
      expect(subtitles.tracks, isEmpty);
      expect(subtitles.active, isNull);
      expect(subtitles.timeline.isEmpty, isTrue);
    });

    test('a load that finishes after dispose is ignored', () async {
      final arrival = Completer<List<int>?>();
      final subtitles = SideCarSubtitles(fetch: (_, _) => arrival.future);
      final [english] = subtitles.replaceSourceTracks([
        _source('https://x/en.srt'),
      ]);
      final shown = subtitles.select(english);

      subtitles.dispose();
      arrival.complete(utf8.encode(_srt('Late')));

      expect(await shown, isFalse);
    });

    test('a track\'s language comes from its tag, else from its label', () {
      final subtitles = SideCarSubtitles(fetch: _Files({}).fetch);
      addTearDown(subtitles.dispose);
      final tracks = subtitles.replaceSourceTracks([
        _source('https://x/1.srt', language: 'eng', label: 'Spanish'),
        _source('https://x/2.srt', label: 'Portuguese (Brazil)'),
        _source('https://x/3.srt', language: 'und', label: 'Subtitle 3'),
      ]);

      expect(tracks.map((t) => t.languageCode), ['en', 'pt', null]);
    });
  });

  group('matchSideCar', () {
    List<SideCarTrack> tracks(List<SideCarSource> sources) {
      final subtitles = SideCarSubtitles(fetch: _Files({}).fetch);
      addTearDown(subtitles.dispose);
      return subtitles.replaceSourceTracks(sources);
    }

    test('finds the same file first', () {
      final [before] = tracks([_source('https://x/en.srt', language: 'en')]);
      final after = tracks([
        _source('https://y/en.srt', language: 'en'),
        _source('https://x/en.srt', language: 'en'),
      ]);

      expect(matchSideCar(after, before), after[1]);
    });

    test('then the same language and label, then the same language', () {
      final [before] = tracks([
        _source('https://x/sdh.srt', language: 'en', label: 'English SDH'),
      ]);
      final after = tracks([
        _source('https://y/fr.srt', language: 'fr', label: 'English SDH'),
        _source('https://y/en.srt', language: 'en', label: 'English'),
        _source('https://y/sdh.srt', language: 'en', label: 'English SDH'),
      ]);

      expect(matchSideCar(after, before), after[2]);
      expect(matchSideCar(after.sublist(0, 2), before), after[1]);
    });

    test('a language that is gone is not answered by a label', () {
      final [before] = tracks([
        _source('https://x/en.srt', language: 'en', label: 'Subs'),
      ]);
      final after = tracks([
        _source('https://y/fr.srt', language: 'fr', label: 'Subs'),
      ]);

      expect(matchSideCar(after, before), isNull);
    });

    test('with no language, the same label', () {
      final [before] = tracks([_source('https://x/a.srt', label: 'Subs 2')]);
      final after = tracks([
        _source('https://y/a.srt', label: 'Subs 1'),
        _source('https://y/b.srt', label: 'Subs 2'),
      ]);

      expect(matchSideCar(after, before), after[1]);
      expect(matchSideCar(after.sublist(0, 1), before), isNull);
    });
  });

  group('the Subtitles tab', () {
    late FakeVlcEngine engine;
    late VlcPlayerController controller;
    late SideCarSubtitles subtitles;
    late _Files files;

    setUp(() async {
      engine = FakeVlcEngine()
        ..subtitle = <Map<String, Object?>>[
          <String, Object?>{'id': 3, 'name': 'Commentary'},
        ]
        ..activeSubtitleId = 3
        ..install();
      controller = await engine.attach();
      await engine.emit(<String, Object?>{'state': 'paused'});
      files = _Files({
        'https://x/en.srt': _srt('Hello'),
        'https://x/fr.srt': null,
      });
      subtitles = SideCarSubtitles(fetch: files.fetch);
    });

    tearDown(() {
      subtitles.dispose();
      controller.dispose();
      engine.dispose();
    });

    Future<void> pumpTab(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerTracksTab(
              controller: controller,
              kind: PlayerTrackKind.subtitle,
              tracks: const <VlcTrackDescription>[
                VlcTrackDescription(id: 3, name: 'Commentary'),
              ],
              trackInfo: const <VlcMediaTrackInfo>[],
              sideCars: subtitles,
              onTracksChanged: () {},
              onOpenPage: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the delay tells a screen reader what a step would make it', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpTab(tester);

      final delay = tester.getSemantics(find.byType(PanelStepperRow));
      expect(delay.value, '+0ms');
      expect(delay.increasedValue, '+100ms');
      expect(delay.decreasedValue, '-100ms');
      semantics.dispose();
    });

    testWidgets('lists files after the video\'s own tracks', (tester) async {
      subtitles.replaceSourceTracks([
        _source('https://x/en.srt', label: 'English'),
        _source('https://x/fr.srt', language: 'fr'),
      ]);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpTab(tester);

      final labels = tester
          .widgetList<PanelRow>(find.byType(PanelRow, skipOffstage: false))
          .map((row) => row.label)
          .toList();
      expect(labels.take(4), [l10n.off, 'Commentary', 'English', 'French']);
      expect(_selectedRows(tester), ['Commentary']);
    });

    testWidgets('a file turns on over libVLC\'s own, which goes off', (
      tester,
    ) async {
      subtitles.replaceSourceTracks([
        _source('https://x/en.srt', label: 'English'),
      ]);
      await pumpTab(tester);

      await tester.tap(find.widgetWithText(PanelRow, 'English'));
      await tester.pumpAndSettle();

      expect(subtitles.active?.label, 'English');
      expect(engine.callsTo('disableSubtitle'), hasLength(1));
      await engine.emit(<String, Object?>{'state': 'paused'});
      await tester.pumpAndSettle();
      expect(_selectedRows(tester), ['English']);
    });

    testWidgets('a track inside the video takes the file off', (tester) async {
      final [english] = subtitles.replaceSourceTracks([
        _source('https://x/en.srt', label: 'English'),
      ]);
      await subtitles.select(english);
      engine.activeSubtitleId = -1;
      await engine.emit(<String, Object?>{'state': 'paused'});
      await pumpTab(tester);
      expect(_selectedRows(tester), ['English']);

      await tester.tap(find.widgetWithText(PanelRow, 'Commentary'));
      await tester.pumpAndSettle();

      expect(subtitles.active, isNull);
      expect(engine.activeSubtitleId, 3);
      await engine.emit(<String, Object?>{'state': 'paused'});
      await tester.pumpAndSettle();
      expect(_selectedRows(tester), ['Commentary']);
    });

    testWidgets(
      'a file still arriving says so, and one that failed says that',
      (tester) async {
        final arrival = Completer<List<int>?>();
        subtitles.dispose();
        subtitles = SideCarSubtitles(
          fetch: (url, _) =>
              url.path.endsWith('fr.srt') ? Future.value(null) : arrival.future,
        );
        final [english, french] = subtitles.replaceSourceTracks([
          _source('https://x/en.srt', label: 'English'),
          _source('https://x/fr.srt', label: 'French'),
        ]);
        final l10n = await AppLocalizations.delegate.load(const Locale('en'));
        await pumpTab(tester);

        unawaited(subtitles.select(english));
        await tester.pump();
        expect(
          tester
              .widget<PanelRow>(find.widgetWithText(PanelRow, 'English'))
              .detail,
          l10n.loading,
        );

        await subtitles.select(french);
        await tester.pump();
        expect(
          tester
              .widget<PanelRow>(find.widgetWithText(PanelRow, 'French'))
              .detail,
          l10n.failed,
        );

        arrival.complete(utf8.encode(_srt('Hello')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<PanelRow>(find.widgetWithText(PanelRow, 'English'))
              .detail,
          isNull,
        );
      },
    );

    testWidgets('a file from the device is drawn by SkyStream, not handed to '
        'libVLC', (tester) async {
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _FakeFilePicker(Uri.file('/subs/mine.srt'));
      addTearDown(() => FilePickerPlatform.instance = previous);
      files.files['file:///subs/mine.srt'] = _srt('Mine');
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpTab(tester);

      await tester.tap(find.text(l10n.loadSubtitleFile));
      await tester.pumpAndSettle();

      expect(engine.callsTo('addSubtitle'), isEmpty);
      expect(subtitles.tracks.single.label, 'mine.srt');
      expect(subtitles.tracks.single.origin, SideCarOrigin.viewer);
      expect(subtitles.active, subtitles.tracks.single);
      expect(find.widgetWithText(PanelRow, 'mine.srt'), findsOneWidget);
    });
  });

  group('SideCarSubtitleView', () {
    late FakeVlcEngine engine;
    late VlcPlayerController controller;
    late SideCarSubtitles subtitles;

    setUp(() async {
      engine = FakeVlcEngine()..install();
      controller = await engine.attach();
      subtitles = SideCarSubtitles(
        fetch: _Files({
          'https://x/en.srt':
              '1\n00:00:05,000 --> 00:00:08,000\nFirst\n\n'
              '2\n00:00:10,000 --> 00:00:12,000\n{\\an8}Up top\n',
        }).fetch,
      );
      final [english] = subtitles.replaceSourceTracks([
        _source('https://x/en.srt'),
      ]);
      await subtitles.select(english);
    });

    tearDown(() {
      subtitles.dispose();
      controller.dispose();
      engine.dispose();
    });

    Future<void> at(int milliseconds, {int delayMs = 0}) =>
        engine.emit(<String, Object?>{
          'state': 'paused',
          'position': milliseconds,
          'subtitleDelay': delayMs * 1000,
        });

    Future<void> pumpView(
      WidgetTester tester, {
      double bottomInset = 0,
      PlayerSettings settings = const PlayerSettings(),
      SideCarSubtitles? files,
    }) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SideCarSubtitleView(
              controller: controller,
              subtitles: files ?? subtitles,
              settings: settings,
              bottomInset: bottomInset,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// The layer under the text that draws its outline, or null when none is
    /// drawn: two copies of a line means the first is the stroke.
    TextStyle? stroke(WidgetTester tester, String line) {
      final copies = tester.widgetList<Text>(find.text(line)).toList();
      return copies.length < 2 ? null : copies.first.textSpan!.style;
    }

    TextStyle fill(WidgetTester tester, String line) =>
        tester.widget<Text>(find.text(line).last).textSpan!.style!;

    testWidgets('draws the line due now, and nothing between lines', (
      tester,
    ) async {
      await at(6000);
      await pumpView(tester);
      expect(find.text('First'), findsWidgets);

      await at(9000);
      await tester.pump();
      expect(find.text('First'), findsNothing);
    });

    testWidgets('follows the subtitle delay', (tester) async {
      await at(4000);
      await pumpView(tester);
      expect(find.text('First'), findsNothing);

      // Two seconds early: the line due at five shows at three.
      await at(4000, delayMs: -2000);
      await tester.pump();
      expect(find.text('First'), findsWidgets);
    });

    testWidgets('while playing, puts a line up on its time between the '
        'engine\'s reports', (tester) async {
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 4000,
      });
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SideCarSubtitleView(
              controller: controller,
              subtitles: subtitles,
              settings: const PlayerSettings(),
            ),
          ),
        ),
      );
      expect(find.text('First'), findsNothing);

      // No report from the engine for the next second; the line is due at
      // five seconds all the same.
      await tester.pump(const Duration(milliseconds: 990));
      expect(find.text('First'), findsNothing);
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('First'), findsWidgets);

      // A playing controller keeps a stall timer armed.
      await engine.emit(<String, Object?>{'state': 'paused', 'position': 5010});
      await tester.pump();
    });

    testWidgets('does not run on past a second without a report', (
      tester,
    ) async {
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 3500,
      });
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SideCarSubtitleView(
              controller: controller,
              subtitles: subtitles,
              settings: const PlayerSettings(),
            ),
          ),
        ),
      );

      // Stalled without saying so: the line at five seconds waits for the
      // engine rather than running over a frozen picture.
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('First'), findsNothing);

      await engine.emit(<String, Object?>{'state': 'paused', 'position': 3500});
      await tester.pump();
    });

    testWidgets(
      'a late VLC timestamp does not briefly hide an active SRT cue',
      (tester) async {
        await engine.emit(<String, Object?>{
          'state': 'playing',
          'position': 5200,
        });
        await pumpView(tester);
        expect(find.text('First'), findsWidgets);

        // The overlay has already displayed 5.2 s, but Android can publish an
        // older snapshot just after it. This is clock jitter, not a seek.
        await engine.emit(<String, Object?>{
          'state': 'playing',
          'position': 4900,
        });
        await tester.pump();
        expect(find.text('First'), findsWidgets);

        await engine.emit(<String, Object?>{
          'state': 'paused',
          'position': 4900,
        });
        await tester.pump();
      },
    );

    testWidgets('a late VLC timestamp does not replay a finished SRT cue', (
      tester,
    ) async {
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 8100,
      });
      await pumpView(tester);
      expect(find.text('First'), findsNothing);

      // Before the fix, rewinding the reported position across the 8 s cue
      // boundary resurrected the expired line for a frame: a visible blink.
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 7900,
      });
      await tester.pump();
      expect(find.text('First'), findsNothing);

      await engine.emit(<String, Object?>{'state': 'paused', 'position': 7900});
      await tester.pump();
    });

    testWidgets('buffering with an older timestamp holds the visible cue', (
      tester,
    ) async {
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 5200,
      });
      await pumpView(tester);
      expect(find.text('First'), findsWidgets);

      await engine.emit(<String, Object?>{
        'state': 'buffering',
        'position': 4900,
      });
      await tester.pump();
      expect(find.text('First'), findsWidgets);

      await engine.emit(<String, Object?>{'state': 'paused', 'position': 4900});
      await tester.pump();
    });

    testWidgets('a real backward seek still shows the earlier cue', (
      tester,
    ) async {
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 11000,
      });
      await pumpView(tester);
      expect(find.text('Up top'), findsWidgets);

      await controller.seekTo(const Duration(seconds: 6));
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 6000,
      });
      await tester.pump();
      expect(find.text('First'), findsWidgets);
      expect(find.text('Up top'), findsNothing);

      await engine.emit(<String, Object?>{'state': 'paused', 'position': 6000});
      await tester.pump();
    });

    testWidgets('paused seeking and subtitle delay still move the clock back', (
      tester,
    ) async {
      await at(8100);
      await pumpView(tester);
      expect(find.text('First'), findsNothing);

      // A fine seek while paused, smaller than any jitter tolerance.
      await controller.seekTo(const Duration(milliseconds: 7900));
      await at(7900);
      await tester.pump();
      expect(find.text('First'), findsWidgets);

      // A four-second delay moves the subtitle timeline back on purpose.
      await at(7900, delayMs: 4000);
      await tester.pump();
      expect(find.text('First'), findsNothing);
    });

    testWidgets('a subtitle delay moves the lines either way', (tester) async {
      await at(9000);
      await pumpView(tester);
      expect(find.text('First'), findsNothing);
      expect(find.text('Up top'), findsNothing);

      // Shown 1.5 s early, the line due at ten is up at 8.5.
      await at(9000, delayMs: -1500);
      await tester.pump();
      expect(find.text('Up top'), findsWidgets);

      // Shown 2 s late, the line that ended at eight is up again.
      await at(9000, delayMs: 2000);
      await tester.pump();
      expect(find.text('First'), findsWidgets);
      expect(find.text('Up top'), findsNothing);

      await at(9000);
      await tester.pump();
      expect(find.text('First'), findsNothing);
    });

    testWidgets('draws nothing once the file is off', (tester) async {
      await at(6000);
      await pumpView(tester);
      expect(find.text('First'), findsWidgets);

      await subtitles.select(null);
      await tester.pump();
      expect(find.text('First'), findsNothing);
    });

    testWidgets('sizes the text the way the settings preview does', (
      tester,
    ) async {
      await at(6000);
      await pumpView(tester);

      final text = tester.widget<Text>(find.text('First').last);
      final expected = subtitleFontSize(
        const PlayerSettings(),
        const Size(1280, 720),
      );
      expect(text.textSpan!.style!.fontSize, expected);
    });

    testWidgets('lifts bottom lines over the controls, and puts a top line '
        'at the top', (tester) async {
      await at(6000);
      await pumpView(tester);
      final low = tester.getBottomLeft(find.text('First').last).dy;

      await pumpView(tester, bottomInset: 108);
      await tester.pump(const Duration(milliseconds: 300));
      final lifted = tester.getBottomLeft(find.text('First').last).dy;
      expect(lifted, lessThan(low - 80));

      await at(11000);
      await tester.pump();
      expect(tester.getTopLeft(find.text('Up top').last).dy, lessThan(100));
    });

    testWidgets('every size step from 10 to 80 draws a different size', (
      tester,
    ) async {
      await at(6000);
      final drawn = <double>[];
      for (var size = 10; size <= 80; size++) {
        await pumpView(
          tester,
          settings: PlayerSettings(subtitleSize: size.toDouble()),
        );
        drawn.add(fill(tester, 'First').fontSize!);
      }
      for (var i = 1; i < drawn.length; i++) {
        expect(drawn[i], greaterThan(drawn[i - 1]), reason: 'size ${10 + i}');
      }
    });

    testWidgets('outlines the letters as heavily as the viewer chose', (
      tester,
    ) async {
      await at(6000);
      const widths = <SubtitleOutline, double>{
        SubtitleOutline.thin: 2,
        SubtitleOutline.normal: 3.5,
        SubtitleOutline.thick: 5,
      };
      for (final MapEntry(key: outline, value: width) in widths.entries) {
        await pumpView(
          tester,
          settings: PlayerSettings(subtitleOutline: outline),
        );
        expect(
          stroke(tester, 'First')?.foreground?.strokeWidth,
          width,
          reason: '$outline',
        );
      }

      await pumpView(
        tester,
        settings: const PlayerSettings(subtitleOutline: SubtitleOutline.none),
      );
      expect(stroke(tester, 'First'), isNull, reason: 'none draws no stroke');
      expect(find.text('First'), findsOneWidget);
    });

    testWidgets('lifts bottom lines by the share of the picture asked for, '
        'and the controls still lift them further', (tester) async {
      await at(6000);
      await pumpView(tester);
      final low = tester.getBottomLeft(find.text('First').last).dy;

      // A tenth of the 720 px frame.
      await pumpView(
        tester,
        settings: const PlayerSettings(subtitleRaise: 0.1),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getBottomLeft(find.text('First').last).dy,
        closeTo(low - 72, 0.01),
      );

      // The bars' 108 px and half a margin beat the lift's: the larger of
      // the two, never their sum.
      await pumpView(
        tester,
        bottomInset: 108,
        settings: const PlayerSettings(subtitleRaise: 0.1),
      );
      await tester.pump(const Duration(milliseconds: 300));
      const margin = 720 * 0.06;
      expect(
        tester.getBottomLeft(find.text('First').last).dy,
        closeTo(low - (108 + margin / 2 - margin), 0.01),
      );
    });

    testWidgets('a lift leaves a line at the top where it is', (tester) async {
      await at(11000);
      await pumpView(tester);
      final top = tester.getTopLeft(find.text('Up top').last).dy;

      await pumpView(
        tester,
        settings: const PlayerSettings(subtitleRaise: 0.2),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getTopLeft(find.text('Up top').last).dy, top);
    });

    testWidgets('draws bold, in the font and at the opacity chosen', (
      tester,
    ) async {
      await at(6000);
      await pumpView(tester);
      expect(fill(tester, 'First').fontWeight, FontWeight.w600);
      expect(fill(tester, 'First').fontFamily, isNull);
      expect(fill(tester, 'First').color, const Color(0xFFFFFFFF));

      await pumpView(
        tester,
        settings: const PlayerSettings(
          subtitleBold: true,
          subtitleFont: SubtitleFont.monospace,
          subtitleTextOpacity: 0.5,
        ),
      );
      final style = fill(tester, 'First');
      expect(style.fontWeight, FontWeight.w800);
      expect(style.fontFamily, subtitleFontFamily(SubtitleFont.monospace));
      expect(style.color?.toARGB32(), 0x80FFFFFF);
      expect(
        stroke(tester, 'First')?.fontWeight,
        FontWeight.w800,
        reason: 'the outline is drawn round the same letters',
      );
    });

    testWidgets('a bold line in a bold style is bolder still', (tester) async {
      final marked = SideCarSubtitles(
        fetch: _Files({'https://x/b.srt': _srt('<b>Loud</b> quiet')}).fetch,
      );
      addTearDown(marked.dispose);
      final [track] = marked.replaceSourceTracks([_source('https://x/b.srt')]);
      await marked.select(track);
      await at(6000);

      FontWeight? loud() =>
          (tester.widget<Text>(find.text('Loud quiet').last).textSpan!
                  as TextSpan)
              .children!
              .first
              .style!
              .fontWeight;

      await pumpView(tester, files: marked);
      expect(loud(), FontWeight.w800);

      await pumpView(
        tester,
        files: marked,
        settings: const PlayerSettings(subtitleBold: true),
      );
      expect(loud(), FontWeight.w900);
    });
  });

  /// The view timing lines against a playing engine. Each test attaches its
  /// controller in the test body: the timer the view sets when the engine
  /// reports is made in the zone the report arrives in, and only the body's
  /// zone runs on the fake time the test pumps.
  group('SideCarSubtitleView timing', () {
    late FakeVlcEngine engine;
    late VlcPlayerController controller;
    late SideCarSubtitles subtitles;

    setUp(() async {
      engine = FakeVlcEngine()..install();
      subtitles = SideCarSubtitles(
        fetch: _Files({
          'https://x/en.srt':
              '1\n00:00:05,000 --> 00:00:08,000\nFirst\n\n'
              '2\n00:00:10,000 --> 00:00:12,000\n{\\an8}Up top\n',
        }).fetch,
      );
      final [english] = subtitles.replaceSourceTracks([
        _source('https://x/en.srt'),
      ]);
      await subtitles.select(english);
    });

    tearDown(() {
      subtitles.dispose();
      controller.dispose();
      engine.dispose();
    });

    Future<void> attach() async {
      controller = await engine.attach();
    }

    Future<void> pumpView(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SideCarSubtitleView(
              controller: controller,
              subtitles: subtitles,
              settings: const PlayerSettings(),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a delay set while playing times the next line by it', (
      tester,
    ) async {
      await attach();
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 4000,
      });
      await pumpView(tester);

      // Half a second early: the line due at five is up at 4.5.
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 4000,
        'subtitleDelay': -500000,
      });
      await tester.pump(const Duration(milliseconds: 490));
      expect(find.text('First'), findsNothing);
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('First'), findsWidgets);

      await engine.emit(<String, Object?>{'state': 'paused', 'position': 4510});
      await tester.pump();
    });

    testWidgets('resuming after a pause does not run the clock on over the '
        'paused time', (tester) async {
      await attach();
      // Every backend reports the position it paused at again on resume; the
      // next time update comes later.
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 4000,
      });
      await pumpView(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await engine.emit(<String, Object?>{'state': 'paused', 'position': 4200});
      await tester.pump(const Duration(seconds: 3));

      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 4200,
      });
      await tester.pump();
      expect(find.text('First'), findsNothing, reason: 'shown 0.8 s early');
      await tester.pump(const Duration(milliseconds: 790));
      expect(find.text('First'), findsNothing);
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('First'), findsWidgets);

      await engine.emit(<String, Object?>{'state': 'paused', 'position': 5010});
      await tester.pump();
    });

    testWidgets('a half-second seek back while playing shows the line it '
        'returns into', (tester) async {
      await attach();
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 8100,
      });
      await pumpView(tester);
      expect(find.text('First'), findsNothing);

      // The player makes these itself, nudging a stalled stream for one.
      await controller.seekTo(const Duration(milliseconds: 7600));
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 7600,
      });
      await tester.pump();
      expect(find.text('First'), findsWidgets);

      await engine.emit(<String, Object?>{'state': 'paused', 'position': 7600});
      await tester.pump();
    });

    testWidgets('a 1.5 s seek back from the run-on clock is a seek, not '
        'jitter', (tester) async {
      await attach();
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 8000,
      });
      await pumpView(tester);
      await tester.pump(const Duration(milliseconds: 900));
      expect(find.text('First'), findsNothing);

      await controller.seekTo(const Duration(milliseconds: 7400));
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 7400,
      });
      await tester.pump();
      expect(find.text('First'), findsWidgets);

      await engine.emit(<String, Object?>{'state': 'paused', 'position': 7400});
      await tester.pump();
    });

    testWidgets('pause, seek a little back, play: the line comes back and '
        'stays', (tester) async {
      await attach();
      // VLCKit does not report a seek made while paused, and on play reports
      // the old time once before the new one.
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 8100,
      });
      await pumpView(tester);
      await engine.emit(<String, Object?>{'state': 'paused', 'position': 8100});
      await tester.pump();
      expect(find.text('First'), findsNothing);

      await controller.seekTo(const Duration(milliseconds: 7700));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('First'), findsWidgets);
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 8100,
      });
      await tester.pump(const Duration(milliseconds: 10));
      expect(find.text('First'), findsWidgets);
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 7700,
      });
      await tester.pump();
      expect(find.text('First'), findsWidgets);

      await engine.emit(<String, Object?>{'state': 'paused', 'position': 7700});
      await tester.pump();
    });

    testWidgets('one stale report seconds behind, with no seek asked for, '
        'does not flash an old line', (tester) async {
      await attach();
      // Measured on HLS: straight after a 10 s seek the adaptive demuxer
      // reported 29078, then 22161, then 29277.
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 11000,
      });
      await pumpView(tester);
      expect(find.text('Up top'), findsWidgets);

      await tester.pump(const Duration(milliseconds: 250));
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 6000,
      });
      await tester.pump();
      expect(find.text('First'), findsNothing, reason: 'flashed an old line');
      expect(find.text('Up top'), findsWidgets);

      await tester.pump(const Duration(milliseconds: 250));
      await engine.emit(<String, Object?>{
        'state': 'playing',
        'position': 11500,
      });
      await tester.pump();
      expect(find.text('Up top'), findsWidgets);

      await engine.emit(<String, Object?>{
        'state': 'paused',
        'position': 11500,
      });
      await tester.pump();
    });
  });

  test('the timeline is the active file\'s, and empty with none on', () {
    final subtitles = SideCarSubtitles(fetch: _Files({}).fetch);
    addTearDown(subtitles.dispose);

    expect(subtitles.timeline, same(SubtitleTimeline.empty));
  });
}
