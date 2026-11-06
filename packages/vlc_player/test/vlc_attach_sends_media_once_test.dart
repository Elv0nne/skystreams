import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/src/vlc_player_controller_internals.dart';
import 'package:vlc_player/src/vlc_video_geometry.dart';
import 'package:vlc_player/vlc_player.dart';

import 'vlc_method_channel_harness.dart';

/// An attach sends the media a host queued before the player existed, once.
///
/// The bug this file holds shut (FORK.md 34): the host's setMedia landed
/// while the attach was still getting the new player ready - the subtitle
/// look on the texture path, the geometry on the platform view - and both
/// sent setSource. The second retired the player the first had just opened:
/// an extra connection, up to 0.6 MB fetched for nothing, and a player
/// retired mid-open at every affected first open (as often as 24 in 26 on
/// Windows in P1 Part 2's runs).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VlcMethodChannelHarness harness;
  late Completer<Object?> held;
  late String holdMethod;

  setUp(() {
    held = Completer<Object?>();
    harness = VlcMethodChannelHarness()
      ..install(
        onCall: (call) async {
          if (call.method == 'create') {
            return <String, Object?>{'viewId': 1, 'textureId': 7};
          }
          if (call.method == holdMethod) return held.future;
          return null;
        },
      );
    harness.mockEventChannel(1);
  });

  tearDown(() => harness.dispose());

  const look = VlcSubtitleLook(
    color: Color(0xFFFFFFFF),
    backgroundColor: Color(0xFF000000),
  );
  final media = VlcMediaSource(uri: Uri.parse('https://example.com/film.mp4'));

  List<MethodCall> sources() =>
      harness.calls.where((call) => call.method == 'setSource').toList();

  test('a texture attach sends media set while the look is on its way '
      'once', () async {
    holdMethod = 'setSubtitleLook';
    final controller = VlcPlayerController();
    addTearDown(controller.dispose);
    // As the screen does in initState: kept until a player exists.
    await controller.setSubtitleLook(look);

    final attaching = harness.attachTexturePlayer(controller);
    await pumpEventQueue();
    expect(
      harness.calls.map((call) => call.method),
      containsAllInOrder(<String>['create', 'setSubtitleLook']),
    );

    await controller.setMedia(media, autoPlay: true);
    held.complete(true);
    await attaching;

    expect(sources(), hasLength(1));
  });

  test('a platform-view attach sends media set while the geometry is on its '
      'way once', () async {
    holdMethod = 'setVideoGeometry';
    final controller = VlcPlayerController();
    addTearDown(controller.dispose);
    // As the VlcPlayer widget does on Android's platform view after layout.
    (controller as VlcPlayerControllerInternals).setVideoGeometry(
      const VlcVideoGeometry(crop: '16:9'),
    );

    final attaching = harness.attachController(controller, 1);
    await pumpEventQueue();
    expect(
      harness.calls.map((call) => call.method),
      contains('setVideoGeometry'),
    );

    await controller.setMedia(media, autoPlay: true);
    held.complete(null);
    await attaching;

    expect(sources(), hasLength(1));
  });

  test('media set before the player exists goes out once, from the '
      'attach', () async {
    holdMethod = 'nothing';
    final controller = VlcPlayerController();
    addTearDown(controller.dispose);
    await controller.setSubtitleLook(look);
    await controller.setMedia(media, autoPlay: true);
    expect(sources(), isEmpty);

    await harness.attachTexturePlayer(controller);

    expect(sources(), hasLength(1));
  });
}
