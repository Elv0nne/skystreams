import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// Seeks asked for in a burst reach the engine as one.
///
/// libVLC answers every seek by flushing its decoders and - whenever the
/// target is not already in its read-ahead - by dropping that and asking the
/// network for the stream again. It merges queued seeks only while one is
/// still being processed, so six presses of an arrow key, six taps or six
/// bumps of a gamepad shoulder became three full resets, each on a new
/// connection, with a frame from each flashing past.
///
/// The first seek of a burst still goes at once, so a single press costs no
/// delay. Later ones inside the window only move the target, which the
/// scrubber and the clock show straight away; the engine is sent the last of
/// them once the input has been quiet for a window.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VlcMethodChannelHarness harness;

  setUp(() {
    harness = VlcMethodChannelHarness()..install();
  });

  tearDown(() {
    harness.dispose();
  });

  Map<String, Object?> snapshot({String state = 'playing'}) =>
      <String, Object?>{
        'state': state,
        'position': 600000,
        'duration': 3600000,
        'isReady': true,
      };

  Future<VlcPlayerController> playing(int viewId) async {
    final controller = VlcPlayerController();
    harness.mockEventChannel(viewId);
    await harness.attachController(controller, viewId);
    await harness.sendEvent(viewId, snapshot());
    return controller;
  }

  List<int> enginePositions() => <int>[
    for (final MethodCall call in harness.calls)
      if (call.method == 'seekTo') (call.arguments as Map)['position'] as int,
  ];

  Duration ms(int value) => Duration(milliseconds: value);
  final window = VlcPlayerController.seekMergeWindow;

  testWidgets('a seek on its own reaches the engine at once', (tester) async {
    final controller = await playing(1);

    await controller.seekTo(const Duration(minutes: 30));

    expect(enginePositions(), <int>[1800000]);
    controller.dispose();
  });

  testWidgets('a burst reaches the engine as its first and last seek', (
    tester,
  ) async {
    final controller = await playing(2);

    for (var step = 1; step <= 6; step++) {
      unawaited(controller.seekTo(ms(600000 + step * 10000)));
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(enginePositions(), <int>[610000]);
    expect(
      controller.pendingSeekTarget.value,
      ms(660000),
      reason: 'the scrubber and the clock show the whole burst at once',
    );

    await tester.pump(window);
    expect(enginePositions(), <int>[610000, 660000]);
    controller.dispose();
  });

  testWidgets('seeks further apart than the window each go at once', (
    tester,
  ) async {
    final controller = await playing(3);

    await controller.seekTo(ms(610000));
    await tester.pump(window * 2);
    await controller.seekTo(ms(620000));

    expect(enginePositions(), <int>[610000, 620000]);
    await tester.pump(window * 2);
    controller.dispose();
  });

  testWidgets('a merged seek never holds up its caller', (tester) async {
    // Awaited straight after another seek, a merged one would otherwise hang
    // its caller for a whole window - forever, where nothing advances time.
    final controller = await playing(4);

    await controller.seekTo(ms(610000));
    await controller.seekTo(ms(620000));
    await controller.seekTo(ms(630000));
    expect(enginePositions(), <int>[610000]);

    await tester.pump(window);
    expect(enginePositions(), <int>[610000, 630000]);
    controller.dispose();
  });

  testWidgets('a burst that ends where it began sends nothing more', (
    tester,
  ) async {
    // Right, right, left: the engine already has the place the viewer settled
    // on, and a second seek there would flush and refill for nothing.
    final controller = await playing(7);

    await controller.seekTo(ms(610000));
    await controller.seekTo(ms(620000));
    await controller.seekTo(ms(610000));
    await tester.pump(window);

    expect(enginePositions(), <int>[610000]);
    controller.dispose();
  });

  testWidgets('the first seek on new media goes at once', (tester) async {
    // A seek on the media going away is no burst for the one replacing it.
    final controller = await playing(8);

    await controller.seekTo(ms(610000));
    await controller.setMedia(
      VlcMediaSource(uri: Uri.parse('https://example.com/next.mkv')),
    );
    await controller.seekTo(ms(620000));

    expect(enginePositions(), <int>[610000, 620000]);
    controller.dispose();
  });

  testWidgets('new media drops a merged seek that has not gone out', (
    tester,
  ) async {
    final controller = await playing(5);

    await controller.seekTo(ms(610000));
    unawaited(controller.seekTo(ms(620000)));
    await controller.setMedia(
      VlcMediaSource(uri: Uri.parse('https://example.com/next.mkv')),
    );
    await tester.pump(window * 2);

    expect(enginePositions(), <int>[610000]);
    controller.dispose();
  });

  testWidgets('disposing drops it too, and leaves no timer behind', (
    tester,
  ) async {
    final controller = await playing(6);

    await controller.seekTo(ms(610000));
    unawaited(controller.seekTo(ms(620000)));
    controller.dispose();
    await tester.pump(window * 2);

    expect(enginePositions(), <int>[610000]);
  });
}
