/// Side-car subtitles handed to the engine: what the Subtitles tab does when a
/// viewer adds one by hand with no screen behind the panel to draw it -
/// observed through the one fake every app-side player test drives, so the
/// argument shapes stay honest and the id growth on `addSubtitle` (100, 101,
/// ...) is the fake's own. The files SkyStream draws itself are
/// side_car_tracks_test.dart's.
///
/// The thing being pinned is libVLC 3's add-slave: it is *queued* to the
/// input thread, so the track does not exist when `addSubtitle` completes and
/// no list read in that turn can carry it.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/side_car_subtitles.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_tracks_tab.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// A snapshot that moves nothing but keeps the controller's stall watchdog
/// unarmed: a playing snapshot leaves a 1 s timer pending, and flutter_test
/// checks pending timers before any tear-down runs.
const Map<String, Object?> _paused = <String, Object?>{'state': 'paused'};

/// The labels of every ticked row - the tab's own reading of what the engine
/// says is playing.
List<String> _selectedRows(WidgetTester tester) => tester
    .widgetList<PanelRow>(find.byType(PanelRow, skipOffstage: false))
    .where((row) => row.selected)
    .map((row) => row.label)
    .toList();

/// The label of the row holding primary focus, or null when no row does.
String? _focusedRow() {
  final context = FocusManager.instance.primaryFocus?.context;
  return context?.findAncestorWidgetOfExactType<PanelRow>()?.label;
}

/// A file the picker "returned". Everything the tab reads comes off [uri] -
/// `path` included, which [PlatformFile] derives from it - so only [uri] and
/// [name] are answered here.
///
/// [PlatformFile] is a `base` class, so a double has to extend it and cannot
/// implement it; the [noSuchMethod] catch-all stands in for the rest, and
/// leaves the class standing when the package adds another member.
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

/// The device picker, answering with [pick] (null = the viewer cancelled)
/// instead of a dialog no test host can show.
final class _FakeFilePicker extends FilePickerPlatform {
  _FakeFilePicker(this.pick);

  final Uri? pick;

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
  }) async => pick == null ? null : _PickedFile(pick!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('preferredSubtitleIndex', () {
    test('finds the first entry written in the wanted language', () {
      expect(preferredSubtitleIndex(<String?>['es', 'en', 'en'], 'en'), 1);
    });

    test('matches on the primary subtag, so pt-BR satisfies pt', () {
      expect(preferredSubtitleIndex(<String?>['fr', 'pt-BR'], 'pt'), 1);
      expect(preferredSubtitleIndex(<String?>['PT_br'], 'pt'), 0);
    });

    test('treats und, empty and null as "no language", never a match', () {
      expect(preferredSubtitleIndex(<String?>['und', null, ''], 'en'), isNull);
      expect(preferredSubtitleIndex(<String?>['und'], 'und'), isNull);
      expect(preferredSubtitleIndex(<String?>['en'], null), isNull);
    });

    test('reads codes of either length and plain names as one language', () {
      expect(preferredSubtitleIndex(<String?>['fre', 'eng'], 'en'), 1);
      expect(preferredSubtitleIndex(<String?>['Hindi', 'English'], 'en'), 1);
      expect(preferredSubtitleIndex(<String?>['en-GB'], 'eng'), 0);
    });

    test('matches nothing it cannot name', () {
      expect(preferredSubtitleIndex(<String?>['Track 1', 'SDH'], 'en'), isNull);
    });
  });

  /// The engine, the controller and a paused first snapshot: what mid-playback
  /// looks like to a panel that is about to open.
  Future<VlcPlayerController> attach(FakeVlcEngine engine) async {
    engine.install();
    // Tear-downs run last-in first-out, so the controller goes first, while
    // the channel it sends `dispose` on still has a handler.
    addTearDown(engine.dispose);
    final controller = await engine.attach();
    addTearDown(controller.dispose);
    await engine.emit(_paused);
    return controller;
  }

  /// Answers the device picker with [pick] for the rest of the test.
  void pickerAnswers(Uri? pick) {
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _FakeFilePicker(pick);
    addTearDown(() => FilePickerPlatform.instance = previous);
  }

  /// The real panel, opened on Subtitles as a television opens it: focus goes
  /// into the list, and the panel's own revision listener is running - which
  /// is what re-reads the lists when the engine finally announces a side-car.
  Future<void> pumpPanelOnSubtitles(
    WidgetTester tester,
    VlcPlayerController controller,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final data = ValueNotifier<PanelData>(PanelData.empty);
    addTearDown(data.dispose);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerPanel(
            controller: controller,
            initialTab: PlayerPanelTab.subtitles,
            data: data,
            isTv: true,
            focusOnOpen: true,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The tab on its own, handed a list the caller controls - the way the panel
  /// hands it whatever the last read returned, however old that is by now.
  Future<void> pumpTracksTab(
    WidgetTester tester, {
    required VlcPlayerController controller,
    required PlayerTrackKind kind,
    required List<VlcTrackDescription> tracks,
    VoidCallback? onTracksChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerTracksTab(
            controller: controller,
            kind: kind,
            tracks: tracks,
            trackInfo: const <VlcMediaTrackInfo>[],
            onTracksChanged: onTracksChanged ?? () {},
            onOpenPage: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('a side-car the engine has only queued', () {
    /// One embedded track, playing, and an add-slave that behaves the way
    /// libVLC 3's does: queued to the input thread, so the ES does not exist
    /// when `addSubtitle` completes.
    FakeVlcEngine queuedEngine() => FakeVlcEngine()
      ..queueAddedSlaves = true
      ..subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 3, 'name': 'English'},
      ]
      ..activeSubtitleId = 3;

    testWidgets('is not re-read out of the engine before it exists', (
      tester,
    ) async {
      final engine = queuedEngine();
      final controller = await attach(engine);
      pickerAnswers(Uri.file('/subs/spanish.srt'));
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpPanelOnSubtitles(tester, controller);
      final readsAtOpen = engine.callsTo('getSubtitleTracks').length;

      await tester.tap(find.text(l10n.loadSubtitleFile));
      await tester.pumpAndSettle();

      expect(
        engine.callsTo('addSubtitle'),
        hasLength(1),
        reason: 'the file did reach the engine',
      );
      expect(
        engine.callsTo('getSubtitleTracks'),
        hasLength(readsAtOpen),
        reason:
            'libVLC 3 queues add-slave to the input thread, so a list read '
            'in this turn is still the pre-add one: it would put the panel '
            'back on a list without the file the viewer just picked, with '
            'nothing ticked, and re-anchor the D-pad on it. The reload waits '
            'for the engine to announce the track.',
      );
      expect(_selectedRows(tester), <String>[
        'English',
      ], reason: 'the tick still follows the engine, which has not moved yet');
    });

    testWidgets('is picked up, ticked and focused when the engine announces '
        'it', (tester) async {
      final engine = queuedEngine();
      final controller = await attach(engine);
      pickerAnswers(Uri.file('/subs/spanish.srt'));
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpPanelOnSubtitles(tester, controller);

      await tester.tap(find.text(l10n.loadSubtitleFile));
      await tester.pumpAndSettle();
      expect(find.text('spanish.srt'), findsNothing, reason: 'not landed yet');

      // ESAdded on Darwin and Android, the next poll on Windows and Linux:
      // the ES exists, add-slave's select flag has it on, and the snapshot
      // carries a moved trackRevision.
      await engine.landQueuedSlaves(_paused);
      await tester.pumpAndSettle();

      expect(find.text('spanish.srt'), findsOneWidget);
      expect(_selectedRows(tester), <String>['spanish.srt']);
      expect(
        _focusedRow(),
        'spanish.srt',
        reason: 'the reload re-anchors on what is playing now',
      );
    });

    testWidgets('that the engine refuses outright is absorbed, not thrown at '
        'the zone', (tester) async {
      final engine = queuedEngine()..refusedMethods = <String>{'addSubtitle'};
      final controller = await attach(engine);
      pickerAnswers(Uri.file('/subs/spanish.srt'));
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpPanelOnSubtitles(tester, controller);

      await tester.tap(find.text(l10n.loadSubtitleFile));
      await tester.pumpAndSettle();

      // The row's handler is unawaited: nothing downstream would catch this,
      // and the app installs no PlatformDispatcher.onError.
      expect(tester.takeException(), isNull);
      expect(_selectedRows(tester), <String>['English']);
    });
  });

  group('a track the engine refuses', () {
    testWidgets('does not move the tick, does not reach the zone, and gets '
        'the list read again', (tester) async {
      // The engine carries one subtitle track and has it on. The tab is
      // holding a list with a second row in it - a language the stream
      // dropped when it renegotiated, still on screen because the panel reads
      // the list once and holds it.
      final engine = FakeVlcEngine()
        ..subtitle = <Map<String, Object?>>[
          <String, Object?>{'id': 3, 'name': 'English'},
        ]
        ..activeSubtitleId = 3;
      final controller = await attach(engine);
      var reloads = 0;
      await pumpTracksTab(
        tester,
        controller: controller,
        kind: PlayerTrackKind.subtitle,
        tracks: const <VlcTrackDescription>[
          VlcTrackDescription(id: 3, name: 'English'),
          VlcTrackDescription(id: 7, name: 'German'),
        ],
        onTracksChanged: () => reloads++,
      );

      await tester.tap(find.text('German'));
      await tester.pumpAndSettle();

      expect(
        engine.callsTo('setSubtitleTrack'),
        hasLength(1),
        reason: 'the tap is the bare engine call, as it should be',
      );
      expect(
        tester.takeException(),
        isNull,
        reason:
            'the natives answer track_not_found here (Android when '
            'setAudioTrack comes back false, Darwin from the same guard) and '
            'the handler is unawaited: unabsorbed, it is a console trace and '
            'nothing else',
      );
      expect(_selectedRows(tester), <String>[
        'English',
      ], reason: 'nothing is optimistic: a refused set never moves the tick');
      expect(
        reloads,
        1,
        reason:
            'a refusal says the held list is out of date, so it is read again '
            'and the dead row goes',
      );
    });

    testWidgets('to switch off, or to take a delay, is absorbed too', (
      tester,
    ) async {
      final engine = FakeVlcEngine()
        ..subtitle = <Map<String, Object?>>[
          <String, Object?>{'id': 3, 'name': 'English'},
        ]
        ..activeSubtitleId = 3
        ..refusedMethods = <String>{'disableSubtitle', 'setSubtitleDelay'};
      final controller = await attach(engine);
      final l10n = await AppLocalizations.delegate.load(const Locale('en'));
      await pumpTracksTab(
        tester,
        controller: controller,
        kind: PlayerTrackKind.subtitle,
        tracks: const <VlcTrackDescription>[
          VlcTrackDescription(id: 3, name: 'English'),
        ],
      );

      await tester.tap(find.text(l10n.off));
      await tester.pumpAndSettle();
      expect(engine.callsTo('disableSubtitle'), hasLength(1));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(engine.callsTo('setSubtitleDelay'), hasLength(1));
      expect(tester.takeException(), isNull);

      expect(_selectedRows(tester), <String>[
        'English',
      ], reason: 'the engine said no to both, so nothing on screen moved');
      expect(find.text('+0ms'), findsOneWidget);
    });
  });
}
