import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

/// libVLC's font database is ready before the first video (Android).
///
/// libVLC's freetype text renderer has fontconfig build its font database the
/// first time a video output is made in a process, on the thread that opens
/// the media, and nothing plays until it is done: a scan of every system font
/// when there is no cache, 11.5 s on the phone emulator for the first video
/// after an install. The plugin builds it in the background when it
/// registers, so by the time someone picks a video the cache is there and the
/// build takes milliseconds. `flutter test` installs the app afresh, so every
/// run starts without a cache.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the font database is built before the first video', (
    tester,
  ) async {
    // libvlc-android's home, beside the cache directory the system temp is.
    final cache = Directory(
      '${Directory.systemTemp.parent.path}/app_vlc/.cache/fontconfig',
    );
    await pumpUntil(
      tester,
      () => _hasCacheFile(cache),
      description: "fontconfig's cache, with no video played",
      attempts: 240,
    );

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
    );
    clock.stop();
    debugPrint('font_warmup: first picture ${clock.elapsedMilliseconds} ms');
    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 5)),
      reason: 'the first video waited on the font database',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  }, skip: !Platform.isAndroid);
}

/// Whether fontconfig wrote a cache file (`<hash>-<arch>.cache-<version>`).
bool _hasCacheFile(Directory cache) =>
    cache.existsSync() &&
    cache.listSync().any(
      (entity) => entity is File && entity.path.contains('.cache-'),
    );
