import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

const String _assetRoot = 'assets/format_fixtures';

/// What a player does by default, whatever VLCKit's own defaults say
/// (FORK.md 32).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a media played to its end reports ended', (tester) async {
    // VLCKit's macOS defaults begin with --play-and-pause, which pauses
    // libVLC's input at every end instead of ending it: a host saw a pause
    // nobody asked for, with no next episode after a finished film and
    // nothing recovered from a lost connection's false end.
    final controller = await _mount(tester, headlessPlayerOptions());
    final states = <VlcPlaybackState>[];
    void record() {
      final state = controller.value.state;
      if (states.isEmpty || states.last != state) states.add(state);
    }

    controller.addListener(record);
    addTearDown(() => controller.removeListener(record));
    // Two seconds of video.
    await controller.setMedia(
      VlcMediaSource(uri: await materializeAsset('$_assetRoot/video.mp4')),
      autoPlay: true,
    );
    // The first play after an install waits for libVLC's font database on
    // Android (FORK.md 26): 12.7 s on the TV emulator, longer after a few
    // installs in one boot.
    await pumpUntil(
      tester,
      () => states.contains(VlcPlaybackState.playing),
      description: 'the media playing',
      attempts: 240,
    );
    await pumpUntil(
      tester,
      () =>
          controller.value.state != VlcPlaybackState.playing &&
          controller.value.state != VlcPlaybackState.buffering,
      description: 'the media past its end',
    );
    // For the device matrix's record.
    debugPrint('player_defaults: ${states.map((s) => s.name).join(' ')}');
    // Ended, then stopped as libVLC closes the input; never paused.
    expect(states, contains(VlcPlaybackState.ended));
    expect(states, isNot(contains(VlcPlaybackState.paused)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a new player starts at the volume the last one was set to',
    (tester) async {
      // libVLC did it on macOS through the volume it saved in its
      // configuration, which every new audio output read; the plugin carries
      // it now that the saving is off. An audio output is needed for a
      // volume, so these players get one; no media plays.
      final first = await _mount(tester, const <String>['--quiet']);
      await first.setVolume(150);
      await pumpUntil(
        tester,
        () => first.value.volume == 150,
        description: 'the first player at 150',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      first.dispose();

      final second = await _mount(tester, const <String>['--quiet']);
      // Its first snapshot says what its audio output started at.
      await tester.pump(const Duration(seconds: 1));
      expect(second.value.volume, 150);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    // The other backends never carried a volume from one player to the next.
    skip: !Platform.isMacOS,
  );
}

/// A texture player of its own, attached.
Future<VlcPlayerController> _mount(
  WidgetTester tester,
  List<String> options,
) async {
  final controller = VlcPlayerController(options: options);
  addTearDown(controller.dispose);
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
  return controller;
}
