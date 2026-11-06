import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

const String _assetRoot = 'assets/format_fixtures';

/// The shape a host turns the device by has to reach Dart for every
/// container, not only the ones that declare it up front.
///
/// MP4 and MKV carry width and height in the container header, so their video
/// track is sized from the moment it exists. MPEG-TS does not - and neither
/// does HLS, which is TS segments behind a playlist: the size is only known
/// once the decoder has parsed the stream. A backend that samples the track
/// before then, and never again, reports no shape at all for the second group.
///
/// Every fixture is a 160x90 picture, so the only honest answer is landscape.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final cases = <(String, Future<Uri> Function())>[
    ('MP4', () => materializeAsset('$_assetRoot/video.mp4')),
    ('MKV', () => materializeAsset('$_assetRoot/video.mkv')),
    ('MPEG-TS', () => materializeAsset('$_assetRoot/video.ts')),
    (
      'HLS',
      () => materializeHlsFixture(
        playlistAssetPath: '$_assetRoot/hls/playlist.m3u8',
        segmentAssetPath: '$_assetRoot/hls/segment.ts',
      ),
    ),
  ];

  group('display video size', () {
    for (final (name, source) in cases) {
      testWidgets('reaches Dart for $name', (WidgetTester tester) async {
        final controller = VlcPlayerController(
          options: headlessPlayerOptions(),
        );
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 240,
                  height: 135,
                  child: VlcPlayer(controller: controller),
                ),
              ),
            ),
          ),
        );
        await pumpUntil(
          tester,
          () => controller.isAttached,
          description: 'native player attachment for $name',
        );

        await controller.setMedia(
          VlcMediaSource(uri: await source()),
          autoPlay: true,
        );

        for (
          var attempt = 0;
          attempt < 40 &&
              controller.value.displayVideoSize == null &&
              !controller.value.hasError;
          attempt += 1
        ) {
          await tester.pump(const Duration(milliseconds: 250));
        }

        final value = controller.value;
        final info = await controller.getMediaInfo();
        debugPrint(
          '$name: state=${value.state} videoSize=${value.videoSize} '
          'orientation=${value.videoOrientation} '
          'display=${value.displayVideoSize} tracks='
          '${info.videoTracks.map((t) => '${t.width}x${t.height}').toList()}',
        );

        expect(value.hasError, isFalse, reason: '$name: ${value.error}');
        final shape = value.displayVideoSize;
        expect(shape, isNotNull, reason: '$name reported no display shape.');
        expect(
          shape!.width > shape.height,
          isTrue,
          reason: '$name is 160x90 but reported $shape.',
        );

        await controller.stop();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle(const Duration(milliseconds: 50));
      });
    }
  });
}
