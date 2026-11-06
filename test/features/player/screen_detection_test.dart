/// What notices a failure, on the real screen over the fake engine (spec 2,
/// Detection): the watchdog on wall-clock time, a stall on HLS left to ride
/// out, a starved video, a pause nobody asked for, and the first frame
/// counted from progress.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/logger/app_logger.dart';
import 'package:skystream/features/player/domain/qoe_log.dart';
import 'package:skystream/features/player/presentation/vlc/ended_card.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

const _hls = <StreamResult>[
  StreamResult(url: 'https://a.test/show/master.m3u8', source: 'A'),
];
const _file = <StreamResult>[
  StreamResult(url: 'https://a.test/film.mp4', source: 'A'),
];

void main() {
  late FakeVlcEngine engine;

  /// How far the wall clock runs ahead of the test's fake time.
  var jump = Duration.zero;

  setUp(() {
    engine = FakeVlcEngine()..holdsPictures = true;
    installEngineMocks(engine: engine);
    jump = Duration.zero;
  });
  tearDown(removeEngineMocks);

  /// Runs [body] on a wall clock [jump] ahead of the fake time. Everything the
  /// screen makes in it - its timers, its listeners - reads that clock, so
  /// moving [jump] moves the wall clock the way a correction or a sleeping
  /// laptop does, with no timer firing.
  Future<void> onJumpingClock(Future<void> Function() body) {
    final fake = clock;
    return withClock(Clock(() => fake.now().add(jump)), body);
  }

  int opens() => engine.callsTo('setSource').length;
  List<String> errorSigns() => [
    for (final e in QoeLog.latest!.events)
      if (e.kind == QoeEventKind.error && e.fields['sign'] != null)
        '${e.fields['sign']}',
  ];
  VlcPlayerControls controls(WidgetTester tester) =>
      tester.widget<VlcPlayerControls>(find.byType(VlcPlayerControls));

  /// Plays [sources] to [positionMs] of a 90-minute film.
  Future<void> play(
    WidgetTester tester,
    List<StreamResult> sources, {
    int positionMs = 120000,
  }) async {
    await pumpPlayer(tester, preloadedStreams: sources);
    await sendFirstFrame(tester);
    await sendEvent(tester, snapshot(position: positionMs, duration: 5400000));
    await settle(tester);
  }

  /// Healthy playback for [span]: the position reported four times a second,
  /// so every watchdog tick sees it move.
  Future<void> playOn(
    WidgetTester tester,
    Duration span, {
    required int from,
  }) async {
    var position = from;
    for (
      var t = Duration.zero;
      t < span;
      t += const Duration(milliseconds: 250)
    ) {
      position += 250;
      await sendSnapshot(
        tester,
        snapshot(position: position, duration: 5400000),
      );
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  group('the watchdog counts wall-clock time', () {
    testWidgets(
      'a frozen picture noticed a minute late goes to recovery at once',
      variant: texturePlatform,
      (tester) async {
        await onJumpingClock(() async {
          await play(tester, _file);

          // The laptop slept with the picture frozen: no event and no tick,
          // and a minute gone on the wall clock when it wakes.
          jump += const Duration(minutes: 1);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump();

          expect(errorSigns(), contains('stalled'));

          await tester.pumpWidget(const SizedBox());
        });
      },
    );

    testWidgets(
      'a clock jump during healthy playback reopens nothing',
      variant: texturePlatform,
      (tester) async {
        await onJumpingClock(() async {
          await play(tester, _file);
          final before = opens();

          await playOn(tester, const Duration(seconds: 2), from: 120000);
          // An NTP correction, or a television leaving standby, while
          // playback goes on.
          jump += const Duration(minutes: 1);
          await playOn(tester, const Duration(seconds: 3), from: 122000);

          expect(opens(), before);
          expect(errorSigns(), isEmpty);

          await tester.pumpWidget(const SizedBox());
        });
      },
    );
  });

  group('HLS and DASH stalls', () {
    testWidgets(
      'an HLS stall gets no nudge, and goes to recovery at 25 s',
      variant: texturePlatform,
      (tester) async {
        await play(tester, _hls);
        engine.calls.clear();

        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(engine.callsTo('seekTo'), isEmpty, reason: 'no nudge at 10 s');
        expect(errorSigns(), isEmpty);

        for (var i = 0; i < 7; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(errorSigns(), contains('stalled'));

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a file stall is still nudged at 10 s',
      variant: texturePlatform,
      (tester) async {
        await play(tester, _file);
        engine.calls.clear();

        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(seconds: 1));
        }

        expect(engine.callsTo('seekTo'), isNotEmpty);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'HLS bytes still arriving through the demuxer hold a stall off past 25 s',
      variant: texturePlatform,
      (tester) async {
        await play(tester, _hls);
        // libVLC's adaptive module reads the segments itself: the input's own
        // count stands still on the playlist while the demuxer's grows.
        var demuxed = 1 << 20;
        for (var i = 0; i < 40; i++) {
          demuxed += 64 * 1024;
          engine.mediaStats = <String, Object?>{
            'available': true,
            'readBytes': 4096,
            'demuxReadBytes': demuxed,
            'decodedVideo': 3000,
            'displayedPictures': 3000,
          };
          await tester.pump(const Duration(seconds: 1));
        }

        expect(errorSigns(), isEmpty, reason: 'a refill, not a dead source');

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  testWidgets(
    'a starved video on HLS reopens where its picture stopped',
    variant: texturePlatform,
    (tester) async {
      await play(tester, _hls);
      var position = 120000;
      var decoded = 3000;
      // Pictures decoded for two seconds, then none while the sound's clock
      // runs on and libVLC re-displays the last one.
      for (var i = 0; i < 8; i++) {
        position += 1000;
        if (i < 2) decoded += 24;
        engine.mediaStats = <String, Object?>{
          'available': true,
          'displayedPictures': 3000 + i * 12,
          'decodedVideo': decoded,
        };
        await sendSnapshot(tester, <String, Object?>{
          ...snapshot(position: position, duration: 5400000),
          'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
        });
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 700));
        if (errorSigns().isNotEmpty) break;
      }

      expect(errorSigns(), contains('videoStarved'));
      final park =
          engine.callsTo('setSource').last.arguments as Map<Object?, Object?>;
      expect(
        park['startPosition'],
        inInclusiveRange(121000, 122000),
        reason: 'where the picture stopped, not the sound\'s playhead',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  group('a pause or stop nobody asked for', () {
    testWidgets(
      'is a failure; the viewer\'s pause is not',
      variant: texturePlatform,
      (tester) async {
        await play(tester, _file);
        final controller = controls(tester).controller;

        await controller.pause();
        await sendEvent(tester, snapshot(state: 'paused', position: 120500));
        expect(errorSigns(), isEmpty);

        await controller.play();
        await sendEvent(tester, snapshot(position: 121500, duration: 5400000));
        await sendEvent(tester, snapshot(state: 'paused', position: 122000));
        await tester.pump();

        expect(errorSigns(), contains('pausedUnasked'));

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'at the end of the film is its end: macOS pauses there instead of '
      'ending',
      variant: texturePlatform,
      (tester) async {
        await play(tester, _file, positionMs: 5398500);

        await sendEvent(
          tester,
          snapshot(state: 'paused', position: 5399000, duration: 5400000),
        );
        await settle(tester);

        expect(find.byKey(endedCardKey), findsOneWidget);
        expect(errorSigns(), isEmpty);

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('the first frame', () {
    testWidgets(
      'a start still making progress is not given up at 30 s, and is at 60 s',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester, preloadedStreams: _hls);
        var read = 0;
        Future<void> secondsOfProgress(int seconds) async {
          for (var i = 0; i < seconds; i++) {
            read += 32 * 1024;
            engine.mediaStats = <String, Object?>{
              'available': true,
              'demuxReadBytes': read,
            };
            await tester.pump(const Duration(seconds: 1));
          }
        }

        await secondsOfProgress(45);
        expect(errorSigns(), isEmpty);

        await secondsOfProgress(16);
        expect(errorSigns(), contains('neverStarted'));

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'Android\'s font start gate counts as progress',
      variant: texturePlatform,
      (tester) async {
        await pumpPlayer(tester, preloadedStreams: _hls);
        for (var i = 0; i < 45; i++) {
          await engine.emit(<String, Object?>{
            'state': 'opening',
            'position': 0,
            'startGated': true,
          });
          await tester.pump(const Duration(seconds: 1));
        }

        expect(errorSigns(), isEmpty);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'a held reopen that never starts is given up on',
      variant: texturePlatform,
      (tester) async {
        await play(tester, _hls);
        await sendEvent(tester, snapshot(state: 'error'));
        await settle(tester);
        // The check answered: the reopen comes after its 1 s back-off.
        await tester.pump(const Duration(seconds: 2));
        expect(controls(tester).controller.value.isPictureHeld, isTrue);

        for (var i = 0; i < 32; i++) {
          await tester.pump(const Duration(seconds: 1));
        }

        expect(errorSigns(), contains('neverStarted'));

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  testWidgets(
    "a viewer's own seek isn't blamed on the source",
    variant: texturePlatform,
    (tester) async {
      // libVLC counts a demux discontinuity at a seek, and the smoothness
      // log read any as "the source is skipping or splicing badly": 5-9 such
      // lines a run on the MP4 seek rows of four targets (P1 Part 2).
      await play(tester, _file);
      var pictures = 3000;
      engine.mediaStats = <String, Object?>{
        'available': true,
        'displayedPictures': pictures,
        'decodedVideo': pictures,
        'demuxDiscontinuity': 0,
      };
      await playOn(tester, const Duration(seconds: 10), from: 120000);

      final controller = tester
          .widget<VlcPlayer>(find.byType(VlcPlayer))
          .controller;
      unawaited(controller.seekTo(const Duration(minutes: 3)));
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        pictures += 24;
        engine.mediaStats = <String, Object?>{
          'available': true,
          'displayedPictures': pictures,
          'decodedVideo': pictures,
          'demuxDiscontinuity': 2,
        };
        await sendEvent(
          tester,
          snapshot(position: 180000 + i * 1000, duration: 5400000),
        );
        await tester.pump(const Duration(seconds: 1));
      }

      expect(
        talker.history.map((entry) => entry.message ?? ''),
        isNot(contains(contains('skipping or splicing'))),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
