import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// Attach and detach are not ordered against one another.
///
/// A host that swaps the widget occupying the video slot gets the replacement
/// built — and its platform view created and attached — before the outgoing
/// element is disposed. An unqualified detach from that outgoing element then
/// tears down the player that has just started, and the controller re-opens
/// its media from the beginning. That is the shape of the picture-in-picture
/// bug where entering PiP restarted the film.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VlcMethodChannelHarness harness;

  setUp(() {
    harness = VlcMethodChannelHarness()..install();
    harness.mockEventChannel(1);
    harness.mockEventChannel(2);
  });

  tearDown(() => harness.dispose());

  MethodCall? lastCall(String method) =>
      harness.calls.where((call) => call.method == method).lastOrNull;

  group('detach', () {
    test('a stale view id cannot take down a live attach', () async {
      final controller = VlcPlayerController();
      addTearDown(controller.dispose);
      await harness.attachController(controller, 1);
      await harness.attachController(controller, 2);

      await (controller as dynamic).detach(viewId: 1);

      expect(controller.isAttached, isTrue);
      await controller.play();
      expect(lastCall('play')?.arguments, containsPair('viewId', 2));
    });

    test('the id it does own still releases the native player', () async {
      final controller = VlcPlayerController();
      addTearDown(controller.dispose);
      await harness.attachController(controller, 1);

      await (controller as dynamic).detach(viewId: 1);

      expect(controller.isAttached, isFalse);
      expect(lastCall('dispose')?.arguments, containsPair('viewId', 1));
    });

    test('no id detaches whatever is attached', () async {
      // The texture platforms never learn the view id — the controller creates
      // the view itself — so the unqualified form has to keep working.
      final controller = VlcPlayerController();
      addTearDown(controller.dispose);
      await harness.attachController(controller, 1);

      await harness.detachController(controller);

      expect(controller.isAttached, isFalse);
      expect(lastCall('dispose')?.arguments, containsPair('viewId', 1));
    });
  });

  group('re-attach', () {
    test('resumes where playback got to, not where the source opened', () async {
      final controller = VlcPlayerController(
        mediaSource: VlcMediaSource(
          uri: Uri.parse('https://example.com/film.mkv'),
          startPosition: const Duration(seconds: 30),
        ),
        autoPlay: true,
      );
      addTearDown(controller.dispose);
      await harness.attachController(controller, 1);
      await harness.sendEvent(1, <String, Object?>{
        'state': 'playing',
        'position': 2700000,
        'duration': 5400000,
        'isReady': true,
      });

      await harness.detachController(controller);
      harness.calls.clear();
      await harness.attachController(controller, 2);

      expect(
        lastCall('setSource')?.arguments,
        containsPair('startPosition', 2700000),
      );
    });

    test('the configured start survives a first attach', () async {
      // The resume point handed in at construction: nothing has played, so
      // position zero is ignorance rather than an answer.
      final controller = VlcPlayerController(
        mediaSource: VlcMediaSource(
          uri: Uri.parse('https://example.com/film.mkv'),
          startPosition: const Duration(seconds: 30),
        ),
      );
      addTearDown(controller.dispose);

      await harness.attachController(controller, 1);

      expect(
        lastCall('setSource')?.arguments,
        containsPair('startPosition', 30000),
      );
    });
  });
}
