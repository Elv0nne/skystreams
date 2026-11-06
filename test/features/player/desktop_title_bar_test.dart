import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';
import 'package:skystream/main.dart';
import 'package:window_manager/window_manager.dart';

/// The desktop title bar is stacked over every route, and it is drawn last, so
/// it wins. Over the player that is two bugs at once: the 48px hover state
/// lands squarely on the player's own back button and title, and the 8px
/// collapsed strip is an invisible band across the top of the video that eats
/// pointers for a bar nobody asked for. Full screen makes it worse - there is
/// no window furniture to reach for there at all.
///
/// Subject is [CustomTitleBar] itself rather than the app: main.dart only
/// stacks it on Windows and Linux, and the host running this is neither.
const MethodChannel _window = MethodChannel('window_manager');

/// The strip's collapsed height, from [CustomTitleBar]. Its presence is the
/// bug - a transparent 8px MouseRegion is still a pointer target.
const double _collapsedStrip = 8;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late bool windowIsFullScreen;

  setUp(() {
    windowIsFullScreen = false;
    immersiveRouteActive.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_window, (call) async {
          switch (call.method) {
            case 'isFullScreen':
              return windowIsFullScreen;
            case 'isMaximized':
            case 'isAlwaysOnTop':
              return false;
          }
          return null;
        });
  });

  tearDown(() {
    immersiveRouteActive.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_window, null);
  });

  /// Mirrors main.dart's builder: the bar is pinned across the top of whatever
  /// the route drew, which is what makes its height the thing to measure.
  Future<void> pumpTitleBar(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: ColoredBox(color: Colors.black)),
            Positioned(top: 0, left: 0, right: 0, child: CustomTitleBar()),
          ],
        ),
      ),
    );
    // _updateStates waits out the window manager's transition before reading.
    await tester.pump(const Duration(milliseconds: 300));
  }

  double barHeight(WidgetTester tester) =>
      tester.getSize(find.byType(CustomTitleBar)).height;

  testWidgets('the strip is there on an ordinary route', (tester) async {
    await pumpTitleBar(tester);

    expect(barHeight(tester), _collapsedStrip);
  });

  testWidgets('the player route gets the top of the window to itself', (
    tester,
  ) async {
    immersiveRouteActive.value = true;
    await pumpTitleBar(tester);

    expect(
      barHeight(tester),
      0,
      reason:
          'the title bar is still over the player, hiding its back button '
          'on hover and eating pointers the rest of the time',
    );
  });

  testWidgets('a flag set after the bar is up still stands it down', (
    tester,
  ) async {
    await pumpTitleBar(tester);
    expect(barHeight(tester), _collapsedStrip);

    immersiveRouteActive.value = true;
    await tester.pump();

    expect(
      barHeight(tester),
      0,
      reason: 'the bar has to follow the flag, not just sample it once',
    );
  });

  testWidgets('full screen stands it down whatever route is up', (
    tester,
  ) async {
    await pumpTitleBar(tester);
    expect(barHeight(tester), _collapsedStrip);

    windowIsFullScreen = true;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _window.name,
      _window.codec.encodeMethodCall(
        const MethodCall('onEvent', <String, Object?>{
          'eventName': kWindowEventEnterFullScreen,
        }),
      ),
      (_) {},
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      barHeight(tester),
      0,
      reason: 'there is no window furniture to reach for in full screen',
    );
  });
}
