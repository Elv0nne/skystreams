import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// The desktop plugins number each snapshot as they make it, and the
/// controller applies none older than the last one it applied (FORK.md 37).
///
/// Windows delivers a snapshot sent from libVLC's event thread later than one
/// sent at once on the platform thread, so the order snapshots were made in is
/// not the order they arrive in. A reopen measured on Windows: the new media's
/// held opening snapshot (100) arrived before the old media's end (99), which
/// then let go of the held picture and said the new media had ended.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VlcMethodChannelHarness harness;
  var created = 0;

  setUp(() {
    created = 0;
    harness = VlcMethodChannelHarness()
      ..install(
        onCall: (call) async {
          if (call.method == 'create') {
            return <String, Object?>{'viewId': ++created, 'textureId': 7};
          }
          return null;
        },
      );
  });

  tearDown(() => harness.dispose());

  Map<String, Object?> snapshot(
    String state, {
    int? sequence,
    int position = 0,
    bool held = false,
  }) => <String, Object?>{
    'state': state,
    'position': position,
    'duration': 60000,
    'isReady': true,
    'isSeekable': true,
    'pictureHeld': held,
    'sequence': ?sequence,
  };

  test('an older snapshot that arrives after a newer one is not '
      'applied', () async {
    final controller = VlcPlayerController();
    addTearDown(controller.dispose);
    harness.mockEventChannel(71);
    await harness.attachController(controller, 71);

    // As they arrived on Windows (p4-t14-windows-diag.log, live-drop20).
    await harness.sendEvent(
      71,
      snapshot('ended', sequence: 98, position: 31145),
    );
    await harness.sendEvent(71, snapshot('opening', sequence: 100, held: true));
    await harness.sendEvent(
      71,
      snapshot('ended', sequence: 99, position: 31145),
    );

    expect(controller.value.state, VlcPlaybackState.opening);
    expect(controller.value.isPictureHeld, isTrue);

    await harness.sendEvent(
      71,
      snapshot('playing', sequence: 101, position: 400),
    );
    expect(controller.value.state, VlcPlaybackState.playing);
    expect(controller.value.position, const Duration(milliseconds: 400));
  });

  test('snapshots without a number apply in the order they arrive', () async {
    // Android and the Apple platforms send them in the order they are made.
    final controller = VlcPlayerController();
    addTearDown(controller.dispose);
    harness.mockEventChannel(72);
    await harness.attachController(controller, 72);

    await harness.sendEvent(72, snapshot('playing', position: 5000));
    await harness.sendEvent(72, snapshot('paused', position: 4000));

    expect(controller.value.state, VlcPlaybackState.paused);
    expect(controller.value.position, const Duration(seconds: 4));
  });

  test('a new platform view numbers its snapshots from the start '
      'again', () async {
    final controller = VlcPlayerController();
    addTearDown(controller.dispose);
    harness
      ..mockEventChannel(73)
      ..mockEventChannel(74);
    await harness.attachController(controller, 73);
    await harness.sendEvent(73, snapshot('playing', sequence: 50));

    await harness.attachController(controller, 74);
    await harness.sendEvent(74, snapshot('opening', sequence: 1));

    expect(controller.value.state, VlcPlaybackState.opening);
  });

  test('a new texture player numbers its snapshots from the start '
      'again', () async {
    final controller = VlcPlayerController();
    addTearDown(controller.dispose);
    harness
      ..mockEventChannel(1)
      ..mockEventChannel(2);
    await harness.attachTexturePlayer(controller);
    await harness.sendEvent(1, snapshot('playing', sequence: 50));

    await harness.detachController(controller);
    await harness.attachTexturePlayer(controller);
    await harness.sendEvent(2, snapshot('opening', sequence: 1));

    expect(controller.value.state, VlcPlaybackState.opening);
  });
}
