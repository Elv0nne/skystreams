/// The audio language setting, driven through the real screen over the real
/// engine fake.
///
/// Every track list here is shaped the way a device sends it: no language
/// field on any track - all five natives send `language: null` - libVLC's own
/// names, `Track 2 - [Hindi]` or `Hindi - [Hindi]`, and, where a test says so,
/// the language `getMediaInfo` reports for the track at the same position.
///
/// The rules, each tested here:
///
///  * Each media this screen opens asks libVLC for the language as it opens
///    it, and starts on its track in the language once its track list has
///    one - left alone when the track already playing is in it, and moved off
///    a commentary libVLC put on for the language. A track the screen
///    switches to plays from where the picture is.
///  * A track the viewer picks from the Audio tab is theirs for the rest of
///    the content: a reopen puts it back wherever it can be told - by its
///    language, or on the very copy it was picked on - and the setting is
///    what is left where it cannot.
///  * Nothing else is a pick. Opening the panel is not one, a source picked
///    by hand is not one, and the setting's own pick is not one.
///  * Media that lacks the language plays what was playing before the reopen
///    if it has that, and its own default otherwise.
///  * The next episode starts afresh: nothing the last one played is carried
///    to it, whoever chose it.
///
/// Harness rules apply - `settle`, never `pumpAndSettle`, and every test
/// unmounts in-body so no watchdog timer outlives it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/services/download_service.dart';
import 'package:skystream/features/player/domain/playback_recovery.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart'
    show PlayerPanel;
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

void main() {
  late FakeVlcEngine engine;

  /// Where playback has got to. Every snapshot moves it on, as real playback
  /// does: a snapshot equal to the last one changes no value, so the screen
  /// would never hear it.
  late int position;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
    position = 1500;
  });
  tearDown(removeEngineMocks);

  Future<AppLocalizations> english() =>
      AppLocalizations.delegate.load(const Locale('en'));

  const PlayerSettings hindi = PlayerSettings(preferredAudioLanguage: 'hi');

  /// One audio track as every native sends it: no language field.
  Map<String, Object?> track(int id, String name) => <String, Object?>{
    'id': id,
    'name': name,
    'language': null,
  };

  /// Bare paths, so the resolver's health probe answers without a socket.
  const sources = <StreamResult>[
    StreamResult(url: '/sources/alpha.mkv', source: 'Alpha', providerName: 'A'),
    StreamResult(url: '/sources/beta.mkv', source: 'Beta', providerName: 'B'),
  ];

  /// The media lists [tracks], libVLC's Disable first, with [active] on - the
  /// snapshot every native sends on ESAdded.
  Future<void> listAudio(
    WidgetTester tester,
    List<Map<String, Object?>> tracks, {
    required int active,
  }) async {
    engine.audio = <Map<String, Object?>>[
      const <String, Object?>{'id': -1, 'name': 'Disable', 'language': null},
      ...tracks,
    ];
    engine.activeAudioId = active;
    await engine.bumpTracks(<String, Object?>{'position': position += 250});
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  /// One ordinary snapshot past the screen's 250 ms throttle, a little
  /// further on: playback goes on, four times a second, on every native.
  Future<void> tick(
    WidgetTester tester, [
    Map<String, Object?> partial = const <String, Object?>{},
  ]) async {
    await engine.emit(<String, Object?>{
      'position': position += 250,
      ...partial,
    });
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  /// Every audio track the screen asked the engine for, in order.
  List<Object?> audioSets() => engine
      .callsTo('setAudioTrack')
      .map((call) => (call.arguments as Map<Object?, Object?>)['id'])
      .toList();

  /// The libVLC options the media last handed to the engine was opened with.
  List<String> lastMediaOptions() {
    final arguments =
        engine.callsTo('setSource').last.arguments as Map<Object?, Object?>;
    final options = arguments['mediaOptions'] as List<Object?>?;
    return <String>[...?options?.cast<String>()];
  }

  /// The positions the screen seeked to, in order.
  List<Object?> seeks() => engine
      .callsTo('seekTo')
      .map((call) => (call.arguments as Map<Object?, Object?>)['position'])
      .toList();

  /// The source drops and the screen fails over to the next one.
  Future<void> failOver(WidgetTester tester) async {
    await tick(tester, <String, Object?>{
      'state': 'error',
      'errorDescription': 'the socket closed',
    });
    await settle(tester);
  }

  /// The source drops for good. A source that has played is reopened after
  /// each of the 1, 2, 4 and 8 s back-offs (a local file can't be checked),
  /// and its fifth failure moves on to the next source in the list: another
  /// provider's copy (spec 2).
  Future<void> failOverToNextSource(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await failOver(tester);
      await tester.pump(const Duration(seconds: 8));
    }
  }

  /// The address of the media last handed to the engine.
  String lastSource() =>
      (engine.callsTo('setSource').last.arguments
              as Map<Object?, Object?>)['uri']!
          as String;

  /// Opens the panel from the control bar on [tab], the viewer's only route
  /// to a track.
  Future<void> openPanel(WidgetTester tester, String tab) async {
    final l10n = await english();
    await revealPlayerControls(tester);
    await tester.tap(find.byTooltip(l10n.options));
    await settle(tester);
    expect(find.byType(PlayerPanel), findsOneWidget);
    await tester.tap(find.text(tab));
    await settle(tester);
  }

  Future<void> closePanel(WidgetTester tester) async {
    await sendBack(tester);
    await settle(tester);
    expect(find.byType(PlayerPanel), findsNothing);
  }

  /// Picks [name] in the Audio tab, as the viewer would.
  Future<void> pickAudio(WidgetTester tester, String name) async {
    await openPanel(tester, (await english()).audio);
    await tester.tap(find.widgetWithText(PanelRow, name));
    await settle(tester);
    await closePanel(tester);
  }

  group('each media this screen opens', () {
    testWidgets('asks libVLC for the language as it opens it', (tester) async {
      // libVLC then starts on the language's track wherever the source says
      // which one it is, and nothing has to be switched.
      await pumpPlayer(tester, settings: hindi);

      expect(lastMediaOptions(), contains(':audio-language=hin,hi'));

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('asks libVLC for no language on Auto', (tester) async {
      await pumpPlayer(tester);

      expect(
        lastMediaOptions().where((o) => o.startsWith(':audio-language')),
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('starts on its track in the language', (tester) async {
      await pumpPlayer(tester, settings: hindi);

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);

      expect(audioSets(), <Object?>[2]);
      expect(engine.activeAudioId, 2);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('reads the language getMediaInfo reports where the name '
        'does not say it in a way known here', (tester) async {
      await pumpPlayer(
        tester,
        settings: const PlayerSettings(preferredAudioLanguage: 'ta'),
      );

      // A libVLC built with its translations names the language in the
      // viewer's own - here, French.
      engine.mediaInfo = <String, Object?>{
        'audioTracks': <Map<String, Object?>>[
          <String, Object?>{'type': 'audio', 'language': 'eng'},
          <String, Object?>{'type': 'audio', 'language': 'tam'},
        ],
      };
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Piste 1 - [Anglais]'),
        track(2, 'Piste 2 - [Tamoul]'),
      ], active: 1);

      expect(audioSets(), <Object?>[2]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('switches when the media lists the language late', (
      tester,
    ) async {
      await pumpPlayer(tester, settings: hindi);

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
      ], active: 1);
      expect(audioSets(), isEmpty);

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);

      expect(audioSets(), <Object?>[2]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('leaves the track playing alone when it is already in the '
        'language', (tester) async {
      await pumpPlayer(tester, settings: hindi);

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Hindi 2.0 - [Hindi]'),
        track(2, 'Hindi DD 5.1 - [Hindi]'),
      ], active: 2);
      await tick(tester);

      expect(audioSets(), isEmpty);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('keeps English when a commentary in English is listed before '
        'it', (tester) async {
      await pumpPlayer(
        tester,
        settings: const PlayerSettings(preferredAudioLanguage: 'en'),
      );

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'English Commentary - [English]'),
        track(2, 'English - [English]'),
      ], active: 2);
      await tick(tester);

      expect(audioSets(), isEmpty);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('goes from a commentary libVLC started on for the language to '
        'the film in it', (tester) async {
      // libVLC takes the first track the source declares in the language it
      // was asked for, commentary or not.
      await pumpPlayer(
        tester,
        settings: const PlayerSettings(preferredAudioLanguage: 'en'),
      );

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Japanese]'),
        track(2, 'English Commentary - [English]'),
        track(3, 'English - [English]'),
      ], active: 2);

      expect(audioSets(), <Object?>[3]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('goes from a commentary libVLC started on for the language to '
        'the film, when that is all there is in it', (tester) async {
      await pumpPlayer(
        tester,
        settings: const PlayerSettings(preferredAudioLanguage: 'en'),
      );

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Japanese]'),
        track(2, 'English Commentary - [English]'),
      ], active: 2);
      await tick(tester);

      expect(audioSets(), <Object?>[
        1,
      ], reason: 'a language the media has only a commentary in is missing');

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('leaves on a commentary it put back itself', (tester) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Tamil]'),
        track(2, 'Commentary'),
      ], active: 1);
      await pickAudio(tester, 'Commentary');
      await tick(tester);

      // Another copy, with no Hindi: the viewer's pick goes back on by its
      // name, and the list then grows while the setting still watches it.
      await failOverToNextSource(tester);
      expect(lastSource(), endsWith('/beta.mkv'));
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Tamil]'),
        track(2, 'Commentary'),
      ], active: 1);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Tamil]'),
        track(2, 'Commentary'),
        track(3, 'Track 3 - [Telugu]'),
      ], active: 2);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[2]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('tries again with the next change to the list when the engine '
        'refuses the track', (tester) async {
      await pumpPlayer(tester, settings: hindi);

      engine.refusedMethods = const <String>{'setAudioTrack'};
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      expect(audioSets(), <Object?>[2]);
      expect(engine.activeAudioId, 1, reason: 'refused');

      engine.refusedMethods = const <String>{};
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
        track(3, 'Track 3 - [Tamil]'),
      ], active: 1);

      expect(audioSets(), <Object?>[2, 2]);
      expect(engine.activeAudioId, 2);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('keeps the engine default when the media lacks the language', (
      tester,
    ) async {
      await pumpPlayer(tester, settings: hindi);

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 1);
      await tick(tester);

      expect(audioSets(), isEmpty);
      expect(engine.activeAudioId, 1);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('is left to the engine with the setting on Auto', (
      tester,
    ) async {
      await pumpPlayer(tester);

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await tick(tester);

      expect(audioSets(), isEmpty);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);
  });

  group('a track the screen puts on', () {
    // Only selected: nothing seeks. libVLC plays it one caching interval
    // later, a second on demand; the seek that used to follow cost a rebuffer
    // and could land on top of a seek of the viewer's.

    testWidgets('for the setting is selected, and nothing seeks', (
      tester,
    ) async {
      await pumpPlayer(tester, settings: hindi);

      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);

      expect(audioSets(), <Object?>[2]);
      expect(seeks(), isEmpty);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('back on another copy is selected, and nothing seeks', (
      tester,
    ) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 1);
      await tick(tester);

      await failOver(tester);
      final before = seeks().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Tamil]'),
        track(2, 'Track 2 - [English]'),
      ], active: 1);

      expect(audioSets(), <Object?>[2]);
      expect(seeks().skip(before), isEmpty);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('back on another copy on Auto is selected, and nothing seeks', (
      tester,
    ) async {
      await pumpPlayer(tester, preloadedStreams: sources);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 2);
      await tick(tester);

      await failOver(tester);
      final before = seeks().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Tamil]'),
        track(2, 'Track 2 - [English]'),
      ], active: 2);

      expect(audioSets(), <Object?>[1]);
      expect(seeks().skip(before), isEmpty);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('is no switch at all, and nothing is reseated, when the one '
        'playing is it already', (tester) async {
      await pumpPlayer(tester, preloadedStreams: sources);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 2);
      await tick(tester);

      await failOver(tester);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 2);
      await tick(tester);

      expect(audioSets(), isEmpty);
      expect(seeks(), isEmpty);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);
  });

  group('a reopen', () {
    testWidgets('follows the language to a copy that numbers and names its '
        'tracks differently', (tester) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await tick(tester);
      expect(audioSets(), <Object?>[2]);

      await failOver(tester);
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Hindi - [Hindi]'),
        track(2, 'English - [English]'),
      ], active: 2);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[
        1,
      ], reason: 'Hindi is id 1 on this copy; id 2 is English');

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('keeps what was playing on a copy that renumbers it, while the '
        'language is nowhere to be had', (tester) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 1);
      await tick(tester);
      expect(audioSets(), isEmpty);

      await failOver(tester);
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Tamil]'),
        track(2, 'Track 2 - [English]'),
      ], active: 1);
      await tick(tester);

      expect(
        audioSets().skip(before),
        <Object?>[2],
        reason:
            'the viewer was hearing English; a reopen has no business '
            'changing the language',
      );

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('to a source picked by hand still gets the language', (
      tester,
    ) async {
      // The issue this setting answers: the first source has no Hindi, so the
      // viewer picks another that does.
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
      ], active: 1);

      final l10n = await english();
      await openPanel(tester, l10n.sources);
      await tick(tester);
      await tester.tap(find.widgetWithText(PanelRow, 'Beta'));
      await settle(tester);

      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[2]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('puts back the viewer\'s own pick on a copy that numbers and '
        'names its tracks differently', (tester) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      expect(audioSets(), <Object?>[2]);

      await pickAudio(tester, 'Track 1 - [English]');
      await tick(tester);
      expect(engine.activeAudioId, 1);

      await failOver(tester);
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Hindi - [Hindi]'),
        track(2, 'English - [English]'),
      ], active: 1);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[
        2,
      ], reason: 'the viewer chose English over the setting\'s Hindi');

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('to a copy without the viewer\'s own pick gets the language', (
      tester,
    ) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await pickAudio(tester, 'Track 1 - [English]');
      await tick(tester);

      await failOverToNextSource(tester);
      expect(lastSource(), endsWith('/beta.mkv'));
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Tamil]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[
        2,
      ], reason: 'this copy has no English; the setting is what is left');

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('to another copy gets the language over a pick that named '
        'none', (tester) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1'),
        track(2, 'Track 2'),
      ], active: 1);
      await pickAudio(tester, 'Track 2');
      await tick(tester);

      await failOverToNextSource(tester);
      expect(lastSource(), endsWith('/beta.mkv'));
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Hindi]'),
        track(2, 'Track 2 - [English]'),
      ], active: 2);
      await tick(tester);

      expect(
        audioSets().skip(before),
        <Object?>[1],
        reason:
            '"Track 2" says nothing about which track it is on another copy',
      );

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('of the same copy puts back a pick that named no language', (
      tester,
    ) async {
      await pumpPlayer(tester, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Hindi]'),
        track(2, 'Track 2'),
      ], active: 1);
      await pickAudio(tester, 'Track 2');
      await tick(tester);

      // The source stops answering; the watchdog reopens it, and the engine
      // comes back on Hindi, its own default.
      engine.activeAudioId = 1;
      final before = audioSets().length;
      final beyond = kStallRecoverAfterSeek + const Duration(seconds: 5);
      for (var i = 0; i < beyond.inSeconds; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await settle(tester);
      await tick(tester);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[2]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('asks libVLC for the viewer\'s language ahead of the '
        'setting\'s', (tester) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await pickAudio(tester, 'Track 1 - [English]');
      await tick(tester);

      await failOver(tester);

      expect(lastMediaOptions(), contains(':audio-language=eng,en,hin,hi'));

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('puts back the viewer\'s own pick two copies on, past one '
        'without it', (tester) async {
      const three = <StreamResult>[
        ...sources,
        StreamResult(
          url: '/sources/gamma.mkv',
          source: 'Gamma',
          providerName: 'C',
        ),
      ];
      await pumpPlayer(tester, preloadedStreams: three, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await pickAudio(tester, 'Track 1 - [English]');
      await tick(tester);

      // Beta has no English, so the setting puts its Hindi on - which is
      // what is playing when Beta drops in turn.
      await failOverToNextSource(tester);
      expect(lastSource(), endsWith('/beta.mkv'));
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Tamil]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await tick(tester);

      await failOverToNextSource(tester);
      expect(lastSource(), endsWith('/gamma.mkv'));
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Hindi]'),
        track(2, 'Track 2 - [English]'),
      ], active: 1);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[
        2,
      ], reason: 'the viewer chose English; Hindi only filled in on Beta');

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('that has a subtitle to put back leaves the audio to the '
        'setting', (tester) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      engine.subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 7, 'name': 'Track 3 - [English]'},
      ];
      engine.activeSubtitleId = 7;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 1);
      await tick(tester);

      // English was playing, and the subtitle was on. The copy that comes
      // back has the language, so English is not put back first.
      await failOver(tester);
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Tamil]'),
        track(2, 'Track 2 - [Hindi]'),
        track(3, 'Track 3 - [English]'),
      ], active: 1);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[2]);
      expect(engine.activeSubtitleId, 7);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('puts back the viewer\'s own pick after a recovery of the same '
        'source, and the setting does not undo it', (tester) async {
      await pumpPlayer(tester, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await pickAudio(tester, 'Track 1 - [English]');
      await tick(tester);

      // The source stops answering; the watchdog reopens it, and the engine
      // comes back on Hindi, its own default. The stall began with the seek
      // that seated the viewer's pick, so it is given the longer allowance.
      engine.activeAudioId = 2;
      final before = audioSets().length;
      final opens = engine.callsTo('setSource').length;
      final beyond = kStallRecoverAfterSeek + const Duration(seconds: 5);
      for (var i = 0; i < beyond.inSeconds; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await settle(tester);
      expect(engine.callsTo('setSource').length, opens + 1, reason: 'reopened');
      await tick(tester);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[1]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);
  });

  group('the viewer', () {
    testWidgets('opening the panel and picking nothing leaves the setting to '
        'act', (tester) async {
      await pumpPlayer(tester, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
      ], active: 1);

      await openPanel(tester, (await english()).audio);
      await closePanel(tester);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);

      expect(audioSets(), <Object?>[2]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('picking a track while the next media opens carries it to that '
        'media', (tester) async {
      await pumpPlayer(tester, preloadedStreams: sources, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      expect(audioSets(), <Object?>[2]);

      // The panel is up on the Audio tab when the source drops. Recovery
      // parks it, and after its 1 s back-off reopens it; the engine has the
      // reopen's media and has not said so yet: the tracks the panel lists
      // are still the outgoing media's.
      await openPanel(tester, (await english()).audio);
      await engine.emit(<String, Object?>{
        'state': 'error',
        'errorDescription': 'the socket closed',
      });
      await tester.pump(const Duration(milliseconds: 100));
      final opening = engine.holdNextReply('setSource');
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
      expect(
        engine.callsTo('setSource'),
        hasLength(3),
        reason: 'the first open, the park, and the reopen being held',
      );
      await tester.tap(find.widgetWithText(PanelRow, 'Track 1 - [English]'));
      await settle(tester);
      await closePanel(tester);

      opening.complete();
      await settle(tester);
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [Hindi]'),
        track(2, 'Track 2 - [English]'),
      ], active: 1);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[
        2,
      ], reason: 'the viewer picked English while this media opened');

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('picking a track while a reopen puts one back keeps it', (
      tester,
    ) async {
      await pumpPlayer(tester, preloadedStreams: sources);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 2);
      await tick(tester);

      // Tamil was playing. The reopen's restore asks for the new media's
      // tracks, and the viewer picks English before the answer comes back.
      await failOver(tester);
      final listing = engine.holdNextReply('getAudioTracks');
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 1);
      final before = audioSets().length;
      await pickAudio(tester, 'Track 1 - [English]');
      listing.complete();
      await settle(tester);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[1]);
      expect(engine.activeAudioId, 1);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('picking a track before the language turns up keeps it', (
      tester,
    ) async {
      await pumpPlayer(tester, settings: hindi);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 1);

      await pickAudio(tester, 'Track 2 - [Tamil]');
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
        track(3, 'Track 3 - [Hindi]'),
      ], active: 2);

      expect(audioSets(), <Object?>[2]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);
  });

  group('the next episode', () {
    final firstEpisode = Episode(
      name: 'Ep 01',
      url: 'https://example.com/e1.mp4',
      season: 1,
      episode: 1,
    );
    final secondEpisode = Episode(
      name: 'Ep 02',
      url: 'https://example.com/e2.mp4',
      season: 1,
      episode: 2,
    );
    final show = MultimediaItem(
      title: 'Show',
      url: 'https://example.com/show',
      posterUrl: '',
      contentType: MultimediaContentType.series,
      episodes: [firstEpisode, secondEpisode],
      provider: 'Remote',
    );

    /// The show on its first episode, with the disk lookup every advance
    /// opens with held shut, so the outgoing episode can be seen playing on
    /// while the next one is looked up.
    Future<GatedDownloads Function()> pumpShow(
      WidgetTester tester, {
      PlayerSettings settings = hindi,
    }) async {
      late GatedDownloads downloads;
      await pumpPlayer(
        tester,
        item: show,
        episode: firstEpisode,
        videoUrl: firstEpisode.url,
        settings: settings,
        overrides: [
          downloadServiceProvider.overrideWith(
            (ref) => downloads = GatedDownloads(ref),
          ),
        ],
      );
      return () => downloads;
    }

    Future<void> pressNext(WidgetTester tester) async {
      final l10n = await english();
      await revealPlayerControls(tester);
      await tester.tap(find.byTooltip(l10n.next));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('pressed mid-playback gets the language, however long the '
        'last one plays on', (tester) async {
      final downloads = await pumpShow(tester);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await tick(tester);
      expect(audioSets(), <Object?>[2]);

      await pressNext(tester);
      final reads = engine.callsTo('getAudioTracks').length;
      await tick(tester);
      await tick(tester);
      expect(
        engine.callsTo('getAudioTracks').length,
        reads,
        reason:
            'the outgoing episode\'s ticks describe media on its way '
            'out, and nothing may be learned from them',
      );

      downloads().gate.complete();
      await settle(tester);
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Hindi - [Hindi]'),
        track(2, 'English - [English]'),
      ], active: 2);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[1]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('reached by playing to the end gets the language', (
      tester,
    ) async {
      final downloads = await pumpShow(tester);
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Hindi]'),
      ], active: 1);
      await tick(tester);
      expect(audioSets(), <Object?>[2]);

      await tick(tester, <String, Object?>{
        'position': 1199000,
        'duration': 1200000,
      });
      await tick(tester, <String, Object?>{'state': 'ended'});
      // The outgoing engine says so again, late.
      await tick(tester, <String, Object?>{'state': 'ended'});

      downloads().gate.complete();
      await settle(tester);
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Hindi - [Hindi]'),
        track(2, 'English - [English]'),
      ], active: 2);
      await tick(tester);

      expect(audioSets().skip(before), <Object?>[1]);

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);

    testWidgets('on Auto starts on its own default, not on the track the '
        'viewer picked in the last one', (tester) async {
      final downloads = await pumpShow(
        tester,
        settings: const PlayerSettings(),
      );
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 1);
      await pickAudio(tester, 'Track 2 - [Tamil]');
      await tick(tester);

      await pressNext(tester);
      await tick(tester);
      await tick(tester);
      downloads().gate.complete();
      await settle(tester);
      final before = audioSets().length;
      await listAudio(tester, <Map<String, Object?>>[
        track(1, 'Track 1 - [English]'),
        track(2, 'Track 2 - [Tamil]'),
      ], active: 1);
      await tick(tester);

      expect(
        audioSets().skip(before),
        isEmpty,
        reason: 'the next episode\'s tracks are its own',
      );

      await tester.pumpWidget(const SizedBox());
    }, variant: texturePlatform);
  });
}
