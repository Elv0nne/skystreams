import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// A reopen that keeps the picture starts where it was asked to, and
/// [VlcPlayerController.pendingSeekTarget] says so while the held picture
/// stands in for it (FORK.md 33).
///
/// The engine reports 0 until the new media plays from its start, and a
/// scrubber or a clock drawn from that jumped to the film's opening under a
/// picture from minutes in. The start is not a seek: it went to the engine
/// with the media, so nothing sends it again, counts it, or waits for its
/// echo.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VlcMethodChannelHarness harness;

  tearDown(() {
    harness.dispose();
  });

  const at = Duration(minutes: 40);

  VlcMediaSource reopen([Duration start = at]) => VlcMediaSource(
    uri: Uri.parse('https://example.com/film.m3u8'),
    startPosition: start,
  );

  List<String> methods() => harness.calls.map((call) => call.method).toList();

  /// An attached controller playing at 40:00 of an hour-long film, on a
  /// native side whose `setSource` sends the new media's opening snapshot
  /// before it answers. [holds] says whether its output had a picture to
  /// hold.
  Future<VlcPlayerController> playing(int viewId, {bool holds = true}) async {
    harness = VlcMethodChannelHarness()
      ..install(
        onCall: (call) async {
          if (call.method == 'setSource') {
            final arguments = call.arguments as Map<Object?, Object?>;
            await harness.sendEvent(viewId, <String, Object?>{
              'state': 'opening',
              'position': 0,
              'duration': 0,
              'isSeekable': false,
              'pictureHeld': arguments['keepPicture'] == true && holds,
            });
          }
          return null;
        },
      );
    final controller = VlcPlayerController();
    harness.mockEventChannel(viewId);
    await harness.attachController(controller, viewId);
    await harness.sendEvent(viewId, <String, Object?>{
      'state': 'playing',
      'position': 2400000,
      'duration': 3600000,
      'isReady': true,
      'isSeekable': true,
    });
    harness.calls.clear();
    return controller;
  }

  testWidgets('a held reopen\'s start is the target while the picture is '
      'held, and is never sent', (tester) async {
    final controller = await playing(61);

    await controller.setMedia(reopen(), autoPlay: true, keepPicture: true);

    expect(controller.value.isPictureHeld, isTrue);
    expect(controller.value.position, Duration.zero);
    expect(controller.pendingSeekTarget.value, at);
    expect(methods(), <String>['setSource']);
    expect(controller.seekRequests, 0);
    expect(controller.playbackClock.position, at);
    controller.dispose();
  });

  testWidgets('it goes when the hold ends, which is playback from the start', (
    tester,
  ) async {
    final controller = await playing(62);
    await controller.setMedia(reopen(), autoPlay: true, keepPicture: true);

    // Filling its buffer at the start: still held, still 0.
    await harness.sendEvent(62, <String, Object?>{
      'state': 'buffering',
      'position': 0,
      'pictureHeld': true,
    });
    await tester.pump(const Duration(seconds: 10));
    expect(controller.pendingSeekTarget.value, at);

    // libVLC's first time report, in the snapshot that ends the hold: from a
    // keyframe a little before the start.
    await harness.sendEvent(62, <String, Object?>{
      'state': 'playing',
      'position': 2394000,
      'pictureHeld': false,
    });
    expect(controller.pendingSeekTarget.value, isNull);
    expect(controller.value.position, const Duration(milliseconds: 2394000));
    expect(methods(), <String>['setSource']);
    controller.dispose();
  });

  testWidgets('it goes when the held media fails', (tester) async {
    final controller = await playing(63);
    await controller.setMedia(reopen(), autoPlay: true, keepPicture: true);

    // The hold outlives the failure (FORK.md 30); the start cannot land.
    await harness.sendEvent(63, <String, Object?>{
      'state': 'error',
      'pictureHeld': true,
    });

    expect(controller.value.isPictureHeld, isTrue);
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a reopen whose output had nothing to hold has no target', (
    tester,
  ) async {
    final controller = await playing(64, holds: false);

    await controller.setMedia(reopen(), autoPlay: true, keepPicture: true);

    expect(controller.value.isPictureHeld, isFalse);
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a plain setMedia at a position has no target', (tester) async {
    final controller = await playing(65);

    await controller.setMedia(reopen(), autoPlay: true);

    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a held reopen at the start has no target', (tester) async {
    final controller = await playing(66);

    await controller.setMedia(
      reopen(Duration.zero),
      autoPlay: true,
      keepPicture: true,
    );

    expect(controller.value.isPictureHeld, isTrue);
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a seek over the held picture goes from the start, as an '
      'ordinary seek', (tester) async {
    final controller = await playing(67);
    await controller.setMedia(reopen(), autoPlay: true, keepPicture: true);

    // Ten seconds back, before the media plays.
    await controller.seekTo(const Duration(minutes: 39, seconds: 50));
    expect(methods(), <String>['setSource', 'seekTo']);
    expect(harness.calls.last.arguments['position'], 2390000);
    expect(controller.seekRequests, 1);
    expect(
      controller.pendingSeekTarget.value,
      const Duration(minutes: 39, seconds: 50),
    );

    // The media playing from its own start is not this seek landing: a step
    // back from 40:00 has not landed at 40:00. From 0, it would have.
    await harness.sendEvent(67, <String, Object?>{
      'state': 'playing',
      'position': 2400000,
      'pictureHeld': false,
    });
    expect(
      controller.pendingSeekTarget.value,
      const Duration(minutes: 39, seconds: 50),
    );

    await harness.sendEvent(67, <String, Object?>{
      'state': 'playing',
      'position': 2390100,
    });
    expect(controller.pendingSeekTarget.value, isNull);
    controller.dispose();
  });

  testWidgets('a refused seek in libVLC\'s log sends nothing for it', (
    tester,
  ) async {
    final controller = await playing(68);
    await controller.setMedia(reopen(), autoPlay: true, keepPicture: true);

    // libVLC's own start, refused and logged (Darwin, Windows, Linux).
    await harness.sendEvent(68, <String, Object?>{
      'state': 'buffering',
      'position': 0,
      'pictureHeld': true,
      'seekRefusals': 1,
      'seekRefusedAt': 2400000,
    });

    expect(methods(), <String>['setSource']);
    expect(controller.pendingSeekTarget.value, at);
    controller.dispose();
  });

  testWidgets('reports that move while the picture is held never send it '
      'again', (tester) async {
    final controller = await playing(69);
    await controller.setMedia(reopen(), autoPlay: true, keepPicture: true);

    // More moves than the landing check lets a seek go without arriving.
    for (var step = 1; step <= 14; step += 1) {
      await harness.sendEvent(69, <String, Object?>{
        'state': 'buffering',
        'position': step * 250,
        'pictureHeld': true,
      });
    }

    expect(methods(), <String>['setSource']);
    expect(controller.pendingSeekTarget.value, at);
    controller.dispose();
  });
}
