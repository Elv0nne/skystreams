import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// Background policy belongs to the controller, not to a screen.
///
/// The bug this file holds shut: on Android, pressing Home left libVLC
/// decoding and playing audio with nothing on screen and no notification to
/// stop it with, because the only lifecycle observer in the app was the player
/// screen and it never paused. The other half is the mirror-image bug the old
/// player got right — resuming something the viewer had paused themselves.
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
    debugDefaultTargetPlatformOverride = null;
  });

  /// An attached controller reporting playback, which is the only state in
  /// which the policy has anything to do.
  Future<VlcPlayerController> playing({
    VlcBackgroundPolicy? policy,
    bool isPlaying = true,
  }) async {
    final controller = VlcPlayerController(
      config: VlcPlayerConfig(backgroundPolicy: policy),
    );
    harness.mockEventChannel(1);
    await harness.attachController(controller, 1);
    await harness.sendEvent(1, <String, Object?>{
      'state': isPlaying ? 'playing' : 'paused',
      'position': 30000,
      'duration': 3600000,
      'isReady': true,
    });
    harness.calls.clear();
    return controller;
  }

  List<String> methodsOn(VlcMethodChannelHarness harness) =>
      harness.calls.map((call) => call.method).toList();

  group('platform default', () {
    test('mobile pauses, desktop keeps playing', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          const VlcPlayerConfig().effectiveBackgroundPolicy,
          VlcBackgroundPolicy.pause,
          reason: '$platform',
        );
      }
      for (final platform in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(
          const VlcPlayerConfig().effectiveBackgroundPolicy,
          VlcBackgroundPolicy.keepPlaying,
          reason: '$platform',
        );
      }
    });

    test('an explicit policy overrules the platform', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final controller = VlcPlayerController(
        config: const VlcPlayerConfig(
          backgroundPolicy: VlcBackgroundPolicy.pause,
        ),
      );
      addTearDown(controller.dispose);
      expect(controller.backgroundPolicy, VlcBackgroundPolicy.pause);
    });

    test('the policy is not a libVLC option', () {
      expect(
        const VlcPlayerConfig(
          backgroundPolicy: VlcBackgroundPolicy.pause,
        ).toOptions(),
        const VlcPlayerConfig().toOptions(),
      );
    });
  });

  group('pause policy', () {
    test('pauses on the way out and resumes on the way back', () async {
      final controller = await playing(policy: VlcBackgroundPolicy.pause);
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      expect(methodsOn(harness), <String>['pause']);

      harness.calls.clear();
      await setAppLifecycleState(AppLifecycleState.resumed);
      expect(methodsOn(harness), <String>['play']);
    });

    test('losing focus is not leaving the foreground', () async {
      // Entering picture-in-picture on Android is exactly this: the activity
      // pauses, the window stays on screen, and the video must keep playing.
      final controller = await playing(policy: VlcBackgroundPolicy.pause);
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.inactive);
      expect(methodsOn(harness), isEmpty);
    });

    test('pauses once across the whole hidden-then-paused sequence', () async {
      final controller = await playing(policy: VlcBackgroundPolicy.pause);
      addTearDown(controller.dispose);

      // Android emits inactive, hidden and paused in turn on the way to Home.
      await setAppLifecycleState(AppLifecycleState.paused);
      expect(methodsOn(harness).where((m) => m == 'pause'), hasLength(1));
    });

    test('never resumes a player the viewer paused themselves', () async {
      final controller = await playing(
        policy: VlcBackgroundPolicy.pause,
        isPlaying: false,
      );
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      await setAppLifecycleState(AppLifecycleState.resumed);
      expect(methodsOn(harness), isEmpty);
    });

    test('a deliberate play while hidden cancels the resume', () async {
      // The seam the media session and the notification will call through.
      final controller = await playing(policy: VlcBackgroundPolicy.pause);
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      await controller.play();
      harness.calls.clear();

      await setAppLifecycleState(AppLifecycleState.resumed);
      expect(methodsOn(harness), isEmpty);
    });

    test('a deliberate pause while hidden survives the return', () async {
      final controller = await playing(policy: VlcBackgroundPolicy.pause);
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      await controller.pause();
      harness.calls.clear();

      await setAppLifecycleState(AppLifecycleState.resumed);
      expect(methodsOn(harness), isEmpty);
    });

    test('a detached controller is left alone', () async {
      final controller = await playing(policy: VlcBackgroundPolicy.pause);
      addTearDown(controller.dispose);
      await harness.detachController(controller);
      harness.calls.clear();

      await setAppLifecycleState(AppLifecycleState.paused);
      await setAppLifecycleState(AppLifecycleState.resumed);
      expect(methodsOn(harness), isEmpty);
    });
  });

  group('keepPlaying policy', () {
    test('desktop backgrounding touches nothing', () async {
      // The regression guard for cmd-tab: desktop lifecycle is verified-good
      // today and this item must not have cost it.
      final controller = await playing(policy: VlcBackgroundPolicy.keepPlaying);
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      await setAppLifecycleState(AppLifecycleState.resumed);
      expect(methodsOn(harness), isEmpty);
    });
  });

  group('a video not playing yet when the app leaves', () {
    // libVLC 3.0.24 stops an input that can't pause yet
    // (libvlc_media_player_set_pause, lib/media_player.c), so the pause waits
    // for the first `playing` (FORK.md 35).
    Map<String, Object?> state(String name, {int position = 0}) =>
        <String, Object?>{
          'state': name,
          'position': position,
          'duration': 3600000,
          'isReady': name == 'playing',
        };

    Future<VlcPlayerController> opening({
      VlcBackgroundPolicy policy = VlcBackgroundPolicy.pause,
    }) async {
      final controller = VlcPlayerController(
        config: VlcPlayerConfig(backgroundPolicy: policy),
      );
      harness.mockEventChannel(1);
      await harness.attachController(controller, 1);
      await harness.sendEvent(1, state('opening'));
      harness.calls.clear();
      return controller;
    }

    test('is paused once it plays, and resumed on the way back', () async {
      final controller = await opening();
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      expect(methodsOn(harness), isEmpty);

      await harness.sendEvent(1, state('playing', position: 400));
      expect(methodsOn(harness), <String>['pause']);
      expect(controller.pauseRequests, 1, reason: 'a pause that was asked for');

      harness.calls.clear();
      await setAppLifecycleState(AppLifecycleState.resumed);
      expect(methodsOn(harness), <String>['play']);
    });

    test('one the engine still calls idle just after its play is paused once '
        'it plays', () async {
      // Windows' and Linux's core report idle for a moment after a play, until
      // libVLC opens the input: leaving then kept no claim, and the video
      // played on in the background (P1 Part 4's Windows run).
      final controller = VlcPlayerController(
        config: const VlcPlayerConfig(
          backgroundPolicy: VlcBackgroundPolicy.pause,
        ),
      );
      addTearDown(controller.dispose);
      harness.mockEventChannel(1);
      await harness.attachController(controller, 1);
      await controller.setMedia(
        VlcMediaSource(uri: Uri.parse('https://example.com/film.mp4')),
        autoPlay: true,
      );
      await harness.sendEvent(1, state('idle'));
      harness.calls.clear();

      await setAppLifecycleState(AppLifecycleState.paused);
      expect(methodsOn(harness), isEmpty);

      await harness.sendEvent(1, state('playing', position: 400));
      expect(methodsOn(harness), <String>['pause']);
    });

    test('an idle media nobody asked to play keeps no claim', () async {
      final controller = VlcPlayerController(
        config: const VlcPlayerConfig(
          backgroundPolicy: VlcBackgroundPolicy.pause,
        ),
      );
      addTearDown(controller.dispose);
      harness.mockEventChannel(1);
      await harness.attachController(controller, 1);
      await controller.setMedia(
        VlcMediaSource(uri: Uri.parse('https://example.com/film.mp4')),
      );
      await harness.sendEvent(1, state('idle'));
      harness.calls.clear();

      await setAppLifecycleState(AppLifecycleState.paused);
      await harness.sendEvent(1, state('playing', position: 400));
      expect(methodsOn(harness), isEmpty);
    });

    test('a rebuffer after a seek is paused once it plays again', () async {
      final controller = await playing(policy: VlcBackgroundPolicy.pause);
      addTearDown(controller.dispose);
      await harness.sendEvent(1, state('buffering', position: 30000));
      harness.calls.clear();

      await setAppLifecycleState(AppLifecycleState.paused);
      expect(methodsOn(harness), isEmpty);

      await harness.sendEvent(1, state('playing', position: 31000));
      expect(methodsOn(harness), <String>['pause']);
    });

    test('coming back before it plays pauses nothing', () async {
      final controller = await opening();
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      await setAppLifecycleState(AppLifecycleState.resumed);
      await harness.sendEvent(1, state('playing', position: 400));
      expect(methodsOn(harness), isEmpty);
    });

    test('a play while away is not paused', () async {
      final controller = await opening();
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      await controller.play();
      harness.calls.clear();
      await harness.sendEvent(1, state('playing', position: 400));
      expect(methodsOn(harness), isEmpty);
    });

    test('keepPlaying leaves it alone', () async {
      final controller = await opening(policy: VlcBackgroundPolicy.keepPlaying);
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      await harness.sendEvent(1, state('playing', position: 400));
      expect(methodsOn(harness), isEmpty);
    });
  });
}
