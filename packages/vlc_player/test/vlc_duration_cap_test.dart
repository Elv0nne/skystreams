import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// A length the host has measured caps the one libVLC reports.
///
/// libVLC reports an HLS master's length as that of the longest playlist it
/// has loaded, alternative renditions included - and a rendition does not have
/// to be selected to be loaded. A subtitle file wrapped as one segment that
/// claims 99,999 seconds therefore makes a fifty-minute episode read
/// 27:46:39: the seek bar is useless, and the real ending looks like a stream
/// that died short of its length. The host can read the video's own playlist;
/// once it says how long that is, the controller never reports more.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const viewId = 7;
  const inflated = Duration(seconds: 99999);
  late VlcMethodChannelHarness harness;

  setUp(() {
    harness = VlcMethodChannelHarness()..install();
  });

  tearDown(() {
    harness.dispose();
  });

  Map<String, Object?> snapshot({
    required Duration duration,
    int position = 1000,
  }) {
    return <String, Object?>{
      'state': 'playing',
      'position': position,
      'duration': duration.inMilliseconds,
      'isReady': true,
    };
  }

  Future<VlcPlayerController> attached() async {
    final controller = VlcPlayerController();
    addTearDown(controller.dispose);
    harness.mockEventChannel(viewId);
    await harness.attachController(controller, viewId);
    return controller;
  }

  test('reports the measured length instead of a longer one', () async {
    final controller = await attached();
    await harness.sendEvent(viewId, snapshot(duration: inflated));
    expect(controller.value.duration, inflated);

    controller.setDurationCap(const Duration(minutes: 49, seconds: 37));

    // At once: the seek bar should not wait for the next snapshot.
    expect(controller.value.duration, const Duration(minutes: 49, seconds: 37));
    // And from then on, whatever libVLC keeps saying.
    await harness.sendEvent(
      viewId,
      snapshot(duration: inflated, position: 2000),
    );
    expect(controller.value.duration, const Duration(minutes: 49, seconds: 37));
    expect(controller.value.position, const Duration(seconds: 2));
  });

  test('never lengthens a shorter report', () async {
    final controller = await attached();
    controller.setDurationCap(const Duration(minutes: 50));

    await harness.sendEvent(
      viewId,
      snapshot(duration: const Duration(minutes: 49, seconds: 58)),
    );

    expect(controller.value.duration, const Duration(minutes: 49, seconds: 58));
  });

  test('leaves an unknown length unknown', () async {
    final controller = await attached();
    controller.setDurationCap(const Duration(minutes: 50));

    await harness.sendEvent(viewId, snapshot(duration: Duration.zero));

    expect(controller.value.duration, Duration.zero);
  });

  test('belongs to one media', () async {
    final controller = await attached();
    controller.setDurationCap(const Duration(minutes: 50));

    await controller.setMedia(
      VlcMediaSource(uri: Uri.parse('https://example.test/next.m3u8')),
    );
    await harness.sendEvent(viewId, snapshot(duration: inflated));

    expect(controller.value.duration, inflated);
  });

  test('null lifts it from the next report on', () async {
    final controller = await attached();
    controller.setDurationCap(const Duration(minutes: 50));
    await harness.sendEvent(viewId, snapshot(duration: inflated));
    expect(controller.value.duration, const Duration(minutes: 50));

    controller.setDurationCap(null);
    await harness.sendEvent(
      viewId,
      snapshot(duration: inflated, position: 2000),
    );

    expect(controller.value.duration, inflated);
  });
}
