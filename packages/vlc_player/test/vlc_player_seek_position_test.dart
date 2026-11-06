import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// [VlcPlayerController.pendingSeekTarget]: where a seek is going while the
/// engine still reports where it was.
///
/// libVLC answers a seek with the position it left for as long as the stream
/// takes to reach the new one - seconds, on a network file - so a scrubber
/// drawn from the position alone sprang back to where the viewer was and
/// jumped forward when the buffer filled. Media3 and the browsers report the
/// target from the moment a seek is asked for. The controller keeps the
/// engine's own position as it is - resume points and relative steps must
/// only ever see places playback reached - and publishes the target beside
/// it for the scrubber and the clock.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  /// An attached controller playing at 10:00.
  Future<VlcPlayerController> playing(int viewId) async {
    final controller = VlcPlayerController();
    harness.mockEventChannel(viewId);
    await harness.attachController(controller, viewId);
    await harness.sendEvent(viewId, snapshot(position: 600000));
    return controller;
  }

  Duration ms(int value) => Duration(milliseconds: value);

  testWidgets('the target is published the moment the seek is asked for, and '
      'the position stays the engine\'s', (tester) async {
    final controller = await playing(1);
    final seen = <Duration?>[];
    controller.pendingSeekTarget.addListener(
      () => seen.add(controller.pendingSeekTarget.value),
    );

    await controller.seekTo(const Duration(minutes: 30));

    expect(seen, <Duration?>[const Duration(minutes: 30)]);
    expect(controller.value.position, ms(600000));
    // The stall clock and the merge window are both armed by the seek; ending
    // healthy means disposing in-body, before flutter_test checks for pending
    // timers.
    controller.dispose();
  });

  testWidgets('it holds while the engine still reports where it was, and '
      'goes when the engine arrives', (tester) async {
    final controller = await playing(2);

    await controller.seekTo(const Duration(minutes: 30));
    // Refilling at the new place: the engine repeats the old position.
    await harness.sendEvent(2, snapshot(state: 'buffering', position: 600000));
    await harness.sendEvent(2, snapshot(state: 'buffering', position: 600000));
    await tester.pump(const Duration(seconds: 10));
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));

    await harness.sendEvent(2, snapshot(position: 1800040));
    expect(controller.pendingSeekTarget.value, isNull);
    expect(controller.value.position, ms(1800040));
    controller.dispose();
  });

  testWidgets('a landing a little short of the target counts', (tester) async {
    // A keyframe or an HLS segment boundary before the millisecond asked for.
    final controller = await playing(3);

    await controller.seekTo(const Duration(minutes: 30));
    await harness.sendEvent(3, snapshot(position: 1797600));

    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('backwards too, and past the target in the seek\'s direction', (
    tester,
  ) async {
    final controller = await playing(4);

    await controller.seekTo(const Duration(minutes: 5));
    // A report from the old place, a little on.
    await harness.sendEvent(4, snapshot(position: 600500));
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 5));

    // A keyframe well before the target is still the seek landing.
    await harness.sendEvent(4, snapshot(position: 290000));
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a chain of steps is not undone by an earlier step landing', (
    tester,
  ) async {
    // Three presses of a D-pad's Right before the first has landed.
    final controller = await playing(5);

    await controller.seekTo(ms(610000));
    await controller.seekTo(ms(620000));
    await controller.seekTo(ms(630000));
    expect(controller.pendingSeekTarget.value, ms(630000));

    await harness.sendEvent(5, snapshot(position: 610000));
    await harness.sendEvent(5, snapshot(position: 620000));
    expect(controller.pendingSeekTarget.value, ms(630000));

    await harness.sendEvent(5, snapshot(position: 630020));
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a short step cannot be landed by the report it left from', (
    tester,
  ) async {
    final controller = await playing(6);

    await controller.seekTo(ms(602000));
    await harness.sendEvent(6, snapshot(position: 600250));

    expect(controller.pendingSeekTarget.value, ms(602000));
    controller.dispose();
  });

  testWidgets('a paused seek holds its target too', (tester) async {
    final controller = await playing(7);
    await harness.sendEvent(7, snapshot(state: 'paused', position: 600000));

    await controller.seekTo(const Duration(minutes: 20));
    await harness.sendEvent(7, snapshot(state: 'paused', position: 600000));

    expect(controller.pendingSeekTarget.value, const Duration(minutes: 20));
    // A seek leaves its merge window open; see the first test.
    controller.dispose();
  });

  testWidgets('an engine that stops, ends or fails lets the target go', (
    tester,
  ) async {
    final controller = await playing(8);

    await controller.seekTo(const Duration(minutes: 30));
    await harness.sendEvent(8, snapshot(state: 'ended', position: 3600000));

    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('new media drops the old media\'s target', (tester) async {
    final controller = await playing(9);
    addTearDown(controller.dispose);

    await controller.seekTo(const Duration(minutes: 30));
    await controller.setMedia(
      VlcMediaSource(uri: Uri.parse('https://example.com/next.mkv')),
    );

    expect(controller.pendingSeekTarget.value, isNull);
  });

  testWidgets('playback carrying on elsewhere gets the seek sent once more, '
      'then is a seek that did not happen', (tester) async {
    // An engine that took the call and ignored it: libVLC 3 has been seen
    // dropping an HLS seek. The controller asks once more; when the engine
    // carries on again, the scrubber follows it rather than sit on a target
    // twenty minutes away until playback gets there.
    final controller = await playing(10);
    List<Object?> seeks() => <Object?>[
      for (final call in harness.calls)
        if (call.method == 'seekTo')
          (call.arguments as Map<Object?, Object?>)['position'],
    ];
    var position = 600000;
    Future<void> carryOn(int reports) async {
      for (var i = 0; i < reports; i++) {
        position += 250;
        await harness.sendEvent(10, snapshot(position: position));
      }
    }

    await controller.seekTo(const Duration(minutes: 30));
    await carryOn(11);
    expect(seeks(), <Object?>[1800000]);
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));

    await carryOn(1);
    expect(seeks(), <Object?>[1800000, 1800000], reason: 'sent once more');
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));

    await carryOn(12);
    expect(seeks(), hasLength(2), reason: 'never a third time');
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a seek taken when it is sent once more lands like any other', (
    tester,
  ) async {
    final controller = await playing(11);
    var position = 600000;

    await controller.seekTo(const Duration(minutes: 30));
    for (var i = 0; i < 12; i++) {
      position += 250;
      await harness.sendEvent(11, snapshot(position: position));
    }
    // The target reported straight back, then playback from there.
    await harness.sendEvent(11, snapshot(position: 1800000));
    await harness.sendEvent(11, snapshot(position: 1800250));

    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('the time reported straight back is the seek echoed, not '
      'landed: playback carrying on from where it was gets it sent once '
      'more', (tester) async {
    // Every backend reports the time it was just given before libVLC has
    // taken it, and libVLC 3 can still refuse: an HLS stream whose WebVTT
    // track is restarting - at every segment, and as the track is switched
    // on - is "not seekable" for that moment. The refusal flushes and
    // refills all the same, so the time is repeated while it buffers
    // (SkyStream's QoE suite on macOS, 2026-10-13).
    final controller = await playing(12);
    List<Object?> seeks() => <Object?>[
      for (final call in harness.calls)
        if (call.method == 'seekTo')
          (call.arguments as Map<Object?, Object?>)['position'],
    ];

    await controller.seekTo(const Duration(minutes: 30));
    await harness.sendEvent(12, snapshot(position: 1800000));
    await harness.sendEvent(
      12,
      snapshot(state: 'buffering', position: 1800000),
    );
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));

    var position = 600000;
    for (var i = 0; i < 12; i++) {
      position += 250;
      await harness.sendEvent(12, snapshot(position: position));
    }
    expect(seeks(), <Object?>[1800000, 1800000], reason: 'sent once more');
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));
    controller.dispose();
  });

  testWidgets('a report repeating the last position does not restart the '
      'count: playback carrying on in steps still gets the seek sent once '
      'more', (tester) async {
    // libVLC's time for an HLS stream moves in steps of about a second, and
    // reports in between change something else - the track list, as a WebVTT
    // track restarts at every segment - with the position the same (macOS,
    // 2026-10-13). Each of those restarted the count, so a refused seek was
    // never sent again.
    final controller = await playing(15);
    List<Object?> seeks() => <Object?>[
      for (final call in harness.calls)
        if (call.method == 'seekTo')
          (call.arguments as Map<Object?, Object?>)['position'],
    ];

    await controller.seekTo(const Duration(minutes: 30));
    var position = 600000;
    for (var i = 0; i < 12; i++) {
      position += 250;
      await harness.sendEvent(15, snapshot(position: position));
      await harness.sendEvent(
        15,
        snapshot(position: position)..['trackRevision'] = i + 1,
      );
    }

    expect(seeks(), <Object?>[1800000, 1800000], reason: 'sent once more');
    controller.dispose();
  });

  testWidgets('a seek libVLC says it refused is sent again at once', (
    tester,
  ) async {
    // libVLC 3 refuses a seek while an adaptive stream's track restarts and
    // says so only in its log ("INPUT_CONTROL_SET_TIME ... failed or not
    // possible"); the backends that read the log count those lines.
    final controller = await playing(16);
    List<Object?> seeks() => <Object?>[
      for (final call in harness.calls)
        if (call.method == 'seekTo')
          (call.arguments as Map<Object?, Object?>)['position'],
    ];

    await controller.seekTo(const Duration(minutes: 30));
    await harness.sendEvent(
      16,
      snapshot(position: 600250)
        ..['seekRefusals'] = 1
        ..['seekRefusedAt'] = 1800000,
    );

    expect(seeks(), <Object?>[1800000, 1800000]);
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));
    controller.dispose();
  });

  testWidgets('a refusal that comes while the engine echoes the target keeps '
      'the seek on its way', (tester) async {
    // VLCKit reports the time it was just given until libVLC's own next
    // report, and libVLC's refusal comes inside that. Taking that echo for
    // where the re-send left from made the re-send's own echo a landing: a
    // resume at 3 min that libVLC refused twice played from the start
    // (SkyStream's QoE suite on macOS, 2026-10-14).
    final controller = await playing(19);
    List<Object?> seeks() => <Object?>[
      for (final call in harness.calls)
        if (call.method == 'seekTo')
          (call.arguments as Map<Object?, Object?>)['position'],
    ];

    await controller.seekTo(const Duration(minutes: 30));
    await harness.sendEvent(19, snapshot(position: 1800000));
    await harness.sendEvent(
      19,
      snapshot(state: 'buffering', position: 1800000)
        ..['seekRefusals'] = 1
        ..['seekRefusedAt'] = 1800000,
    );
    expect(seeks(), <Object?>[1800000, 1800000]);
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));

    // The re-send's echo, and libVLC refusing that one too.
    await harness.sendEvent(
      19,
      snapshot(state: 'buffering', position: 1800000),
    );
    await harness.sendEvent(
      19,
      snapshot(state: 'buffering', position: 1800000)
        ..['seekRefusals'] = 2
        ..['seekRefusedAt'] = 1800000,
    );
    expect(seeks(), <Object?>[1800000, 1800000, 1800000]);
    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));

    // Taken at last: the engine reports from past the target.
    await harness.sendEvent(19, snapshot(position: 1800750));
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a refusal counted before, of another time, or with no seek on '
      'its way sends nothing', (tester) async {
    final controller = await playing(17);
    List<Object?> seeks() => <Object?>[
      for (final call in harness.calls)
        if (call.method == 'seekTo')
          (call.arguments as Map<Object?, Object?>)['position'],
    ];

    // No seek on its way.
    await harness.sendEvent(
      17,
      snapshot(position: 600250)
        ..['seekRefusals'] = 1
        ..['seekRefusedAt'] = 1800000,
    );
    expect(seeks(), isEmpty);

    await controller.seekTo(const Duration(minutes: 30));
    // The same count again: that refusal was already seen.
    await harness.sendEvent(
      17,
      snapshot(position: 600500)
        ..['seekRefusals'] = 1
        ..['seekRefusedAt'] = 1800000,
    );
    // A new refusal, of a time this seek didn't send.
    await harness.sendEvent(
      17,
      snapshot(position: 600750)
        ..['seekRefusals'] = 2
        ..['seekRefusedAt'] = 1200000,
    );
    expect(seeks(), <Object?>[1800000]);
    controller.dispose();
  });

  testWidgets('a seek refused again and again is sent at most three more '
      'times', (tester) async {
    final controller = await playing(18);
    List<Object?> seeks() => <Object?>[
      for (final call in harness.calls)
        if (call.method == 'seekTo')
          (call.arguments as Map<Object?, Object?>)['position'],
    ];

    await controller.seekTo(const Duration(minutes: 30));
    for (var refusals = 1; refusals <= 5; refusals++) {
      await harness.sendEvent(
        18,
        snapshot(position: 600000 + refusals * 250)
          ..['seekRefusals'] = refusals
          ..['seekRefusedAt'] = 1800000,
      );
    }

    expect(seeks(), hasLength(4));
    controller.dispose();
  });

  testWidgets('a report from before the seek, arriving after it, does not '
      'make the echo a landing', (tester) async {
    final controller = await playing(13);

    await controller.seekTo(const Duration(minutes: 30));
    await harness.sendEvent(13, snapshot(position: 600250));
    await harness.sendEvent(13, snapshot(position: 1800000));

    expect(controller.pendingSeekTarget.value, const Duration(minutes: 30));
    controller.dispose();
  });

  testWidgets('an echoed seek lands on the engine\'s next report from near '
      'the target', (tester) async {
    final controller = await playing(14);

    await controller.seekTo(const Duration(minutes: 30));
    await harness.sendEvent(14, snapshot(position: 1800000));
    await harness.sendEvent(14, snapshot(position: 1800250));

    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  group('a seek in a live window', () {
    /// Live HLS 4,000 s into the stream's own timeline, [fraction] of the way
    /// through a two-minute window.
    Map<String, Object?> live({
      required int position,
      required double fraction,
    }) => <String, Object?>{
      'state': 'playing',
      'position': position,
      'duration': 120000,
      'isReady': true,
      'isSeekable': true,
      'positionFraction': fraction,
    };

    List<double> fractionsSent() => <double>[
      for (final call in harness.calls)
        if (call.method == 'seekToFraction')
          (call.arguments as Map<Object?, Object?>)['fraction']! as double,
    ];

    testWidgets('goes to the engine as a fraction, and is watched as the '
        'position it means', (tester) async {
      final controller = VlcPlayerController();
      harness.mockEventChannel(20);
      await harness.attachController(controller, 20);
      await harness.sendEvent(20, live(position: 4000000, fraction: 0.9));

      await controller.seekToWindowFraction(0.65);

      expect(fractionsSent().single, closeTo(0.65, 1e-9));
      expect(harness.calls.where((call) => call.method == 'seekTo'), isEmpty);
      // A quarter of the window back: 30 s.
      expect(controller.pendingSeekTarget.value, ms(3970000));

      await harness.sendEvent(20, live(position: 3970400, fraction: 0.653));
      expect(controller.pendingSeekTarget.value, isNull, reason: 'landed');
      controller.dispose();
    });

    testWidgets('the time libVLC reports as 0 while it seeks in the window '
        'is not a landing', (tester) async {
      // An adaptive stream's time reads 0 for half a second or so after a
      // seek while libVLC finds it again (SkyStream's harness, 2026-10-13),
      // and 0 is far past a step back's target in the step's direction.
      final controller = VlcPlayerController();
      harness.mockEventChannel(24);
      await harness.attachController(controller, 24);
      await harness.sendEvent(24, live(position: 4000000, fraction: 0.9));

      await controller.seekToWindowFraction(0.65);
      await harness.sendEvent(24, live(position: 0, fraction: 0));
      expect(controller.pendingSeekTarget.value, ms(3970000));

      await harness.sendEvent(24, live(position: 3970400, fraction: 0.653));
      expect(controller.pendingSeekTarget.value, isNull, reason: 'landed');
      controller.dispose();
    });

    testWidgets('a burst is merged, and sent as the fraction it ends at', (
      tester,
    ) async {
      final controller = VlcPlayerController();
      harness.mockEventChannel(21);
      await harness.attachController(controller, 21);
      await harness.sendEvent(21, live(position: 4000000, fraction: 0.9));

      await controller.seekToWindowFraction(0.8);
      await controller.seekToWindowFraction(0.7);
      await controller.seekToWindowFraction(0.6);
      await tester.pump(VlcPlayerController.seekMergeWindow);

      expect(fractionsSent(), hasLength(2));
      expect(fractionsSent().first, closeTo(0.8, 1e-9));
      expect(fractionsSent().last, closeTo(0.6, 1e-9));
      controller.dispose();
    });

    testWidgets('needs a window, and a fraction inside it', (tester) async {
      final controller = await playing(22);

      expect(() => controller.seekToWindowFraction(0.5), throwsStateError);
      expect(() => controller.seekToWindowFraction(1.5), throwsArgumentError);
      controller.dispose();
    });
  });

  group('a live HLS window, which libVLC counts from where it was joined', () {
    // libVLC 3.0.24 keeps a live HLS stream's time counted from the join but
    // measures its window from the start of the playlist it last read, so
    // its fraction is the time over the window's length: right as the
    // stream is joined, then running ahead of the window as it moves on, and
    // 0 once past 1. set_position does land in the window as it is now
    // (SkyStream's harness, 2026-10-13).
    Map<String, Object?> hls({required int position, required double raw}) =>
        <String, Object?>{
          'state': 'playing',
          'position': position,
          'duration': 24000,
          'isReady': true,
          'isSeekable': true,
          'positionFraction': raw,
        };

    List<double> fractionsSent() => <double>[
      for (final call in harness.calls)
        if (call.method == 'seekToFraction')
          (call.arguments as Map<Object?, Object?>)['fraction']! as double,
    ];

    Future<VlcPlayerController> joined(int viewId, {bool isLive = true}) async {
      final controller = VlcPlayerController();
      harness.mockEventChannel(viewId);
      await harness.attachController(controller, viewId);
      await controller.setMedia(
        VlcMediaSource(
          uri: Uri.parse('https://example.com/live/index.m3u8'),
          isLive: isLive,
        ),
      );
      return controller;
    }

    testWidgets('its place moves with the window, not with libVLC\'s count '
        'from the join', (tester) async {
      final controller = await joined(30);

      await tester.pump(const Duration(seconds: 1));
      await harness.sendEvent(30, hls(position: 13000, raw: 13000 / 24000));
      // The window has moved on a second since the join.
      expect(controller.value.positionFraction, closeTo(0.5, 1e-3));

      await tester.pump(const Duration(seconds: 10));
      await harness.sendEvent(30, hls(position: 23000, raw: 23000 / 24000));
      expect(controller.value.positionFraction, closeTo(0.5, 1e-3));

      // Past the window's length libVLC says 0.
      await tester.pump(const Duration(seconds: 5));
      await harness.sendEvent(30, hls(position: 28000, raw: 0));
      expect(controller.value.positionFraction, closeTo(0.5, 1e-3));
      controller.dispose();
    });

    testWidgets('a window still filling up keeps its start: only its end '
        'moves on', (tester) async {
      // A live playlist that hasn't reached its full length yet - or an event
      // playlist - grows at its end and keeps its first segment, so libVLC's
      // window doesn't move; the edge still runs on with the clock.
      final controller = await joined(35);
      Map<String, Object?> filling(int position, int window) =>
          <String, Object?>{
            ...hls(position: position, raw: position / window),
            'duration': window,
          };

      await tester.pump(const Duration(seconds: 1));
      await harness.sendEvent(35, filling(52000, 60000));
      // 9 s behind an edge a second past the 60 s listed at the join.
      expect(controller.value.positionFraction, closeTo(51 / 60, 1e-3));

      await tester.pump(const Duration(seconds: 10));
      await harness.sendEvent(35, filling(62000, 70000));
      // Still 9 s behind, in a window of 70 s that starts 1 s in.
      expect(controller.value.positionFraction, closeTo(61 / 70, 1e-3));
      controller.dispose();
    });

    testWidgets('a seek in it goes from that place', (tester) async {
      final controller = await joined(31);
      await tester.pump(const Duration(seconds: 11));
      await harness.sendEvent(31, hls(position: 23000, raw: 23000 / 24000));

      await controller.seekToWindowFraction(0.25);

      expect(fractionsSent().single, closeTo(0.25, 1e-9));
      // A quarter of the window back from the middle: 6 s.
      expect(controller.pendingSeekTarget.value, ms(17000));
      controller.dispose();
    });

    testWidgets('new media is joined afresh', (tester) async {
      final controller = await joined(32);
      await tester.pump(const Duration(seconds: 20));
      await controller.setMedia(
        VlcMediaSource(
          uri: Uri.parse('https://example.com/live/index.m3u8'),
          isLive: true,
        ),
      );

      await tester.pump(const Duration(seconds: 1));
      await harness.sendEvent(32, hls(position: 13000, raw: 13000 / 24000));
      expect(controller.value.positionFraction, closeTo(0.5, 1e-3));
      controller.dispose();
    });

    testWidgets('a window counted in its own timeline is taken as libVLC '
        'says it', (tester) async {
      // DASH's segments carry their own times, so the fraction is not the
      // time over the window's length, and nothing needs working out.
      final controller = await joined(33);
      await tester.pump(const Duration(seconds: 30));
      await harness.sendEvent(33, <String, Object?>{
        ...hls(position: 4000000, raw: 0.9),
        'duration': 120000,
      });
      expect(controller.value.positionFraction, 0.9);
      controller.dispose();
    });

    testWidgets('media not said to be live keeps libVLC\'s place', (
      tester,
    ) async {
      final controller = await joined(34, isLive: false);
      await tester.pump(const Duration(seconds: 11));
      await harness.sendEvent(34, hls(position: 23000, raw: 23000 / 24000));
      expect(controller.value.positionFraction, closeTo(23000 / 24000, 1e-9));
      controller.dispose();
    });
  });
}
