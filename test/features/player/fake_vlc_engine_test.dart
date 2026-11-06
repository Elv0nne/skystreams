import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// The fake is only worth having if it behaves like the engine it stands in
/// for, so it gets the same kind of tests: what does the controller see.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine()..install();
  });
  tearDown(() => engine.dispose());

  group('FakeVlcEngine', () {
    test('answers the track lists and media info from its fields', () async {
      engine.audio = <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'name': 'English', 'language': 'en'},
      ];
      engine.subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 3, 'name': 'Spanish', 'language': 'es'},
      ];
      engine.mediaInfo = <String, Object?>{'title': 'Channel One'};
      final controller = await engine.attach();

      final audio = await controller.getAudioTracks();
      final subtitle = await controller.getSubtitleTracks();
      final info = await controller.getMediaInfo();

      expect(audio.single.id, 1);
      expect(audio.single.language, 'en');
      expect(subtitle.single.name, 'Spanish');
      expect(info.title, 'Channel One');
      controller.dispose();
    });

    test('setSubtitleTrack(3) then emit() carries subtitleTrack 3', () async {
      engine.subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 2, 'name': 'English'},
        <String, Object?>{'id': 3, 'name': 'Spanish'},
      ];
      final controller = await engine.attach();

      await controller.setSubtitleTrack(3);
      final delivered = await engine.emit();

      expect(engine.activeSubtitleId, 3);
      expect(delivered['subtitleTrack'], 3);
      expect(delivered['audioTrack'], -1, reason: 'no audio was ever chosen');
      expect(delivered['trackRevision'], 0);
      // The delivered map is the harness-shaped snapshot underneath.
      expect(delivered['state'], 'playing');
      expect(delivered['position'], 1500);
      expect(controller.value.state, VlcPlaybackState.playing);
      // What the controller made of it: the raw id as-is, -1 normalised to
      // "none", the revision untouched because the set was not a list change.
      expect(controller.value.activeSubtitleTrackId, 3);
      expect(controller.value.activeAudioTrackId, isNull);
      expect(controller.value.trackRevision, 0);
      controller.dispose();
    });

    test('setAudioTrack and disableSubtitle move the active ids', () async {
      engine.audio = <Map<String, Object?>>[
        <String, Object?>{'id': 0, 'name': 'Stereo'},
        <String, Object?>{'id': 1, 'name': '5.1'},
      ];
      engine.subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 4, 'name': 'English'},
      ];
      final controller = await engine.attach();

      // 0 is a legal id, not "none".
      await controller.setAudioTrack(0);
      expect(engine.activeAudioId, 0);
      await controller.setAudioTrack(1);
      expect(engine.activeAudioId, 1);

      await controller.setSubtitleTrack(4);
      expect(engine.activeSubtitleId, 4);
      await controller.disableSubtitle();
      expect(engine.activeSubtitleId, -1);
      expect((await engine.emit())['subtitleTrack'], -1);
      controller.dispose();
    });

    test('addSubtitle appends, selects and bumps trackRevision', () async {
      engine.subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 2, 'name': 'Embedded'},
      ];
      engine.activeSubtitleId = 2;
      final controller = await engine.attach();

      await controller.addSubtitle(Uri.parse('https://subs.test/a/en.srt'));

      expect(engine.subtitle, hasLength(2));
      expect(engine.subtitle.last, <String, Object?>{
        'id': 100,
        'name': 'en.srt',
      });
      expect(engine.activeSubtitleId, 100, reason: 'add-slave selects');
      expect(engine.trackRevision, 1);

      await controller.addSubtitle(Uri.parse('https://subs.test/a/es.srt'));
      expect(engine.subtitle.last['id'], 101);
      expect(engine.activeSubtitleId, 101);
      expect(engine.trackRevision, 2);

      final delivered = await engine.emit();
      expect(delivered['subtitleTrack'], 101);
      expect(delivered['trackRevision'], 2);
      expect(controller.value.activeSubtitleTrackId, 101);
      expect(
        controller.value.trackRevision,
        greaterThan(0),
        reason: 'an added track is a list change the value reports',
      );
      expect(controller.value.trackRevision, 2);

      final tracks = await controller.getSubtitleTracks();
      expect(tracks.map((t) => t.id), <int>[2, 100, 101]);
      controller.dispose();
    });

    test('an unknown id surfaces as the controller\'s exception', () async {
      engine.audio = <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'name': 'English'},
      ];
      final controller = await engine.attach();

      // The controller wraps the channel's PlatformException; the code is
      // what the fake threw.
      await expectLater(
        controller.setAudioTrack(7),
        throwsA(
          isA<VlcPlayerException>().having(
            (e) => e.code,
            'code',
            'track_not_found',
          ),
        ),
      );
      expect(engine.activeAudioId, -1, reason: 'a failed set moves nothing');

      await expectLater(
        controller.setSubtitleTrack(9),
        throwsA(isA<VlcPlayerException>()),
      );
      expect(engine.activeSubtitleId, -1);
      controller.dispose();
    });

    test('calls record arguments, not only names', () async {
      final controller = await engine.attach();

      await controller.seekTo(const Duration(seconds: 90));
      await controller.setSubtitleDelay(const Duration(milliseconds: 500));
      await controller.setAudioDelay(const Duration(milliseconds: -200));
      await controller.play();

      expect(engine.methods, <String>[
        'seekTo',
        'setSubtitleDelay',
        'setAudioDelay',
        'play',
      ]);
      final seek = engine.callsTo('seekTo').single;
      expect(seek.arguments, containsPair('viewId', 1));
      expect(seek.arguments, containsPair('position', 90000));
      expect(
        engine.callsTo('setSubtitleDelay').single.arguments,
        containsPair('delay', 500000),
        reason: 'delays travel as microseconds',
      );
      expect(
        engine.callsTo('setAudioDelay').single.arguments,
        containsPair('delay', -200000),
      );
      controller.dispose();
    });

    test(
      'create answers with its own view, so the texture path works',
      () async {
        final controller = VlcPlayerController();
        // The texture path asks the engine for a view instead of being handed
        // one; the fake names itself.
        final textureId = await (controller as dynamic).attachTexturePlayer();

        expect(textureId, 1);
        expect(engine.methods, <String>['create']);
        expect(engine.sink, isNotNull, reason: 'the controller is listening');

        await engine.emit(<String, Object?>{'state': 'paused'});
        expect(controller.value.state, VlcPlaybackState.paused);
        controller.dispose();
      },
    );

    test(
      'holds the next reply back while acting on the call at once',
      () async {
        engine.audio = <Map<String, Object?>>[
          <String, Object?>{'id': 1, 'name': 'English'},
          <String, Object?>{'id': 2, 'name': 'Hindi'},
        ];
        final controller = await engine.attach();
        final reply = engine.holdNextReply('setAudioTrack');

        var answered = false;
        final set = controller.setAudioTrack(2).then((_) => answered = true);
        await pumpEventQueue();

        expect(engine.activeAudioId, 2, reason: 'the engine has done it');
        expect(answered, isFalse, reason: 'and not yet said so');

        reply.complete();
        await set;
        expect(answered, isTrue);

        // Only the next call was held.
        await controller.setAudioTrack(1);
        expect(engine.activeAudioId, 1);
        controller.dispose();
      },
    );

    test('emit honours the caller\'s overrides and the throttle', () async {
      final controller = await engine.attach(
        eventThrottleInterval: const Duration(milliseconds: 250),
      );

      await engine.emit(<String, Object?>{'position': 1000});
      expect(controller.value.position, const Duration(seconds: 1));

      // A progress tick with nothing else changed is held back until the
      // throttle flushes.
      await engine.emit(<String, Object?>{'position': 2000});
      expect(controller.value.position, const Duration(seconds: 1));
      controller.dispose();
    });

    test('dispose clears the sink and stops answering', () async {
      final controller = await engine.attach();
      expect(engine.sink, isNotNull);
      controller.dispose();

      engine.dispose();
      expect(engine.sink, isNull);
    });

    /// Under `testWidgets`, and only there, a failure in the services layer
    /// - an `onListen` reply the codec cannot encode, say - is collected and
    /// reported. A plain `test()` swallows it, which is how the fake once
    /// broke every widget test that attached through it while its own tests
    /// stayed green. So the fake is also exercised the way its consumers use
    /// it: attached inside a pumped widget that listens to the controller.
    testWidgets('attaches under a pumped widget and a snapshot reaches it', (
      tester,
    ) async {
      engine.subtitle = <Map<String, Object?>>[
        <String, Object?>{'id': 3, 'name': 'Spanish'},
      ];
      final controller = await engine.attach();

      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<VlcPlayerValue>(
            valueListenable: controller,
            builder: (_, value, _) =>
                Text('${value.state.name}/${value.activeSubtitleTrackId}'),
          ),
        ),
      );
      expect(find.text('idle/null'), findsOneWidget);
      expect(engine.sink, isNotNull, reason: 'the controller is listening');

      // Paused, so no stall watchdog is left pending at the end of the test.
      await engine.emit(<String, Object?>{
        'state': 'paused',
        'subtitleTrack': 3,
      });
      await tester.pump();

      expect(controller.value.activeSubtitleTrackId, 3);
      expect(find.text('paused/3'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });
}
