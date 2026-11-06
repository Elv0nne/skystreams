import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// [VlcPlayerController.pauseRequests]: every pause and stop asked of the
/// controller, or made by its own background policy.
///
/// A recovery has to tell a stop it, the viewer or the policy asked for from
/// one the engine made after a failure it never reported as one (SkyStream's
/// P1 Part 3). The engine's own snapshots say only `paused` or `stopped`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VlcMethodChannelHarness harness;

  setUp(() {
    harness = VlcMethodChannelHarness()..install();
  });

  tearDown(() async {
    // Leave the binding where every test expects to find it, or the next one
    // inherits a hidden app and AppLifecycleListener asserts on the sequence.
    await setAppLifecycleState(AppLifecycleState.resumed);
    harness.dispose();
  });

  final film = VlcMediaSource(uri: Uri.parse('https://example.com/film.mp4'));

  /// An attached controller reporting playback.
  Future<VlcPlayerController> playing(
    int viewId, {
    VlcBackgroundPolicy? policy,
  }) async {
    final controller = VlcPlayerController(
      config: VlcPlayerConfig(backgroundPolicy: policy),
    );
    harness.mockEventChannel(viewId);
    await harness.attachController(controller, viewId);
    await harness.sendEvent(viewId, <String, Object?>{
      'state': 'playing',
      'position': 30000,
      'duration': 3600000,
      'isReady': true,
    });
    harness.calls.clear();
    return controller;
  }

  test('starts at 0, and counts pause() and stop() but not play()', () async {
    final controller = await playing(71);
    addTearDown(controller.dispose);
    expect(controller.pauseRequests, 0);

    await controller.pause();
    await controller.play();
    await controller.stop();

    expect(controller.pauseRequests, 2);
  });

  test('a stop before any player counts', () async {
    final controller = VlcPlayerController(mediaSource: film, autoPlay: true);
    addTearDown(controller.dispose);

    await controller.stop();

    expect(controller.pauseRequests, 1);
  });

  test('a playlist\'s own stop counts', () async {
    final controller = await playing(72);
    addTearDown(controller.dispose);
    await controller.setPlaylist(<VlcMediaSource>[film]);

    await controller.clearPlaylist();

    expect(harness.calls.map((call) => call.method), contains('stop'));
    expect(controller.pauseRequests, 1);
  });

  test('the background policy\'s pause counts, once', () async {
    final controller = await playing(73, policy: VlcBackgroundPolicy.pause);
    addTearDown(controller.dispose);

    // Hidden, then paused: the policy pauses at the first and not again.
    await setAppLifecycleState(AppLifecycleState.paused);

    expect(harness.calls.map((call) => call.method), <String>['pause']);
    expect(controller.pauseRequests, 1);
  });

  test('an open turned stopped by the background policy counts', () async {
    final controller = await playing(74, policy: VlcBackgroundPolicy.pause);
    addTearDown(controller.dispose);
    // Paused by the engine, so going away has nothing to pause.
    await harness.sendEvent(74, <String, Object?>{'state': 'paused'});
    await setAppLifecycleState(AppLifecycleState.paused);
    expect(controller.pauseRequests, 0);

    await controller.setMedia(film, autoPlay: true);

    final setSource = harness.calls.singleWhere(
      (call) => call.method == 'setSource',
    );
    expect(setSource.arguments['autoPlay'], isFalse);
    expect(controller.pauseRequests, 1);
  });

  test('the engine\'s own pause or stop does not count', () async {
    final controller = await playing(75);
    addTearDown(controller.dispose);

    await harness.sendEvent(75, <String, Object?>{'state': 'paused'});
    await harness.sendEvent(75, <String, Object?>{'state': 'stopped'});

    expect(controller.pauseRequests, 0);
  });
}
