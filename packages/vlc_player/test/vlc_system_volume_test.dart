import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

/// The device's media volume on Android and iOS, through this plugin rather
/// than a volume plugin that reconfigures the app's audio session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('vlc_player');
  const events = EventChannel('vlc_player/system_volume');

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('reads the level from the plugin', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return 0.4;
    });
    expect(await VlcSystemVolume.read(), 0.4);
    expect(calls.single.method, 'getSystemVolume');
  });

  test('sets the level, and says whether the player is on screen', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return call.method == 'setSystemVolume' ? 0.2667 : null;
    });
    // The level that stood: Android's stream rounds to its steps.
    expect(await VlcSystemVolume.write(0.25), 0.2667);
    await VlcSystemVolume.setPlayerShown(true);
    expect(calls.map((c) => c.method), ['setSystemVolume', 'setPlayerShown']);
    expect(calls[0].arguments, {'level': 0.25});
    expect(calls[1].arguments, {'shown': true});
  });

  test('says whether the device volume is fixed', () async {
    Object? answer;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      return answer;
    });
    answer = true;
    expect(await VlcSystemVolume.isFixed(), isTrue);
    answer = false;
    expect(await VlcSystemVolume.isFixed(), isFalse);
    // A platform with no answer has a volume an app can change.
    answer = null;
    expect(await VlcSystemVolume.isFixed(), isFalse);
    expect(calls.toSet(), {'isSystemVolumeFixed'});
  });

  test('hands on each change of the level', () async {
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, sink) {
          sink.success(0.3);
          sink.success(0.6);
        },
      ),
    );
    expect(await VlcSystemVolume.changes.take(2).toList(), [0.3, 0.6]);
  });
}
