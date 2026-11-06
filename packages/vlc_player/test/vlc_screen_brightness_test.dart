import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

/// The app's screen brightness on Android and iOS, set as the finger moves.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('vlc_player');

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return call.method == 'getScreenBrightness' ? 0.6 : null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('reads the level the screen has now', () async {
    expect(await VlcScreenBrightness.read(), 0.6);
    expect(calls.single.method, 'getScreenBrightness');
  });

  test('sets a level, and gives the screen back to the system', () async {
    await VlcScreenBrightness.set(0.3);
    await VlcScreenBrightness.reset();
    expect(calls.map((c) => c.method), [
      'setScreenBrightness',
      'resetScreenBrightness',
    ]);
    expect(calls.first.arguments, {'level': 0.3});
  });
}
