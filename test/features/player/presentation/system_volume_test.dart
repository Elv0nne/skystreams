import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/system_volume.dart';

/// The player's system volume, through the player's own plugin on Android and
/// iOS.
///
/// flutter_volume_controller's iOS listener set the app's audio session to
/// `.ambient` as it started (a film went silent a second in) and deactivated
/// the session as it stopped, under a film still playing (libVLC's audio output
/// stopped, and leaving the player froze the app). Found on an iPad,
/// 2026-10-10.
///
/// A swipe writes the level many times a second, and the platform reports each
/// write back a moment later, as VLC's players see it too: one write goes at a
/// time, the reports of the app's own writes are dropped, and once the writes
/// settle the level that stood is read once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('vlc_player');
  const events = EventChannel('vlc_player/system_volume');

  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) answer;
  MockStreamHandlerEventSink? platform;

  setUp(() {
    calls = [];
    platform = null;
    answer = (call) async => call.method == 'getSystemVolume' ? 0.4 : null;
    messenger.setMockMethodCallHandler(methods, (call) {
      calls.add(call);
      return answer(call);
    });
  });

  /// The platform's side of the change stream. Set up in each test's body: the
  /// mock delivers in the zone it was set up from, and a widget test's fake
  /// clock only runs its own zone.
  void mockPlatformStream() => messenger.setMockStreamHandler(
    events,
    MockStreamHandler.inline(onListen: (arguments, sink) => platform = sink),
  );

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  for (final target in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('on ${target.name}, the level is read, watched and set through the '
        "player's plugin", () async {
      debugDefaultTargetPlatformOverride = target;
      mockPlatformStream();
      final volume = PlatformSystemVolume();
      final levels = <double>[];
      final changes = volume.changes.listen(levels.add);
      await pumpEventQueue();
      platform!.success(0.7);
      await pumpEventQueue();
      expect(levels, [0.7], reason: 'the rocker, with no write about');
      expect(await volume.read(), 0.4);
      await volume.write(0.2);
      expect(await volume.isFixed(), isFalse);
      await volume.setPlayerShown(true);
      await pumpEventQueue();
      expect(calls.map((c) => c.method), [
        'getSystemVolume',
        'setSystemVolume',
        'isSystemVolumeFixed',
        'setPlayerShown',
      ]);
      expect(calls[1].arguments, {'level': 0.2});
      expect(calls[3].arguments, {'shown': true});
      volume.dispose();
      await changes.cancel();
    });
  }

  test('writes made while one is in flight send only the newest', () async {
    final held = <Completer<void>>[];
    answer = (call) {
      if (call.method != 'setSystemVolume') return Future.value();
      final write = Completer<void>();
      held.add(write);
      return write.future;
    };
    final volume = PlatformSystemVolume();
    await volume.write(0.1);
    await volume.write(0.2);
    await volume.write(0.3);
    await pumpEventQueue();
    expect(calls.map((c) => c.arguments), [
      {'level': 0.1},
    ]);
    held.last.complete();
    await pumpEventQueue();
    expect(calls.map((c) => c.arguments), [
      {'level': 0.1},
      {'level': 0.3},
    ]);
    held.last.complete();
    volume.dispose();
  });

  test("the platform's reports of the app's own writes are dropped; what "
      'stood is read once they settle', () async {
    // A real clock, short: the platform's mock stream delivers on it.
    const settle = Duration(milliseconds: 150);
    Future<void> settled() => Future<void>.delayed(settle * 3);
    mockPlatformStream();
    double standing = 0.53;
    answer = (call) async => call.method == 'getSystemVolume' ? standing : null;
    final volume = PlatformSystemVolume(settle: settle);
    final levels = <double>[];
    final changes = volume.changes.listen(levels.add);
    await pumpEventQueue();

    await volume.write(0.5);
    // Android rounds to its stream's steps: the write comes back as 0.47, then
    // 0.53.
    platform!.success(0.47);
    platform!.success(0.53);
    await pumpEventQueue();
    expect(levels, isEmpty, reason: 'echoes of the write, mid-swipe');

    await settled();
    expect(
      levels,
      isEmpty,
      reason: 'what stood is a step from what was asked: the same level',
    );

    // A raise past the safe level, held back by Android's hearing-safety limit.
    standing = 0.67;
    await volume.write(0.9);
    await settled();
    expect(levels, [
      0.67,
    ], reason: 'the level that stood, not the one asked for');

    // Settled: the rocker is reported as it comes.
    platform!.success(0.3);
    await pumpEventQueue();
    expect(levels, [0.67, 0.3]);

    volume.dispose();
    await changes.cancel();
  });

  test('a single rocker step inside the echo window is still reported, '
      'against the level that stood', () async {
    // The review found it: a step of a 25-step stream is 0.04, under the
    // 0.07 that tells a level from the one asked for.
    const settle = Duration(milliseconds: 150);
    mockPlatformStream();
    double standing = 0.52;
    answer = (call) async => switch (call.method) {
      // A 25-step stream rounds 0.5 to 13 steps.
      'setSystemVolume' => 0.52,
      'getSystemVolume' => standing,
      _ => null,
    };
    final volume = PlatformSystemVolume(settle: settle);
    final levels = <double>[];
    final changes = volume.changes.listen(levels.add);
    await pumpEventQueue();

    await volume.write(0.5);
    await pumpEventQueue();
    // The rocker, one step up, a moment after the swipe.
    standing = 0.56;
    platform!.success(0.56);
    await pumpEventQueue();
    expect(levels, isEmpty, reason: 'inside the echo window');

    await Future<void>.delayed(settle * 3);
    expect(levels, [0.56]);

    volume.dispose();
    await changes.cancel();
  });

  test(
    'a write that starts while the settled level is being read wins',
    () async {
      const settle = Duration(milliseconds: 100);
      mockPlatformStream();
      final reading = Completer<double?>();
      answer = (call) async => switch (call.method) {
        'getSystemVolume' => reading.future,
        _ => null,
      };
      final volume = PlatformSystemVolume(settle: settle);
      final levels = <double>[];
      final changes = volume.changes.listen(levels.add);
      await pumpEventQueue();

      await volume.write(0.5);
      await Future<void>.delayed(settle * 2);
      // The settle read is out; the finger moves again before it answers.
      await volume.write(0.9);
      reading.complete(0.2);
      await pumpEventQueue();
      expect(levels, isEmpty, reason: 'a level from before the newest write');

      volume.dispose();
      await changes.cancel();
    },
  );

  test(
    "a platform that refuses doesn't take the player's volume control down",
    () async {
      answer = (call) async => throw PlatformException(code: 'refused');
      final volume = PlatformSystemVolume();
      expect(await volume.read(), isNull);
      expect(await volume.isFixed(), isFalse);
      await volume.setPlayerShown(true);
      await volume.write(0.5);
      await pumpEventQueue();
      volume.dispose();
    },
  );
}
