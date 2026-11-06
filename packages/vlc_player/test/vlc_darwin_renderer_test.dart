import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('vlc_player');
  final eventChannels = <EventChannel>[];

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final channel in eventChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(channel, null);
    }
    eventChannels.clear();
  });

  void mockEventChannel(int viewId) {
    final channel = EventChannel('vlc_player/events/$viewId');
    eventChannels.add(channel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          channel,
          MockStreamHandler.inline(
            onListen: (arguments, events) {},
            onCancel: (arguments) {},
          ),
        );
  }

  /// The override has to be undone inside the test body: the binding checks
  /// for leaked foundation debug variables before tearDown runs.
  Future<void> runAsPlatform(
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

  /// Answers `create` the way the Darwin plugins do, and records every call.
  List<MethodCall> mockPlugin({int viewId = -1, int textureId = 88}) {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (call) async {
          calls.add(call);
          if (call.method == 'create') {
            mockEventChannel(viewId);
            return <String, Object?>{'viewId': viewId, 'textureId': textureId};
          }
          return null;
        });
    return calls;
  }

  group('VlcPlayerConfig.darwinRenderer', () {
    test('defaults to the texture', () {
      // Flipped 2026-09-06 after the platform view was shown to drop the
      // video for a frame on every control interaction. See the constant's
      // doc for the measurement.
      expect(
        const VlcPlayerConfig().darwinRenderer,
        VlcDarwinRenderer.texture,
      );
      expect(
        VlcPlayerConfig.defaultDarwinRenderer,
        VlcDarwinRenderer.texture,
      );
    });

    test('is not a libVLC option', () {
      expect(
        const VlcPlayerConfig(
          darwinRenderer: VlcDarwinRenderer.texture,
        ).toOptions(),
        const VlcPlayerConfig().toOptions(),
      );
    });

    test('survives copyWith in both directions', () {
      const base = VlcPlayerConfig(darwinRenderer: VlcDarwinRenderer.texture);

      expect(base.copyWith().darwinRenderer, VlcDarwinRenderer.texture);
      expect(
        base.copyWith(verbose: true).darwinRenderer,
        VlcDarwinRenderer.texture,
      );
      expect(
        const VlcPlayerConfig()
            .copyWith(darwinRenderer: VlcDarwinRenderer.texture)
            .darwinRenderer,
        VlcDarwinRenderer.texture,
      );
    });
  });

  group('VlcPlayer on macOS', () {
    testWidgets('renders the texture by default', (tester) async {
      // The default flipped 2026-09-06: the platform view dropped the video
      // for a frame on every control interaction, the texture did not.
      await runAsPlatform(TargetPlatform.macOS, () async {
        final calls = mockPlugin();
        final platformViews = _PlatformViewsRecorder(onCreate: mockEventChannel)
          ..install();
        final controller = VlcPlayerController();

        await tester.pumpWidget(
          MaterialApp(home: VlcPlayer(controller: controller)),
        );
        await tester.pump();

        expect(find.byType(Texture), findsOneWidget);
        expect(find.byType(AppKitView), findsNothing);
        expect(platformViews.createdViews, isEmpty);
        expect(
          calls.map((call) => call.method),
          contains('create'),
          reason: 'the texture path mints a texture player, never a view',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
    });

    testWidgets('renders a texture when the renderer says so', (tester) async {
      await runAsPlatform(TargetPlatform.macOS, () async {
        final calls = mockPlugin(viewId: -1, textureId: 88);
        final platformViews = _PlatformViewsRecorder(onCreate: mockEventChannel)
          ..install();
        final controller = VlcPlayerController(
          options: const <String>['--network-caching=300'],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: VlcPlayer(
              controller: controller,
              darwinRenderer: VlcDarwinRenderer.texture,
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(AppKitView), findsNothing);
        expect(
          platformViews.createdViews,
          isEmpty,
          reason: 'the texture path must not create a platform view',
        );

        final texture = tester.widget<Texture>(find.byType(Texture));
        expect(texture.textureId, 88);

        final create = calls.singleWhere((call) => call.method == 'create');
        expect((create.arguments as Map)['options'], <String>[
          '--network-caching=300',
        ]);

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
    });

  });

  group('VlcPlayer on iOS', () {
    testWidgets('renders the texture by default', (tester) async {
      // Flipped 2026-09-06 alongside macOS. A UiKitView has the compositing
      // cost the AppKitView was measured paying, and the renderer behind the
      // texture is the one copy already verified there.
      await runAsPlatform(TargetPlatform.iOS, () async {
        final calls = mockPlugin();
        final platformViews = _PlatformViewsRecorder(onCreate: mockEventChannel)
          ..install();
        final controller = VlcPlayerController();

        await tester.pumpWidget(
          MaterialApp(home: VlcPlayer(controller: controller)),
        );
        await tester.pump();

        expect(find.byType(Texture), findsOneWidget);
        expect(find.byType(UiKitView), findsNothing);
        expect(platformViews.createdViews, isEmpty);
        expect(
          calls.map((call) => call.method),
          contains('create'),
          reason: 'the texture path mints a texture player, never a view',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
    });

    testWidgets('opts back into the platform view', (tester) async {
      // The platform view has to stay one flag away: the texture has not run
      // on an iOS device yet, and this is the escape hatch if it misbehaves.
      await runAsPlatform(TargetPlatform.iOS, () async {
        final calls = mockPlugin();
        final platformViews = _PlatformViewsRecorder(onCreate: mockEventChannel)
          ..install();
        final controller = VlcPlayerController();

        await tester.pumpWidget(
          MaterialApp(
            home: VlcPlayer(
              controller: controller,
              darwinRenderer: VlcDarwinRenderer.platformView,
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(UiKitView), findsOneWidget);
        expect(find.byType(Texture), findsNothing);
        expect(platformViews.createdViews, hasLength(1));
        expect(calls.map((call) => call.method), isNot(contains('create')));

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
    });
  });
}

/// Records the platform views the framework is asked to create.
class _PlatformViewsRecorder {
  _PlatformViewsRecorder({required this.onCreate});

  final void Function(int viewId) onCreate;
  final List<_CreatedPlatformView> createdViews = <_CreatedPlatformView>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
          if (call.method != 'create') {
            return null;
          }
          final arguments = call.arguments as Map<Object?, Object?>;
          final viewId = arguments['id']! as int;
          createdViews.add(
            _CreatedPlatformView(
              viewId: viewId,
              viewType: arguments['viewType']! as String,
            ),
          );
          onCreate(viewId);
          return null;
        });
  }
}

class _CreatedPlatformView {
  const _CreatedPlatformView({required this.viewId, required this.viewType});

  final int viewId;
  final String viewType;
}
