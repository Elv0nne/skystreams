import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// [VlcPlayerController.playbackClock]: where playback is between the
/// engine's reports.
///
/// libVLC 3 updates its time at most every 250 ms and not at all while
/// paused. An adaptive stream refreshes it once a wall-clock second, so its
/// reports are a staircase running up to a second behind, wobbling back a few
/// milliseconds; VLCKit's cached time does not move on a seek at all. The
/// numbers below come from libVLC 3.0.24 traces of those cases.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VlcMethodChannelHarness harness;
  late VlcPlayerController controller;

  setUp(() {
    harness = VlcMethodChannelHarness()..install();
  });

  tearDown(() {
    harness.dispose();
  });

  /// A controller on view 1. Built in the test body, so its clock measures
  /// time on the fake clock the test's pumps advance.
  Future<void> attach({Duration? eventThrottleInterval}) async {
    controller = VlcPlayerController(
      eventThrottleInterval: eventThrottleInterval,
    );
    harness.mockEventChannel(1);
    await harness.attachController(controller, 1);
  }

  Future<void> report(String state, int milliseconds, {double speed = 1}) =>
      harness.sendEvent(1, <String, Object?>{
        'state': state,
        'position': milliseconds,
        'playbackSpeed': speed,
      });

  /// The clock's reading, in milliseconds.
  int clock() => controller.playbackClock.position.inMilliseconds;

  Duration ms(int value) => Duration(milliseconds: value);

  /// Plays on for [count] reports a quarter of a second apart, the engine
  /// moving from [from] at [rate] times the clock's speed, and looks at the
  /// clock every 50 ms: the clock less where the engine is, after each
  /// report. Fails at once on a reading lower than the one before.
  Future<List<int>> playOn(
    WidgetTester tester, {
    required int from,
    int count = 24,
    double rate = 1,
  }) async {
    final errors = <int>[];
    var last = clock();
    for (var k = 1; k <= count; k++) {
      for (var look = 1; look <= 6; look++) {
        if (look < 6) {
          await tester.pump(ms(50));
        } else {
          await report('playing', from + (250 * k * rate).round());
        }
        expect(clock(), greaterThanOrEqualTo(last), reason: 'report $k');
        last = clock();
      }
      errors.add(last - (from + (250 * k * rate).round()));
    }
    return errors;
  }

  group('between reports', () {
    testWidgets('runs on from the last report at the playback speed', (
      tester,
    ) async {
      await attach();
      await report('playing', 10000);
      expect(clock(), 10000);

      await tester.pump(ms(200));
      expect(clock(), 10200);

      await report('playing', 10250);
      expect(clock(), 10250);
      await tester.pump(ms(100));
      expect(clock(), 10350);
      expect(controller.playbackClock.timeUntil(ms(10500)), ms(150));
      controller.dispose();
    });

    testWidgets('holds a second past the last report, then waits for the '
        'engine without stepping back', (tester) async {
      await attach();
      await report('playing', 3000);
      await tester.pump(ms(1000));
      expect(clock(), 4000);
      await tester.pump(ms(1000));
      expect(clock(), 4000, reason: 'a stall the engine has not announced');
      expect(controller.playbackClock.timeUntil(ms(4100)), isNull);

      // The engine comes back from where it froze.
      await report('playing', 3200);
      expect(clock(), 4000);
      expect(controller.playbackClock.timeUntil(ms(4100)), ms(900));
      await tester.pump(ms(500));
      expect(clock(), 4000, reason: 'held until the engine catches up');
      await tester.pump(ms(400));
      expect(clock(), 4100);
      controller.dispose();
    });

    testWidgets('a report less than 1.5 s behind is stale, not a step back', (
      tester,
    ) async {
      // An adaptive stream's time steps up once a second and wobbles back in
      // between: what the engine reports four times a second.
      await attach();
      await report('playing', 1155);
      await tester.pump(ms(1000));
      await report('playing', 2155);
      expect(clock(), 2155);
      for (final (after, reported) in <(int, int)>[
        (250, 2171),
        (500, 2141),
        (750, 2156),
      ]) {
        await tester.pump(ms(250));
        await report('playing', reported);
        expect(clock(), 2155 + after, reason: 'report $reported at +$after');
      }
      await tester.pump(ms(250));
      await report('playing', 3155);
      expect(clock(), 3155);
      controller.dispose();
    });

    testWidgets('at 2x a report up to 3 s behind is stale: the window is a '
        'second and a half of wall time', (tester) async {
      // An adaptive stream's time trails playback by up to a second of wall
      // time, and at 2x that second is two of the media.
      await attach();
      await report('playing', 10000, speed: 2);
      await tester.pump(ms(250));
      await report('playing', 10500, speed: 2);
      await tester.pump(ms(1000));
      await report('playing', 10540, speed: 2);
      await tester.pump(ms(250));
      await report('playing', 10520, speed: 2);
      expect(clock(), 13000, reason: 'two reports 2 s and 2.5 s behind');

      await tester.pump(ms(250));
      await report('playing', 13500, speed: 2);
      expect(clock(), 13500);
      controller.dispose();
    });

    testWidgets('one report seconds behind is ignored', (tester) async {
      // Measured: straight after a 10 s seek the adaptive demuxer reported
      // 29078, then 22161, then 29277.
      await attach();
      await report('playing', 19078);
      await controller.seekTo(ms(29078));
      await report('playing', 29078);

      await tester.pump(ms(254));
      await report('playing', 22161);
      expect(clock(), 29332);

      await tester.pump(ms(292));
      await report('playing', 29277);
      expect(clock(), 29624, reason: 'never back from where it was');
      await tester.pump(ms(523 + 270));
      await report('playing', 30284);
      expect(clock(), 30284);
      controller.dispose();
    });

    testWidgets('a jump back is believed when the next report agrees', (
      tester,
    ) async {
      await attach();
      await report('playing', 60000);
      await tester.pump(ms(250));
      await report('playing', 20000);
      expect(clock(), 60250);

      await tester.pump(ms(250));
      await report('playing', 20250);
      expect(clock(), 20250);
      await tester.pump(ms(100));
      expect(clock(), 20350);
      controller.dispose();
    });
  });

  group('run ahead of the engine', () {
    // Races that leave the clock running on from a report ahead of playback,
    // while the engine's own reports trail it by less than the stale window:
    // each moves, so none is late enough to run out on, and none is the
    // freshest. The clock waits where it is for the engine to catch up.

    testWidgets('by one stale report after a short seek back', (tester) async {
      // The desktops and iOS echo the target; a time update from before the
      // seek can still be on its way, and the clock is guessing when it lands.
      await attach();
      for (var i = 0; i <= 4; i++) {
        await report('playing', 10000 + 250 * i);
        if (i < 4) await tester.pump(ms(250));
      }
      await tester.pump(ms(100));
      await controller.seekTo(ms(10600));
      await report('playing', 10600);
      await report('playing', 11100);

      final errors = await playOn(tester, from: 10600);
      expect(errors.first, 500);
      expect(errors.sublist(16), everyElement(0));
      controller.dispose();
    });

    testWidgets('by a seek to the throttled position, run past twice before '
        'it lands', (tester) async {
      // A track switch's re-seat on VLCKit: the cached time runs on along the
      // old timeline after the seek is asked for, and the seek then lands
      // where the throttled value was, behind both.
      await attach(eventThrottleInterval: ms(250));
      for (var i = 0; i <= 8; i++) {
        await report('playing', 10000 + 250 * i);
        if (i < 8) await tester.pump(ms(250));
      }
      final published = controller.value.position.inMilliseconds;
      await controller.seekTo(controller.value.position);
      await tester.pump(ms(60));
      await report('playing', 12250);
      await tester.pump(ms(250));
      await report('playing', 12500);
      await tester.pump(ms(200));
      await report('playing', published);

      final errors = await playOn(tester, from: published);
      expect(errors.first, 950);
      expect(errors.sublist(16), everyElement(0));
      await tester.pump(ms(300));
      controller.dispose();
    });

    testWidgets('by the engine\'s time going back a second with no seek', (
      tester,
    ) async {
      await attach();
      for (var i = 0; i <= 8; i++) {
        await report('playing', 10000 + 250 * i);
        if (i < 8) await tester.pump(ms(250));
      }

      final errors = await playOn(tester, from: 11000);
      expect(errors.first, 1000);
      expect(errors.sublist(16), everyElement(0));
      controller.dispose();
    });

    testWidgets('by a 600 ms freeze the engine says nothing about', (
      tester,
    ) async {
      await attach();
      for (var i = 0; i <= 4; i++) {
        await report('playing', 10000 + 250 * i);
        if (i < 4) await tester.pump(ms(250));
      }
      await tester.pump(ms(600 + 250));
      await report('playing', 11250);

      final errors = await playOn(tester, from: 11250);
      expect(errors.first, 600);
      expect(errors.sublist(16), everyElement(0));
      controller.dispose();
    });

    testWidgets('by an engine playing slower than the clock, which it follows '
        'without stepping back', (tester) async {
      // At four-fifths of the speed it reports, each report falls another
      // 50 ms behind the clock.
      await attach();
      await report('playing', 10000);

      final errors = await playOn(tester, from: 10000, count: 48, rate: 0.8);
      expect(errors, everyElement(lessThan(1000)));
      controller.dispose();
    });

    // An adaptive stream's time holds still, then steps up to where playback
    // is about every 1.13 s of wall time; a desktop backend polls it every
    // 500 ms and may see a step half a second late. None of that is the clock
    // running ahead, and the clock never stops to wait for such a report.
    for (final (speed, every) in const [
      (1.0, 280),
      (1.0, 500),
      (2.0, 280),
      (2.0, 500),
      (3.0, 280),
      (3.0, 500),
    ]) {
      testWidgets('not by an adaptive stream\'s staircase at ${speed}x, '
          'reported every $every ms', (tester) async {
        await attach();
        int playing(int t) => 60000 + (speed * t).round();
        await report('playing', playing(0), speed: speed);
        var last = clock();
        var wobble = 0;
        final stills = <String>[];
        for (var t = 0; t < 30000;) {
          final next = t + every;
          while (t + 16 < next) {
            await tester.pump(ms(16));
            t += 16;
            expect(clock(), greaterThanOrEqualTo(last), reason: 'at $t ms');
            if (clock() == last && t > 1500) stills.add('$t ms');
            last = clock();
          }
          await tester.pump(ms(next - t));
          t = next;
          // A few milliseconds either side of the step, as measured.
          wobble = (wobble * 7 + 13) % 41;
          await report(
            'playing',
            playing(t ~/ 1130 * 1130) + wobble - 20,
            speed: speed,
          );
          expect(clock(), greaterThanOrEqualTo(last), reason: 'at $t ms');
          last = clock();
        }
        expect(stills, isEmpty);
        controller.dispose();
      });
    }
  });

  group('pause and speed', () {
    testWidgets('counts only the time spent playing', (tester) async {
      // Every backend reports the position it paused at again on resume; the
      // next time update comes later.
      await attach();
      await report('playing', 4000);
      await tester.pump(ms(200));
      await report('paused', 4200);
      await tester.pump(ms(3000));
      expect(clock(), 4200);
      expect(controller.playbackClock.timeUntil(ms(4300)), isNull);

      await report('playing', 4200);
      expect(clock(), 4200, reason: 'the pause is not run on');
      await tester.pump(ms(100));
      expect(clock(), 4300);
      controller.dispose();
    });

    testWidgets('paused, follows the engine forward but not back', (
      tester,
    ) async {
      await attach();
      await report('paused', 6000);
      expect(clock(), 6000);
      await report('paused', 9000);
      expect(clock(), 9000);

      // Behind, with no seek asked for: a report from before the pause.
      await report('paused', 8000);
      expect(clock(), 9000);
      controller.dispose();
    });

    testWidgets('a speed change part-way between reports re-bases the clock', (
      tester,
    ) async {
      await attach();
      await report('playing', 10000, speed: 2);
      await tester.pump(ms(100));
      expect(clock(), 10200);
      expect(controller.playbackClock.timeUntil(ms(10300)), ms(50));

      // The snapshot after the change still carries the last time update.
      await report('playing', 10000);
      expect(clock(), 10200);
      await tester.pump(ms(100));
      expect(clock(), 10300);
      await tester.pump(ms(50));
      await report('playing', 10350);
      expect(clock(), 10350);
      controller.dispose();
    });
  });

  group('seeks', () {
    testWidgets('jumps to the target at once and holds there until the '
        'engine arrives', (tester) async {
      await attach();
      await report('playing', 600000);

      await controller.seekTo(ms(1800000));
      expect(clock(), 1800000);
      expect(controller.playbackClock.timeUntil(ms(1800100)), isNull);

      // VLCKit reports the position it left until the seek lands.
      await tester.pump(ms(500));
      await report('playing', 600500);
      expect(clock(), 1800000);

      await report('playing', 1800000);
      await tester.pump(ms(100));
      expect(clock(), 1800100);
      controller.dispose();
    });

    testWidgets('half a second back while playing', (tester) async {
      await attach();
      await report('playing', 8100);

      await controller.seekTo(ms(7600));
      expect(clock(), 7600);
      // Android and the desktops report the target straight away.
      await report('playing', 7600);
      expect(clock(), 7600);
      await tester.pump(ms(100));
      expect(clock(), 7700);
      controller.dispose();
    });

    testWidgets('1.5 s back from where the clock has run on to', (
      tester,
    ) async {
      await attach();
      await report('playing', 8000);
      await tester.pump(ms(900));
      expect(clock(), 8900);

      await controller.seekTo(ms(7400));
      expect(clock(), 7400);
      await report('playing', 7400);
      await tester.pump(ms(100));
      expect(clock(), 7500);
      controller.dispose();
    });

    testWidgets('a seek made while paused counts though the engine never '
        'reports it', (tester) async {
      // VLCKit's cached time does not move on a seek and does not tick while
      // paused; on play it reports the old time once, then the new one.
      await attach();
      await report('playing', 8100);
      await report('paused', 8100);

      await controller.seekTo(ms(7700));
      expect(clock(), 7700);
      await tester.pump(ms(1000));
      expect(clock(), 7700);

      await report('playing', 8100);
      expect(clock(), 7700);
      await tester.pump(ms(10));
      await report('playing', 7700);
      expect(clock(), 7700);
      await tester.pump(ms(100));
      expect(clock(), 7800);
      controller.dispose();
    });

    testWidgets('lands on the engine\'s report, not when the throttle lets '
        'it out', (tester) async {
      await attach(eventThrottleInterval: ms(250));
      await report('playing', 8100);
      await controller.seekTo(ms(7600));

      await report('playing', 7600);
      await tester.pump(ms(100));
      expect(controller.pendingSeekTarget.value, ms(7600));
      expect(clock(), 7700);

      await tester.pump(ms(250));
      controller.dispose();
    });

    testWidgets('in a burst the clock shows the last target, and an earlier '
        'one landing does not release it', (tester) async {
      await attach();
      await report('playing', 600000);

      await controller.seekTo(ms(610000));
      await controller.seekTo(ms(620000));
      expect(clock(), 620000);
      await report('playing', 610000);
      expect(clock(), 620000);

      await tester.pump(VlcPlayerController.seekMergeWindow);
      await report('playing', 620000);
      await tester.pump(ms(100));
      expect(clock(), 620100);
      controller.dispose();
    });

    testWidgets('a seek the engine never takes is let go when the controller '
        'gives up on it, after asking once more', (tester) async {
      await attach();
      await report('playing', 600000);
      await controller.seekTo(ms(1800000));

      // A dozen reports carrying on send the seek once more; a second dozen
      // give it up.
      for (var step = 1; step <= 23; step++) {
        await tester.pump(ms(250));
        await report('playing', 600000 + step * 250);
      }
      expect(clock(), 1800000);
      expect(controller.pendingSeekTarget.value, ms(1800000));

      await tester.pump(ms(250));
      await report('playing', 606000);
      expect(controller.pendingSeekTarget.value, isNull);
      expect(clock(), 606000);
      await tester.pump(ms(100));
      expect(clock(), 606100);
      controller.dispose();
    });

    testWidgets('a seek echoed and then refused waits at its target again '
        'when it is sent once more', (tester) async {
      await attach();
      await report('playing', 600000);
      await controller.seekTo(ms(1800000));

      // The time reported straight back, then the engine carrying on from
      // where it was: libVLC refused the seek.
      await report('playing', 1800000);
      for (var step = 1; step <= 12; step++) {
        await tester.pump(ms(250));
        await report('playing', 600000 + step * 250);
      }
      expect(controller.pendingSeekTarget.value, ms(1800000));
      expect(clock(), 1800000);
      controller.dispose();
    });

    testWidgets('a seek let go runs on at the speed the engine plays at', (
      tester,
    ) async {
      // The viewer picks 2x while a seek is on its way: the snapshots that say
      // so come while the clock waits at the target.
      await attach();
      await report('playing', 600000);
      await controller.seekTo(ms(1800000));

      for (var step = 1; step <= 24; step++) {
        await tester.pump(ms(250));
        await report('playing', 600000 + step * 500, speed: 2);
      }
      expect(controller.pendingSeekTarget.value, isNull);
      expect(clock(), 612000);
      await tester.pump(ms(100));
      expect(clock(), 612200);
      controller.dispose();
    });
  });

  group('starting', () {
    testWidgets('the first report, from behind the clock, takes over without '
        'a step back', (tester) async {
      // Measured: playing at 0, then the first time update said 249 ms when
      // 283 ms had gone by.
      await attach();
      await report('opening', 0);
      await report('playing', 0);
      await tester.pump(ms(283));
      expect(clock(), 283);

      await report('playing', 249);
      expect(clock(), 283);
      await tester.pump(ms(17));
      expect(clock(), 283);
      await tester.pump(ms(17));
      expect(clock(), 283);
      await tester.pump(ms(100));
      expect(clock(), 383);
      controller.dispose();
    });

    testWidgets('the snapshot playback starts on is not a time update', (
      tester,
    ) async {
      // Measured on a desktop poll of an adaptive stream: playing at 0, and
      // the time half a second later 141 - the picture had started 140 ms
      // after the engine said it was playing.
      await attach();
      await report('playing', 0);
      await tester.pump(ms(501));
      expect(clock(), 501);

      await report('playing', 141);
      expect(clock(), 501);
      await tester.pump(ms(460));
      expect(clock(), 601, reason: 'runs on from the time update');
      controller.dispose();
    });

    testWidgets('new media starts at its start position, and its reports of '
        '0 before the resume point do not take it back there', (tester) async {
      await attach();
      await report('playing', 2700000);

      await controller.setMedia(
        VlcMediaSource(
          uri: Uri.parse('https://example.com/next.mkv'),
          startPosition: const Duration(minutes: 12),
        ),
      );
      expect(clock(), 720000);

      await report('opening', 0);
      await report('buffering', 0);
      await report('playing', 0);
      expect(clock(), 720000);
      await tester.pump(ms(250));
      await report('playing', 720250);
      expect(clock(), 720250);
      await tester.pump(ms(100));
      expect(clock(), 720350);
      controller.dispose();
    });

    testWidgets('a stop or a failure stops the clock where the engine says', (
      tester,
    ) async {
      await attach();
      await report('playing', 5000);
      await tester.pump(ms(100));
      await report('stopped', 0);
      expect(clock(), 0);
      await tester.pump(ms(500));
      expect(clock(), 0);

      await report('playing', 4000);
      await tester.pump(ms(100));
      await report('error', 4100);
      await tester.pump(ms(500));
      expect(clock(), 4100);
      controller.dispose();
    });

    testWidgets('a failure of the event channel stops it too', (tester) async {
      await attach();
      await report('playing', 5000);
      await tester.pump(ms(100));

      await harness.sendError(1, code: 'channel_failed');
      expect(controller.value.hasError, isTrue);
      expect(clock(), 5000);
      await tester.pump(ms(500));
      expect(clock(), 5000);
      controller.dispose();
    });
  });

  group('for a reader', () {
    testWidgets('hears every report ahead of the event throttle', (
      tester,
    ) async {
      await attach(eventThrottleInterval: ms(250));
      await report('playing', 10000);
      await tester.pump(ms(100));

      await report('playing', 10500);
      expect(clock(), 10500);
      expect(controller.value.position, ms(10000), reason: 'throttled');

      await tester.pump(ms(250));
      controller.dispose();
    });

    testWidgets('is told when the clock changes course, not as it runs', (
      tester,
    ) async {
      await attach();
      final VlcPlaybackClock playbackClock = controller.playbackClock;
      var told = 0;
      playbackClock.addListener(() => told++);

      await report('playing', 10000);
      expect(told, 1);
      await tester.pump(ms(500));
      expect(told, 1);

      await report('playing', 10000);
      expect(told, 1, reason: 'a report that changes nothing');
      await report('playing', 10500);
      expect(told, 2);
      await controller.seekTo(ms(20000));
      expect(told, 3);
      controller.dispose();
    });
  });
}
