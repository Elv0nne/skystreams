import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_tracks_tab.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// A track switch only selects (spec 1.4).
///
/// It used to seek back to where playback was, so the new track would start
/// at once rather than one caching interval later. With the interval at a
/// second that bought little, and it cost a rebuffer, about 70 MB of
/// re-download per MKV session, and a seek that could land on top of one of
/// the viewer's.
void main() {
  Future<VlcPlayerController> attach(FakeVlcEngine engine) async {
    engine.install();
    addTearDown(engine.dispose);
    return engine.attach();
  }

  Future<void> pumpTracksTab(
    WidgetTester tester, {
    required VlcPlayerController controller,
    required PlayerTrackKind kind,
    required List<VlcTrackDescription> tracks,
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
            onTracksChanged: () {},
            onOpenPage: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// A player a minute into a seekable film, with two audio languages and
  /// two subtitles, none of them on.
  FakeVlcEngine playingEngine() => FakeVlcEngine()
    ..audio = <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'name': 'English', 'language': 'eng'},
      <String, Object?>{'id': 3, 'name': 'French', 'language': 'fra'},
    ]
    ..activeAudioId = 1
    ..subtitle = <Map<String, Object?>>[
      <String, Object?>{'id': 5, 'name': 'English', 'language': 'eng'},
      <String, Object?>{'id': 6, 'name': 'Spanish', 'language': 'spa'},
    ];

  const audio = <VlcTrackDescription>[
    VlcTrackDescription(id: 1, name: 'English', language: 'eng'),
    VlcTrackDescription(id: 3, name: 'French', language: 'fra'),
  ];

  const subtitles = <VlcTrackDescription>[
    VlcTrackDescription(id: 5, name: 'English', language: 'eng'),
    VlcTrackDescription(id: 6, name: 'Spanish', language: 'spa'),
  ];

  testWidgets('choosing an audio track selects it, and nothing seeks', (
    tester,
  ) async {
    final engine = playingEngine();
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{'position': 60000, 'duration': 600000});
    await tester.pump(const Duration(milliseconds: 400));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.audio,
      tracks: audio,
    );
    await tester.tap(find.text('French'));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('setAudioTrack'));
    expect(engine.methods, isNot(contains('seekTo')));

    controller.dispose();
  });

  testWidgets("a switch leaves the viewer's own seek alone", (tester) async {
    // The re-seat seeked again after every switch; one made right after the
    // viewer's seek could overwrite it.
    final engine = playingEngine();
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{
      'state': 'paused',
      'position': 60000,
      'duration': 600000,
    });
    await controller.seekTo(const Duration(seconds: 90));
    await tester.pump(const Duration(milliseconds: 500));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.audio,
      tracks: audio,
    );
    await tester.tap(find.text('French'));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('setAudioTrack'));
    expect(
      engine
          .callsTo('seekTo')
          .map((call) => (call.arguments as Map<Object?, Object?>)['position']),
      <Object?>[90000],
      reason: "the viewer's seek, and nothing after it",
    );

    controller.dispose();
  });

  testWidgets('choosing a subtitle track selects it, and nothing seeks', (
    tester,
  ) async {
    final engine = playingEngine();
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{'position': 60000, 'duration': 600000});
    await tester.pump(const Duration(milliseconds: 400));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.subtitle,
      tracks: subtitles,
    );
    await tester.tap(find.text('Spanish'));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('setSubtitleTrack'));
    expect(engine.methods, isNot(contains('seekTo')));

    controller.dispose();
  });

  testWidgets('turning subtitles off is a selection too', (tester) async {
    final engine = playingEngine()..activeSubtitleId = 5;
    final controller = await attach(engine);
    await engine.emit(<String, Object?>{'position': 60000, 'duration': 600000});
    await tester.pump(const Duration(milliseconds: 400));

    await pumpTracksTab(
      tester,
      controller: controller,
      kind: PlayerTrackKind.subtitle,
      tracks: subtitles,
    );
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.tap(find.text(l10n.off));
    await tester.pumpAndSettle();

    expect(engine.methods, contains('disableSubtitle'));
    expect(engine.methods, isNot(contains('seekTo')));

    controller.dispose();
  });
}
