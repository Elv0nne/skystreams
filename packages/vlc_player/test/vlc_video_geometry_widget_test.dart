import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

/// On Android's platform view the widget tells the native player the crop or
/// aspect ratio its fit needs, and tells it again whenever the fit or its own
/// size changes - a rotation, a resized window, picture-in-picture. Nowhere
/// else: every other renderer hands Flutter a whole picture to fit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('vlc_player');
  late List<MethodCall> calls;
  final eventChannels = <EventChannel>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockEventChannel(int viewId) {
    final channel = EventChannel('vlc_player/events/$viewId');
    eventChannels.add(channel);
    messenger.setMockStreamHandler(
      channel,
      MockStreamHandler.inline(onListen: (arguments, sink) {}),
    );
  }

  setUp(() {
    calls = <MethodCall>[];
    messenger
      ..setMockMethodCallHandler(methodChannel, (call) async {
        calls.add(call);
        if (call.method == 'create') {
          // The texture path: the plugin mints the player and answers with
          // its view and texture.
          mockEventChannel(-1);
          return <String, Object?>{'viewId': -1, 'textureId': 43};
        }
        return null;
      })
      ..setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
        if (call.method == 'create') {
          mockEventChannel(
            (call.arguments as Map<Object?, Object?>)['id']! as int,
          );
        }
        return null;
      });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger
      ..setMockMethodCallHandler(methodChannel, null)
      ..setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final channel in eventChannels) {
      messenger.setMockStreamHandler(channel, null);
    }
    eventChannels.clear();
  });

  /// The override has to be undone inside the test body: the binding checks
  /// for leaked foundation debug variables before tearDown runs.
  Future<void> runAs(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Iterable<MethodCall> geometryCalls() =>
      calls.where((call) => call.method == 'setVideoGeometry');

  Map<String, Object?>? lastGeometry() {
    final sent = geometryCalls();
    if (sent.isEmpty) return null;
    final arguments = Map<String, Object?>.from(sent.last.arguments as Map);
    return <String, Object?>{
      'crop': arguments['crop'],
      'aspectRatio': arguments['aspectRatio'],
    };
  }

  Future<VlcPlayerController> pump(
    WidgetTester tester, {
    required VlcVideoFit fit,
    Size size = const Size(400, 180),
    VlcPlayerController? controller,
    VlcAndroidRenderer androidRenderer = VlcAndroidRenderer.platformView,
  }) async {
    final player = controller ?? VlcPlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VlcPlayer(
              controller: player,
              fit: fit,
              androidRenderer: androidRenderer,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return player;
  }

  Future<void> unmount(WidgetTester tester, VlcPlayerController player) async {
    await tester.pumpWidget(const SizedBox.shrink());
    player.dispose();
  }

  testWidgets('Zoom has libVLC crop to the shape of the view', (tester) async {
    await runAs(TargetPlatform.android, () async {
      final controller = await pump(tester, fit: VlcVideoFit.cover);

      expect(lastGeometry(), <String, Object?>{
        'crop': '20:9',
        'aspectRatio': null,
      });

      await unmount(tester, controller);
    });
  });

  testWidgets('switching fit replaces what libVLC was told', (tester) async {
    await runAs(TargetPlatform.android, () async {
      final controller = await pump(tester, fit: VlcVideoFit.cover);

      await pump(tester, fit: VlcVideoFit.fill, controller: controller);
      expect(lastGeometry(), <String, Object?>{
        'crop': null,
        'aspectRatio': '20:9',
      });

      await pump(tester, fit: VlcVideoFit.contain, controller: controller);
      expect(lastGeometry(), <String, Object?>{
        'crop': null,
        'aspectRatio': null,
      });

      await unmount(tester, controller);
    });
  });

  testWidgets('a new size is a new crop', (tester) async {
    await runAs(TargetPlatform.android, () async {
      final controller = await pump(tester, fit: VlcVideoFit.cover);

      await pump(
        tester,
        fit: VlcVideoFit.cover,
        size: const Size(300, 180),
        controller: controller,
      );

      expect(lastGeometry()?['crop'], '5:3');

      await unmount(tester, controller);
    });
  });

  testWidgets('the same geometry is not sent twice', (tester) async {
    await runAs(TargetPlatform.android, () async {
      final controller = await pump(tester, fit: VlcVideoFit.cover);
      final before = geometryCalls().length;

      await pump(tester, fit: VlcVideoFit.cover, controller: controller);

      expect(geometryCalls().length, before);

      await unmount(tester, controller);
    });
  });

  testWidgets('a renderer Flutter fits is never told', (tester) async {
    for (final (platform, renderer) in <(TargetPlatform, VlcAndroidRenderer)>[
      (TargetPlatform.android, VlcAndroidRenderer.texture),
      (TargetPlatform.windows, VlcAndroidRenderer.platformView),
      (TargetPlatform.macOS, VlcAndroidRenderer.platformView),
    ]) {
      await runAs(platform, () async {
        final controller = await pump(
          tester,
          fit: VlcVideoFit.cover,
          androidRenderer: renderer,
        );
        await pump(
          tester,
          fit: VlcVideoFit.fill,
          controller: controller,
          androidRenderer: renderer,
        );

        expect(geometryCalls(), isEmpty, reason: '$platform, $renderer');

        await unmount(tester, controller);
      });
    }
  });
}
