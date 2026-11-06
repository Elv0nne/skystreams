import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/player_brightness.dart';

/// The player's screen brightness, through the player's own plugin.
///
/// screen_brightness animated every change for a second on iOS, so a swipe's
/// brightness trailed the finger and only arrived once it stopped (an iPad,
/// 2026-10-10). Here a swipe's sets go one at a time with only the newest
/// waiting, and the reset as the player closes rides the same queue, so no set
/// still waiting can land after it and leave the screen dim.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('vlc_player');

  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) answer;

  setUp(() {
    calls = [];
    answer = (call) async => call.method == 'getScreenBrightness' ? 0.6 : null;
    messenger.setMockMethodCallHandler(methods, (call) {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('reads the level through the plugin; a refusal reads as none', () async {
    final brightness = PlatformPlayerBrightness();
    expect(await brightness.read(), 0.6);
    answer = (call) async => throw PlatformException(code: 'refused');
    expect(await brightness.read(), isNull);
  });

  test('a reset waits for the set in flight, and the set waiting behind it '
      'is never sent', () async {
    final held = <Completer<void>>[];
    answer = (call) {
      final done = Completer<void>();
      held.add(done);
      return done.future;
    };
    final brightness = PlatformPlayerBrightness();
    brightness.set(0.2);
    brightness.set(0.4);
    brightness.reset();
    await pumpEventQueue();
    expect(calls.map((c) => c.method), ['setScreenBrightness']);
    held.last.complete();
    await pumpEventQueue();
    expect(calls.map((c) => c.method), [
      'setScreenBrightness',
      'resetScreenBrightness',
    ]);
    expect(calls.first.arguments, {'level': 0.2});
    held.last.complete();
  });

  test('levels are kept to 0..1', () async {
    final brightness = PlatformPlayerBrightness();
    brightness.set(1.4);
    await pumpEventQueue();
    brightness.set(-0.5);
    await pumpEventQueue();
    expect(calls.map((c) => c.arguments), [
      {'level': 1.0},
      {'level': 0.0},
    ]);
  });
}
