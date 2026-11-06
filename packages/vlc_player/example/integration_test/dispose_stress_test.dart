import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

const String _assetRoot = 'assets/format_fixtures';

/// How many times the players are changed to another size and then left.
const int _rounds = int.fromEnvironment(
  'DISPOSE_STRESS_ROUNDS',
  defaultValue: 200,
);

/// The players changed and left together in each round. Each one's video
/// output may be copying a picture at the leave, with odds of its own.
const int _players = 3;

/// Changing texture players to another size, and leaving them, while their
/// video outputs copy pictures, must never crash or freeze the app.
///
/// libVLC 3's vmem copies each picture into the planes its lock returned, and
/// only then unlocks (vmem.c's Prepare). On iOS and macOS a player per source
/// puts two players' outputs on one renderer: the next player's output
/// configures it, and dispose() detaches the renderer while the old output may
/// still be copying. The renderer used to free that picture there, and the
/// copy crashed the app (FORK.md 31). A 2160p picture at 60 fps keeps a copy
/// in progress about 3 % of the time.
///
/// The players are laid out but never painted: a picture Flutter has drawn
/// stays mapped through its Metal texture after the renderer lets it go, which
/// hid the crash in most of the leaves that came during a copy.
///
/// Three players retire together at every change and every leave. On macOS
/// each one's close saved libVLC's configuration while another's audio output
/// wrote it, and the two deadlocked, freezing the app (FORK.md 32).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('changing size and leaving during playback never crash', (
    tester,
  ) async {
    final big = await materializeAsset('$_assetRoot/stress_2160p60.mp4');
    final small = await materializeAsset('$_assetRoot/stress_1080p30.mp4');
    final random = Random(31);
    final clock = Stopwatch()..start();
    for (var round = 1; round <= _rounds; round += 1) {
      final controllers = <VlcPlayerController>[
        for (var player = 0; player < _players; player += 1)
          VlcPlayerController(options: headlessPlayerOptions()),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Offstage(
              child: Stack(
                children: <Widget>[
                  for (final controller in controllers)
                    SizedBox(
                      width: 320,
                      height: 180,
                      child: VlcPlayer(controller: controller),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await pumpUntil(
        tester,
        () => controllers.every((controller) => controller.isAttached),
        description: 'native player attachment',
        attempts: 160,
      );
      // Another size first: the change to the big picture puts two players'
      // outputs on each renderer.
      for (final controller in controllers) {
        await controller.setMedia(VlcMediaSource(uri: small), autoPlay: true);
      }
      await _playingAt(tester, controllers, wide: false, round: round);
      await tester.pump(Duration(milliseconds: random.nextInt(250)));
      for (final controller in controllers) {
        await controller.setMedia(VlcMediaSource(uri: big), autoPlay: true);
      }
      await _playingAt(tester, controllers, wide: true, round: round);
      // The leave lands anywhere in a picture's 16.7 ms.
      await tester.pump(Duration(milliseconds: 50 + random.nextInt(450)));
      // What pressing back does: the widgets go, which disposes the native
      // players, and the owner disposes the controllers.
      await tester.pumpWidget(const SizedBox.shrink());
      for (final controller in controllers) {
        controller.dispose();
      }
      await tester.pump(const Duration(milliseconds: 50));
      // Where a crash or a freeze came, in the log.
      debugPrint('dispose_stress: round $round');
    }
    // For the device matrix's record.
    debugPrint(
      'dispose_stress: $_rounds rounds in '
      '${clock.elapsed.inSeconds} s',
    );
  });
}

/// Until the media now set plays its own pictures in every player: the 2160p
/// one when [wide].
Future<void> _playingAt(
  WidgetTester tester,
  List<VlcPlayerController> controllers, {
  required bool wide,
  required int round,
}) {
  return pumpUntil(
    tester,
    () => controllers.every((controller) {
      final value = controller.value;
      final width = value.videoSize?.width ?? 0;
      return value.state == VlcPlaybackState.playing &&
          value.position >= const Duration(milliseconds: 250) &&
          (wide ? width >= 3000 : width > 0 && width < 3000);
    }),
    description: 'the ${wide ? 2160 : 1080}p media playing in round $round',
    attempts: 80,
  );
}
