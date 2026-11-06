import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

/// A video opened while the plugin still builds libVLC's font database waits
/// for that build instead of starting a second one alongside it (Android).
///
/// The two scans slowed each other: the first picture of a fresh install took
/// 32 s on the phone emulator, past the player screen's 30 s first-frame
/// deadline, whose reopen then stranded the first player inside its scan
/// (SkyStream's QoE suite, 2026-10-14). The build alone takes 12-13 s there.
/// `flutter test` installs the app afresh, so the build is running when this
/// test opens its video.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a video opened during the warm-up waits for it', (tester) async {
    final controller = VlcPlayerController(options: headlessPlayerOptions());
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
    final clock = Stopwatch()..start();
    await controller.setMedia(
      VlcMediaSource(
        uri: await materializeAsset('assets/format_fixtures/video.mp4'),
      ),
      autoPlay: true,
    );
    await pumpUntil(
      tester,
      () => controller.value.videoSize != null,
      description: 'the first picture',
      attempts: 240,
    );
    clock.stop();
    debugPrint(
      'font_warmup_gate: first picture ${clock.elapsedMilliseconds} ms',
    );
    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 25)),
      reason: 'the video built its own font database alongside the warm-up',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, skip: !Platform.isAndroid);
}
