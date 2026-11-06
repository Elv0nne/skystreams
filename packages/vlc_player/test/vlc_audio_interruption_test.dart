import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// Audio focus and interruptions, as far as Dart can see them.
///
/// The native halves cannot be exercised from a Flutter unit test: there is no
/// AudioManager, no becoming-noisy broadcast and no AVAudioSession in the Dart
/// VM, so requesting and losing real focus is out of reach here and is verified
/// on device instead. What is testable — and what this file holds shut — is the
/// contract between those natives and the controller. The engine is already
/// paused by the time the event lands, so the only question left is who owns
/// the resume, and the answer must never be laundered into a user intent: an
/// interruption that cleared `_pausedForBackground` would resurrect the
/// double-resume bug the background policy work just closed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VlcMethodChannelHarness harness;

  setUp(() {
    harness = VlcMethodChannelHarness()..install();
  });

  tearDown(() async {
    await setAppLifecycleState(AppLifecycleState.resumed);
    harness.dispose();
  });

  /// An attached controller reporting playback, which is the only state an
  /// interruption can arrive in.
  Future<VlcPlayerController> playing({
    VlcBackgroundPolicy policy = VlcBackgroundPolicy.pause,
    Duration? eventThrottleInterval,
  }) async {
    final controller = VlcPlayerController(
      config: VlcPlayerConfig(backgroundPolicy: policy),
      eventThrottleInterval: eventThrottleInterval,
    );
    harness.mockEventChannel(1);
    await harness.attachController(controller, 1);
    await harness.sendEvent(1, <String, Object?>{
      'state': 'playing',
      'position': 30000,
      'duration': 3600000,
      'isReady': true,
      'interruption': 'none',
    });
    harness.calls.clear();
    return controller;
  }

  /// The event a native audio-focus handler sends after it has acted.
  Future<void> interrupt(String interruption, {String state = 'paused'}) async {
    await harness.sendEvent(1, <String, Object?>{
      'state': state,
      'position': 30000,
      'interruption': interruption,
    });
    await pumpEventQueue();
  }

  List<String> methodsOn(VlcMethodChannelHarness harness) =>
      harness.calls.map((call) => call.method).toList();

  group('value', () {
    test('reads every interruption the natives can report', () {
      const previous = VlcPlayerValue();
      for (final interruption in VlcAudioInterruption.values) {
        expect(
          VlcPlayerValue.fromEvent(<String, Object?>{
            'interruption': interruption.name,
          }, previous).interruption,
          interruption,
          reason: interruption.name,
        );
      }
    });

    test('an event without an interruption leaves the current one alone', () {
      // Not every backend has an audio session to report on, and a progress
      // tick from one that does must not read as "the interruption ended".
      const previous = VlcPlayerValue(
        interruption: VlcAudioInterruption.focusLostTransient,
      );
      final next = VlcPlayerValue.fromEvent(<String, Object?>{
        'position': 1000,
      }, previous);
      expect(next.interruption, VlcAudioInterruption.focusLostTransient);
    });

    test('an unknown interruption name is ignored', () {
      const previous = VlcPlayerValue(
        interruption: VlcAudioInterruption.ducked,
      );
      final next = VlcPlayerValue.fromEvent(<String, Object?>{
        'interruption': 'somethingNew',
      }, previous);
      expect(next.interruption, VlcAudioInterruption.ducked);
    });

    test('isInterrupted covers everything but none', () {
      for (final interruption in VlcAudioInterruption.values) {
        expect(
          VlcPlayerValue(interruption: interruption).isInterrupted,
          interruption != VlcAudioInterruption.none,
          reason: interruption.name,
        );
      }
    });

    test('the interruption takes part in equality', () {
      expect(
        const VlcPlayerValue(interruption: VlcAudioInterruption.ducked),
        isNot(const VlcPlayerValue()),
      );
    });
  });

  group('transient loss', () {
    test('the controller issues nothing of its own while interrupted', () async {
      // The native side pauses in the same instant focus goes, because a film
      // must not talk over the first ring of a phone call. A second pause from
      // here would be noise on the channel and nothing else.
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('focusLostTransient');

      expect(methodsOn(harness), isEmpty);
      expect(
        controller.value.interruption,
        VlcAudioInterruption.focusLostTransient,
      );
    });

    test('resumes exactly once when focus comes back', () async {
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('focusLostTransient');
      await interrupt('none', state: 'paused');

      expect(methodsOn(harness), <String>['play']);
    });

    test('a second gain does not resume twice', () async {
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('focusLostTransient');
      await interrupt('none', state: 'paused');
      harness.calls.clear();
      await interrupt('none', state: 'playing');

      expect(methodsOn(harness), isEmpty);
    });

    test('a play the system refused is still resumed', () async {
      // Android refuses a focus request made during a call outright, so this
      // play does not start anything: the native side reports the refusal as
      // an interruption and the delayed grant that follows is the only thing
      // that will ever start it. Dropping the claim here would leave a viewer
      // who pressed play looking at a paused film after the call ended.
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('focusLostTransient');
      await controller.play();
      harness.calls.clear();

      await interrupt('none', state: 'paused');
      expect(methodsOn(harness), <String>['play']);
    });

    test('a deliberate pause during the call cancels the resume', () async {
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('focusLostTransient');
      await controller.pause();
      harness.calls.clear();

      await interrupt('none', state: 'paused');
      expect(methodsOn(harness), isEmpty);
    });

    test('a transient loss that turns permanent is not resumed', () async {
      // AVAudioSession says this with an .ended that withholds .shouldResume.
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('focusLostTransient');
      await interrupt('focusLost');
      await interrupt('none', state: 'paused');

      expect(methodsOn(harness), isEmpty);
    });

    test('a detached controller is left alone', () async {
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('focusLostTransient');
      await harness.detachController(controller);
      harness.calls.clear();

      await interrupt('none', state: 'paused');
      expect(methodsOn(harness), isEmpty);
    });
  });

  group('permanent loss', () {
    test('focus handed to another app is the viewer\'s to undo', () async {
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('focusLost');
      await interrupt('none', state: 'paused');

      expect(methodsOn(harness), isEmpty);
    });

    test('unplugged headphones never resume by themselves', () async {
      // The whole point of becoming-noisy: the film must not start blaring out
      // of the phone speaker the moment the buds come out.
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('becameNoisy');
      await interrupt('none', state: 'paused');

      expect(methodsOn(harness), isEmpty);
    });
  });

  group('ducking', () {
    test('a duck is not a pause, so there is nothing to resume', () async {
      final controller = await playing();
      addTearDown(controller.dispose);

      await interrupt('ducked', state: 'playing');
      expect(controller.value.interruption, VlcAudioInterruption.ducked);
      expect(methodsOn(harness), isEmpty);

      await interrupt('none', state: 'playing');
      expect(methodsOn(harness), isEmpty);
    });
  });

  group('against the background policy', () {
    test('a focus loss does not clear the policy\'s claim', () async {
      // The bug this guards: an interruption that ran through the public
      // pause() would clear _pausedForBackground, and the trip back to the
      // foreground would never restart the film.
      final controller = await playing();
      addTearDown(controller.dispose);

      await setAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(methodsOn(harness), <String>['pause']);

      await interrupt('focusLost');
      harness.calls.clear();

      await setAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(methodsOn(harness), <String>['play']);
    });

    test(
      'focus returning while the app is away waits for the way back',
      () async {
        final controller = await playing();
        addTearDown(controller.dispose);

        // A call arrives, then its full-screen UI takes the app away.
        await interrupt('focusLostTransient');
        await setAppLifecycleState(AppLifecycleState.paused);
        await pumpEventQueue();
        harness.calls.clear();

        // The call ends while the app is still hidden. Resuming here is exactly
        // the noise nobody asked for.
        await interrupt('none', state: 'paused');
        expect(methodsOn(harness), isEmpty);

        await setAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(methodsOn(harness), <String>['play']);
      },
    );

    test('keepPlaying resumes as soon as focus returns', () async {
      final controller = await playing(policy: VlcBackgroundPolicy.keepPlaying);
      addTearDown(controller.dispose);

      await interrupt('focusLostTransient');
      await setAppLifecycleState(AppLifecycleState.paused);
      await pumpEventQueue();
      harness.calls.clear();

      await interrupt('none', state: 'paused');
      expect(methodsOn(harness), <String>['play']);
    });
  });

  group('event throttling', () {
    test('an interruption is never held back as a progress tick', () async {
      final controller = await playing(
        eventThrottleInterval: const Duration(seconds: 10),
      );
      addTearDown(controller.dispose);

      await interrupt('focusLostTransient', state: 'playing');

      expect(
        controller.value.interruption,
        VlcAudioInterruption.focusLostTransient,
      );
    });
  });
}
