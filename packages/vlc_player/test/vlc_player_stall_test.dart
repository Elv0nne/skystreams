import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// The stall signal comes from the position clock, not from libVLC's state.
///
/// The bug this file holds shut: on every platform but Android, libVLC keeps
/// reporting `playing` through a rebuffer, so a spinner keyed on
/// `state == buffering` never showed and a viewer stared at a frozen frame
/// under a pause glyph for up to 25 seconds. The only honest evidence of a
/// stall is a position that has stopped moving on a player that says it is
/// running, and the controller owns that judgement so every host gets it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const delay = Duration(milliseconds: 1000);
  late VlcMethodChannelHarness harness;

  setUp(() {
    harness = VlcMethodChannelHarness()..install();
  });

  tearDown(() {
    harness.dispose();
  });

  Map<String, Object?> snapshot({
    String state = 'playing',
    required int position,
  }) {
    return <String, Object?>{
      'state': state,
      'position': position,
      'duration': 3600000,
      'isReady': true,
    };
  }

  /// An attached controller whose clock has demonstrably run: two snapshots
  /// at different positions, so the pre-first-frame guard is behind it.
  Future<VlcPlayerController> running(
    int viewId, {
    Duration? eventThrottleInterval,
  }) async {
    final controller = VlcPlayerController(
      eventThrottleInterval: eventThrottleInterval,
      stallIndicatorDelay: delay,
    );
    harness.mockEventChannel(viewId);
    await harness.attachController(controller, viewId);
    await harness.sendEvent(viewId, snapshot(position: 1000));
    await harness.sendEvent(viewId, snapshot(position: 2000));
    return controller;
  }

  group('configuration', () {
    test('the delay defaults to a second and must be positive', () {
      final controller = VlcPlayerController();
      addTearDown(controller.dispose);
      expect(controller.stallIndicatorDelay, delay);
      expect(
        () => VlcPlayerController(stallIndicatorDelay: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => VlcPlayerController(
          stallIndicatorDelay: const Duration(milliseconds: -1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('raising the flag', () {
    testWidgets('silence after the last moved snapshot raises isStalled', (
      tester,
    ) async {
      // Every native except Android suppresses a snapshot identical to the
      // last one it sent. A real freeze therefore never arrives as a repeated
      // position - it arrives as nothing at all. The deadline has to count
      // from the last snapshot that moved, or the flag is dead on four of
      // five platforms.
      final controller = await running(21);
      addTearDown(controller.dispose);
      // No further events: the wire has gone quiet.

      await tester.pump(delay - const Duration(milliseconds: 1));
      expect(controller.value.isStalled, isFalse);

      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value.isStalled, isTrue);
    });

    testWidgets('a moved snapshot restarts the silence countdown', (
      tester,
    ) async {
      final controller = await running(22);
      addTearDown(controller.dispose);

      await tester.pump(const Duration(milliseconds: 700));
      await harness.sendEvent(22, snapshot(position: 3000));
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        controller.value.isStalled,
        isFalse,
        reason: 'only 700 ms of silence since the last movement',
      );

      await tester.pump(const Duration(milliseconds: 301));
      expect(controller.value.isStalled, isTrue);
    });

    testWidgets('a frozen clock raises isStalled after the delay, not before', (
      tester,
    ) async {
      final controller = await running(1);
      addTearDown(controller.dispose);

      await harness.sendEvent(1, snapshot(position: 2000));
      expect(controller.value.isStalled, isFalse);

      await tester.pump(delay - const Duration(milliseconds: 1));
      expect(controller.value.isStalled, isFalse);

      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value.isStalled, isTrue);
      expect(controller.value.state, VlcPlaybackState.playing);
    });

    testWidgets('the countdown starts at the first frozen snapshot', (
      tester,
    ) async {
      // Later identical snapshots must not push the deadline out, or a 500 ms
      // desktop poll would keep the spinner from ever appearing.
      final controller = await running(2);
      addTearDown(controller.dispose);

      await harness.sendEvent(2, snapshot(position: 2000));
      await tester.pump(const Duration(milliseconds: 500));
      await harness.sendEvent(2, snapshot(position: 2000));
      await tester.pump(const Duration(milliseconds: 500));

      expect(controller.value.isStalled, isTrue);
    });

    testWidgets('a running clock never raises it', (tester) async {
      final controller = await running(3);

      for (var position = 2500; position <= 6000; position += 500) {
        await harness.sendEvent(3, snapshot(position: position));
        await tester.pump(const Duration(milliseconds: 500));
      }

      expect(controller.value.isStalled, isFalse);
      // A moving clock keeps the stall watchdog armed, and flutter_test checks
      // for pending timers BEFORE tearDowns run - so a test that ends with
      // playback healthy has to dispose in-body.
      controller.dispose();
    });

    testWidgets('a frozen clock under the buffering state counts too', (
      tester,
    ) async {
      // Android does report buffering mid-play; the two signals must agree.
      final controller = await running(4);
      addTearDown(controller.dispose);

      await harness.sendEvent(4, snapshot(state: 'buffering', position: 2000));
      await tester.pump(delay);

      expect(controller.value.isStalled, isTrue);
    });
  });

  group('clearing the flag', () {
    testWidgets('a moving clock clears it in the same publish', (tester) async {
      final controller = await running(5);
      await harness.sendEvent(5, snapshot(position: 2000));
      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);

      final published = <VlcPlayerValue>[];
      controller.addListener(() => published.add(controller.value));

      await harness.sendEvent(5, snapshot(position: 2500));

      // Never a frame that says "moved to 2500 and still stalled".
      expect(published, hasLength(1));
      expect(published.single.position, const Duration(milliseconds: 2500));
      expect(published.single.isStalled, isFalse);
      // A moving clock keeps the stall watchdog armed, and flutter_test checks
      // for pending timers BEFORE tearDowns run - so a test that ends with
      // playback healthy has to dispose in-body.
      controller.dispose();
    });

    testWidgets('a seek backwards is movement, not a deeper stall', (
      tester,
    ) async {
      // "Advanced" would hold the spinner up until playback overtook the
      // pre-seek position.
      final controller = await running(6);
      await harness.sendEvent(6, snapshot(position: 2000));
      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);

      await harness.sendEvent(6, snapshot(position: 500));
      expect(controller.value.isStalled, isFalse);

      await harness.sendEvent(6, snapshot(position: 1000));
      // Movement RESTARTS the countdown. Silence for the full delay after the
      // backwards seek would be a stall (natives dedupe, so silence is what a
      // freeze looks like); just short of it, the seek has to have cleared it.
      await tester.pump(delay - const Duration(milliseconds: 1));
      expect(controller.value.isStalled, isFalse);
      // A moving clock keeps the stall watchdog armed, and flutter_test checks
      // for pending timers BEFORE tearDowns run - so a test that ends with
      // playback healthy has to dispose in-body.
      controller.dispose();
    });

    testWidgets('pausing clears it in the same publish and stops the clock', (
      tester,
    ) async {
      final controller = await running(7);
      addTearDown(controller.dispose);
      await harness.sendEvent(7, snapshot(position: 2000));
      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);

      await harness.sendEvent(7, snapshot(state: 'paused', position: 2000));
      expect(controller.value.isStalled, isFalse);

      // A paused player's clock is frozen by definition.
      await harness.sendEvent(7, snapshot(state: 'paused', position: 2000));
      await tester.pump(delay * 2);
      expect(controller.value.isStalled, isFalse);
    });

    testWidgets('ended, stopped and error are never stalled', (tester) async {
      for (final (index, state) in <String>[
        'ended',
        'stopped',
        'error',
      ].indexed) {
        final viewId = 8 + index;
        final controller = await running(viewId);
        addTearDown(controller.dispose);
        await harness.sendEvent(viewId, snapshot(position: 2000));
        await tester.pump(delay);
        expect(controller.value.isStalled, isTrue, reason: state);

        await harness.sendEvent(viewId, snapshot(state: state, position: 2000));
        expect(controller.value.isStalled, isFalse, reason: state);
        await tester.pump(delay);
        expect(controller.value.isStalled, isFalse, reason: state);
      }
    });
  });

  group('what is not a stall', () {
    testWidgets('a clock that has never run is not watched', (tester) async {
      // Before the first frame the startup buffer owns the spinner; a live
      // stream whose position never moves must not spin forever.
      final controller = VlcPlayerController(stallIndicatorDelay: delay);
      addTearDown(controller.dispose);
      harness.mockEventChannel(20);
      await harness.attachController(controller, 20);

      await harness.sendEvent(20, snapshot(state: 'buffering', position: 0));
      await harness.sendEvent(20, snapshot(position: 0));
      await harness.sendEvent(20, snapshot(position: 0));
      await tester.pump(delay * 2);

      expect(controller.value.isStalled, isFalse);
    });

    testWidgets('new media resets the clock and the old stall goes with it', (
      tester,
    ) async {
      final controller = await running(21);
      addTearDown(controller.dispose);
      await harness.sendEvent(21, snapshot(position: 2000));
      await tester.pump(const Duration(milliseconds: 500));

      await controller.setMedia(
        VlcMediaSource(uri: Uri.parse('https://example.com/next.mp4')),
      );
      // Nothing has arrived from the new item yet; the old countdown must not
      // finish against it.
      await tester.pump(delay);
      expect(controller.value.isStalled, isFalse);

      // The new item's opening buffer, then a playing snapshot at zero.
      await harness.sendEvent(21, snapshot(state: 'opening', position: 0));
      await harness.sendEvent(21, snapshot(position: 0));
      await harness.sendEvent(21, snapshot(position: 0));
      await tester.pump(delay * 2);

      expect(controller.value.isStalled, isFalse);
    });

    testWidgets('pause() stops the clock before the paused snapshot arrives', (
      tester,
    ) async {
      final controller = await running(22);
      addTearDown(controller.dispose);
      await harness.sendEvent(22, snapshot(position: 2000));
      await tester.pump(const Duration(milliseconds: 500));

      await controller.pause();
      await tester.pump(delay);

      expect(controller.value.isStalled, isFalse);
    });

    testWidgets('stop() stops the clock', (tester) async {
      final controller = await running(23);
      addTearDown(controller.dispose);
      await harness.sendEvent(23, snapshot(position: 2000));

      await controller.stop();
      await tester.pump(delay);

      expect(controller.value.isStalled, isFalse);
    });

    testWidgets('dispose cancels the clock', (tester) async {
      // No pump and no assertion: testWidgets fails the test on its own if a
      // timer is still pending when it ends.
      final controller = await running(24);
      await harness.sendEvent(24, snapshot(position: 2000));

      controller.dispose();
    });
  });

  group('seeking', () {
    testWidgets('a seek takes a raised flag down for its first second', (
      tester,
    ) async {
      // Spec 4: the first second after a committed seek shows no spinner,
      // even when the clock was already standing still before it.
      final controller = await running(36);
      addTearDown(controller.dispose);
      await harness.sendEvent(36, snapshot(position: 2000));
      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);

      await controller.seekTo(const Duration(minutes: 1));
      expect(controller.value.isStalled, isFalse);

      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);
    });

    testWidgets('a seek to where playback already is leaves the flag up', (
      tester,
    ) async {
      // The player screen's stall watchdog re-issues the current position to
      // kick a stream that stopped. That seek goes nowhere new and the
      // picture stays frozen, so the spinner stays: spec 4's first second is
      // for a seek to another place.
      final controller = await running(37);
      addTearDown(controller.dispose);
      await harness.sendEvent(37, snapshot(position: 2000));
      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);

      await controller.seekTo(const Duration(milliseconds: 2000));
      expect(controller.value.isStalled, isTrue);
      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);
    });

    testWidgets('a seek sent again to the target on its way leaves it up', (
      tester,
    ) async {
      // The watchdog's re-issue goes to a seek still on its way when there is
      // one: that seek had its first second already.
      final controller = await running(38);
      addTearDown(controller.dispose);
      await controller.seekTo(const Duration(minutes: 1));
      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);

      await controller.seekTo(const Duration(minutes: 1));
      expect(controller.value.isStalled, isTrue);
      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);
    });

    testWidgets('seekTo re-arms so the gap to the new frame shows', (
      tester,
    ) async {
      final controller = await running(30);
      addTearDown(controller.dispose);

      await controller.seekTo(const Duration(minutes: 1));
      await tester.pump(delay - const Duration(milliseconds: 1));
      expect(controller.value.isStalled, isFalse);

      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value.isStalled, isTrue);
    });

    testWidgets('the engine echoing the seek target is not movement', (
      tester,
    ) async {
      // Every backend reports the requested time before a frame exists there.
      // Judged against the pre-seek position that echo looks like progress and
      // would push the spinner out by a whole extra delay.
      final controller = await running(31);

      await controller.seekTo(const Duration(milliseconds: 60000));
      await tester.pump(const Duration(milliseconds: 500));
      await harness.sendEvent(31, snapshot(position: 60000));
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.value.isStalled, isTrue);

      await harness.sendEvent(31, snapshot(position: 60040));
      expect(controller.value.isStalled, isFalse);
      // A moving clock keeps the stall watchdog armed, and flutter_test checks
      // for pending timers BEFORE tearDowns run - so a test that ends with
      // playback healthy has to dispose in-body.
      controller.dispose();
    });

    testWidgets('a seek that lands promptly never shows', (tester) async {
      final controller = await running(32);

      await controller.seekTo(const Duration(milliseconds: 60000));
      await tester.pump(const Duration(milliseconds: 300));
      await harness.sendEvent(32, snapshot(position: 60040));
      // The landing restarts the countdown that seekTo armed; had it not, the
      // seek timer would fire here. Silence for the FULL delay after landing
      // would be a genuine stall, so stop one tick short of it.
      await tester.pump(delay - const Duration(milliseconds: 1));

      expect(controller.value.isStalled, isFalse);
      // A moving clock keeps the stall watchdog armed, and flutter_test checks
      // for pending timers BEFORE tearDowns run - so a test that ends with
      // playback healthy has to dispose in-body.
      controller.dispose();
    });

    testWidgets('seeking a paused player arms nothing', (tester) async {
      final controller = await running(33);
      addTearDown(controller.dispose);
      await harness.sendEvent(33, snapshot(state: 'paused', position: 2000));

      await controller.seekTo(const Duration(minutes: 1));
      await tester.pump(delay * 2);

      expect(controller.value.isStalled, isFalse);
    });
  });

  group('under an event throttle', () {
    testWidgets(
      'a pending throttled value carries the flag through its flush',
      (tester) async {
        // Throttle longer than the delay so the flush lands AFTER the stall
        // fires; a flush that overwrote the flag with the pre-stall snapshot it
        // was holding would clear the spinner while the frame is still frozen.
        final controller = await running(
          40,
          eventThrottleInterval: const Duration(milliseconds: 2000),
        );
        addTearDown(controller.dispose);
        // The 2000 snapshot from running() is still pending: 1000 published,
        // 2000 coalesced. A repeat freezes the clock at 2000.
        expect(controller.value.position, const Duration(milliseconds: 1000));
        await harness.sendEvent(40, snapshot(position: 2000));

        await tester.pump(delay);
        expect(controller.value.isStalled, isTrue);
        expect(controller.value.position, const Duration(milliseconds: 1000));

        await tester.pump(delay);
        expect(controller.value.position, const Duration(milliseconds: 2000));
        expect(controller.value.isStalled, isTrue);
      },
    );

    testWidgets('clearing the flag is never coalesced as a progress tick', (
      tester,
    ) async {
      final controller = await running(
        41,
        eventThrottleInterval: const Duration(milliseconds: 250),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await harness.sendEvent(41, snapshot(position: 2000));
      await tester.pump(delay);
      expect(controller.value.isStalled, isTrue);

      await harness.sendEvent(41, snapshot(position: 2500));

      // No pump: the clear must not wait for the throttle window.
      expect(controller.value.isStalled, isFalse);
      expect(controller.value.position, const Duration(milliseconds: 2500));
      // A moving clock keeps the stall watchdog armed, and flutter_test checks
      // for pending timers BEFORE tearDowns run - so a test that ends with
      // playback healthy has to dispose in-body.
      controller.dispose();
    });

    testWidgets('a coalesced first frame still counts as having played', (
      tester,
    ) async {
      // The host throttles at 250 ms, so the first real position is almost
      // always a coalesced tick. If only immediate publishes could mark the
      // media as played, the clock could never arm in production.
      final controller = VlcPlayerController(
        eventThrottleInterval: const Duration(milliseconds: 250),
        stallIndicatorDelay: delay,
      );
      addTearDown(controller.dispose);
      harness.mockEventChannel(42);
      await harness.attachController(controller, 42);

      await harness.sendEvent(42, snapshot(position: 0));
      await harness.sendEvent(42, snapshot(position: 1000));
      await harness.sendEvent(42, snapshot(position: 1000));
      await tester.pump(delay);

      expect(controller.value.isStalled, isTrue);
    });
  });

  group('a clock that moves in whole-second steps', () {
    // libVLC's HLS time, and the TV emulator's time events, move about once
    // a second: a step a little late raised the flag and the next took it
    // down, a 1-177 ms spinner over a playing picture (FORK.md 36).
    testWidgets('a step a little late raises no flag', (tester) async {
      final controller = await running(31);
      await tester.pump(const Duration(milliseconds: 1000));
      await harness.sendEvent(31, snapshot(position: 3000));
      await tester.pump(const Duration(milliseconds: 1150));
      expect(controller.value.isStalled, isFalse);
      await harness.sendEvent(31, snapshot(position: 4000));
      expect(controller.value.isStalled, isFalse);
      // A moving clock keeps the watchdog armed: dispose in the body.
      controller.dispose();
    });

    testWidgets('frozen, it raises the flag a quarter second later', (
      tester,
    ) async {
      final controller = await running(32);
      addTearDown(controller.dispose);
      await tester.pump(const Duration(milliseconds: 1000));
      await harness.sendEvent(32, snapshot(position: 3000));
      await tester.pump(const Duration(milliseconds: 1249));
      expect(controller.value.isStalled, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value.isStalled, isTrue);
    });

    testWidgets('a clock moving every 250 ms keeps the second', (tester) async {
      final controller = await running(33);
      addTearDown(controller.dispose);
      for (final position in const [2250, 2500, 2750]) {
        await tester.pump(const Duration(milliseconds: 250));
        await harness.sendEvent(33, snapshot(position: position));
      }
      await tester.pump(const Duration(milliseconds: 999));
      expect(controller.value.isStalled, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.value.isStalled, isTrue);
    });
  });
}
