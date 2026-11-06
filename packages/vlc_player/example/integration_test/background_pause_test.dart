import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

/// A video still opening when the app leaves is paused once it plays, by the
/// real backend (FORK.md 35). The pause can't go earlier: libVLC 3 stops an
/// input that can't pause yet.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// Moves the app through [states]. No frame is pumped: an app that is
  /// away draws none, and a pump there waits for ever.
  void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  /// Waits for [condition] on real time, for the same reason.
  Future<void> waitFor(bool Function() condition, String what) async {
    for (var i = 0; i < 240 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!condition()) fail('Timed out waiting for $what after 60 s.');
  }

  testWidgets('a video opening when the app leaves is paused once it plays', (
    tester,
  ) async {
    final controller = VlcPlayerController(
      options: headlessPlayerOptions(),
      config: const VlcPlayerConfig(
        backgroundPolicy: VlcBackgroundPolicy.pause,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 135,
            child: VlcPlayer(controller: controller),
          ),
        ),
      ),
    );
    await pumpUntil(
      tester,
      () => controller.isAttached,
      description: 'native player attachment',
      attempts: 160,
    );
    await controller.setMedia(
      VlcMediaSource(
        uri: await materializeAsset(
          'assets/format_fixtures/video_lifecycle.mp4',
        ),
      ),
      autoPlay: true,
    );
    final stateAtLeave = controller.value.state;
    // Only a video not playing yet asks the pause to wait for its first
    // playing; one already playing is paused at once, as before FORK.md 35.
    // Windows and Linux can still call it idle just after its play, until
    // libVLC opens the input (measured on Windows, P1 Part 4).
    expect(
      stateAtLeave,
      anyOf(
        VlcPlaybackState.opening,
        VlcPlaybackState.buffering,
        VlcPlaybackState.idle,
      ),
      reason: 'the app must leave while the video is still opening',
    );
    lifecycle(tester, const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    await waitFor(
      () => controller.value.state == VlcPlaybackState.paused,
      'paused once it played',
    );
    debugPrint(
      'background_pause: left at $stateAtLeave, '
      'pauseRequests ${controller.pauseRequests}',
    );
    expect(controller.pauseRequests, 1);

    lifecycle(tester, const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    await waitFor(
      () => controller.value.state == VlcPlaybackState.playing,
      'playing again on the way back',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
