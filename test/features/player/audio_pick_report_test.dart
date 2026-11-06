import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_tracks_tab.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// The Audio tab tells the screen which track the viewer picked.
///
/// The engine selects audio too - as media opens, on a reopen, for the audio
/// language setting - and only the screen can tell those from the viewer's own
/// choice, which outranks them all for the rest of the content. A row tap is
/// the one thing that is the viewer's, so it is the one thing reported.
void main() {
  Future<VlcPlayerController> attach(FakeVlcEngine engine) async {
    engine.install();
    addTearDown(engine.dispose);
    return engine.attach();
  }

  /// The tracks as every native lists them - no language field - with the
  /// language `getMediaInfo` gives each at the same position.
  const tracks = <VlcTrackDescription>[
    VlcTrackDescription(id: -1, name: 'Disable'),
    VlcTrackDescription(id: 1, name: 'Piste 1 - [Anglais]'),
    VlcTrackDescription(id: 2, name: 'Piste 2 - [Tamoul]'),
  ];
  const info = <VlcMediaTrackInfo>[
    VlcMediaTrackInfo(type: 'audio', language: 'eng'),
    VlcMediaTrackInfo(type: 'audio', language: 'tam'),
  ];

  FakeVlcEngine engineWithTracks() => FakeVlcEngine()
    ..audio = <Map<String, Object?>>[
      for (final track in tracks)
        <String, Object?>{'id': track.id, 'name': track.name},
    ]
    ..subtitle = <Map<String, Object?>>[
      <String, Object?>{'id': 5, 'name': 'Track 3 - [English]'},
    ]
    ..activeAudioId = 1;

  Future<void> pumpTab(
    WidgetTester tester, {
    required VlcPlayerController controller,
    required PlayerTrackKind kind,
    required ValueChanged<VlcTrackDescription> onAudioPicked,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerTracksTab(
            controller: controller,
            kind: kind,
            tracks: kind == PlayerTrackKind.audio
                ? tracks
                : const <VlcTrackDescription>[
                    VlcTrackDescription(id: 5, name: 'Track 3 - [English]'),
                  ],
            trackInfo: kind == PlayerTrackKind.audio
                ? info
                : const <VlcMediaTrackInfo>[],
            onTracksChanged: () {},
            onOpenPage: (_) {},
            onAudioPicked: onAudioPicked,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a picked row reports its track, in the language its media '
      'info gives', (tester) async {
    final engine = engineWithTracks();
    final controller = await attach(engine);
    final picked = <VlcTrackDescription>[];

    await pumpTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.audio,
      onAudioPicked: picked.add,
    );
    await tester.tap(find.text('Piste 2 - [Tamoul]'));
    await tester.pumpAndSettle();

    expect(engine.activeAudioId, 2);
    expect(picked.map((track) => track.id), <int>[2]);
    expect(picked.single.language, 'ta');

    controller.dispose();
  });

  testWidgets('a pick is reported before the engine is asked for it', (
    tester,
  ) async {
    // Reported after, a look of the screen's already past its last check
    // could send its own track after the viewer's, and the engine would play
    // the look's.
    final engine = engineWithTracks();
    final controller = await attach(engine);
    final setsWhenReported = <int>[];

    await pumpTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.audio,
      onAudioPicked: (_) =>
          setsWhenReported.add(engine.callsTo('setAudioTrack').length),
    );
    await tester.tap(find.text('Piste 2 - [Tamoul]'));
    await tester.pumpAndSettle();

    expect(setsWhenReported, <int>[0]);
    expect(engine.activeAudioId, 2);

    controller.dispose();
  });

  testWidgets('a pick the engine refuses is the viewer\'s all the same', (
    tester,
  ) async {
    // It was reported before the engine answered. What the viewer asked for
    // is still what they want, and a reopen puts it back where it can.
    final engine = engineWithTracks()
      ..refusedMethods = const <String>{'setAudioTrack'};
    final controller = await attach(engine);
    final picked = <VlcTrackDescription>[];

    await pumpTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.audio,
      onAudioPicked: picked.add,
    );
    await tester.tap(find.text('Piste 2 - [Tamoul]'));
    await tester.pumpAndSettle();

    expect(picked.map((track) => track.id), <int>[2]);
    expect(engine.activeAudioId, 1, reason: 'refused');

    controller.dispose();
  });

  testWidgets('a subtitle row is no audio pick', (tester) async {
    final engine = engineWithTracks();
    final controller = await attach(engine);
    final picked = <VlcTrackDescription>[];

    await pumpTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.subtitle,
      onAudioPicked: picked.add,
    );
    await tester.tap(find.text('Track 3 - [English]'));
    await tester.pumpAndSettle();

    expect(engine.activeSubtitleId, 5);
    expect(picked, isEmpty);

    controller.dispose();
  });
}
