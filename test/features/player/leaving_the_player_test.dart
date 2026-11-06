import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/presentation/player_platform_service.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart';

import 'vlc_screen_harness.dart';

/// What Back hands back, and when: at the press, while the player's route is
/// still on its way out.
///
/// The route's exit transition runs 300 to 500 ms (450 on Android, 500 on iOS
/// and macOS), and everything here used to wait for it in `dispose`: the
/// handset stayed sideways, the status bar hidden and a desktop window full
/// screen until the transition had run, and only then began to turn, come
/// back or shrink. `dispose` still hands them back, for a route popped from
/// anywhere else.
const MethodChannel _window = MethodChannel('window_manager');

void main() {
  late List<List<String>> pinned;
  late List<List<String>> overlays;
  late List<bool> fullScreenRequests;
  late bool windowIsFullScreen;

  setUp(() {
    installEngineMocks();
    pinned = <List<String>>[];
    overlays = <List<String>>[];
    fullScreenRequests = <bool>[];
    windowIsFullScreen = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'SystemChrome.setPreferredOrientations':
          pinned.add(List<String>.from(call.arguments as List<Object?>));
        // What SystemUiMode.manual sends: the bars to show.
        case 'SystemChrome.setEnabledSystemUIOverlays':
          overlays.add(List<String>.from(call.arguments as List<Object?>));
      }
      return null;
    });
    messenger.setMockMethodCallHandler(_window, (call) async {
      switch (call.method) {
        case 'isFullScreen':
          return windowIsFullScreen;
        case 'setFullScreen':
          windowIsFullScreen =
              (call.arguments as Map)['isFullScreen'] as bool? ?? false;
          fullScreenRequests.add(windowIsFullScreen);
      }
      return null;
    });
  });

  tearDown(() {
    removeEngineMocks();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(_window, null);
  });

  /// A landscape film, held for as long as the settle asks, so the handset
  /// has been turned.
  Future<void> playLandscape(WidgetTester tester) async {
    await sendEvent(tester, <String, Object?>{
      ...snapshot(position: 1500),
      'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
      'codedSize': <String, Object?>{'width': 1920, 'height': 1088},
    });
    await tester.pump(
      PlayerPlatformService.shapeSettleDelay + const Duration(milliseconds: 1),
    );
  }

  Future<void> pumpPhone(WidgetTester tester) => pumpPlayer(
    tester,
    isTv: false,
    pushed: true,
    profile: const DeviceProfile(),
    panelPhysicalSize: const Size(1080, 1920),
    panelDevicePixelRatio: 3,
  );

  testWidgets('Back hands a turned handset back to the system as it is '
      'pressed', (
    tester,
  ) async {
    await pumpPhone(tester);
    await playLandscape(tester);
    expect(pinned, isNotEmpty, reason: 'the film turned the handset');
    pinned.clear();

    await sendBack(tester);

    expect(
      find.byType(VlcPlayerScreen),
      findsOneWidget,
      reason: 'the route is still on its way out',
    );
    expect(pinned, [<String>[]]);

    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(VlcPlayerScreen), findsNothing);
    expect(pinned, [
      <String>[],
    ], reason: 'handed back once, not again when the route has gone');
  }, variant: texturePlatform);

  testWidgets('a frame that arrives while the route leaves turns nothing', (
    tester,
  ) async {
    await pumpPhone(tester);
    await playLandscape(tester);
    pinned.clear();

    await sendBack(tester);
    // The engine plays on until the route has gone, and a tick still carries
    // the film's shape.
    await sendEvent(tester, <String, Object?>{
      ...snapshot(position: 2000),
      'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
      'codedSize': <String, Object?>{'width': 1920, 'height': 1088},
    });
    await tester.pump(
      PlayerPlatformService.shapeSettleDelay + const Duration(seconds: 1),
    );

    expect(find.byType(VlcPlayerScreen), findsNothing);
    expect(pinned, [
      <String>[],
    ], reason: 'the page underneath must not be turned sideways');
  }, variant: texturePlatform);

  testWidgets('the arrow in the top bar leaves as it is pressed', (
    tester,
  ) async {
    await pumpPhone(tester);
    // The controls start hidden; a viewer brings them up to reach the arrow.
    await sendFirstFrame(tester);
    final arrow = find.byTooltip('Back');
    expect(arrow.hitTestable(), findsOneWidget, reason: 'the bars are up');

    await tester.tap(arrow);
    // A frame, well inside the double-tap window.
    await tester.pump(const Duration(milliseconds: 50));

    expect(overlays, [
      ['SystemUiOverlay.top', 'SystemUiOverlay.bottom'],
    ], reason: 'the press waited for a second tap that never came');

    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(VlcPlayerScreen), findsNothing);
  }, variant: texturePlatform);

  testWidgets('Back brings the status bar back as it is pressed', (
    tester,
  ) async {
    await pumpPhone(tester);
    await sendFirstFrame(tester);

    await sendBack(tester);

    expect(find.byType(VlcPlayerScreen), findsOneWidget);
    expect(overlays, [
      ['SystemUiOverlay.top', 'SystemUiOverlay.bottom'],
    ]);

    await tester.pump(const Duration(seconds: 1));
  }, variant: texturePlatform);

  testWidgets('Back takes a desktop window out of full screen as it is '
      'pressed', (tester) async {
    windowIsFullScreen = true;
    await pumpPlayer(
      tester,
      isTv: false,
      pushed: true,
      profile: const DeviceProfile(isDesktopOS: true),
    );
    await sendFirstFrame(tester);

    await sendBack(tester);

    expect(find.byType(VlcPlayerScreen), findsOneWidget);
    expect(fullScreenRequests, [false]);

    await tester.pump(const Duration(seconds: 1));
    expect(fullScreenRequests, [false]);
  }, variant: texturePlatform);
}
