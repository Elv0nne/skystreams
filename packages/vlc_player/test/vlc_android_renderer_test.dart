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
  Future<void> runAsAndroid(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  /// Answers `create` the way the Android plugin does - a negative viewId, so
  /// it can never collide with one the engine minted - and records every call.
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

  group('VlcPlayerConfig.androidRenderer', () {
    test('defaults to the platform view', () {
      // Deliberately not the texture, unlike every other platform: a
      // single-surface texture costs libVLC 3 its hardware decoder (the
      // Android vout will not open on an opaque MediaCodec surface with no
      // subtitle surface to blend into, and falls back to avcodec). See the
      // constant's doc for the chain and the device check that would flip it.
      expect(
        const VlcPlayerConfig().androidRenderer,
        VlcAndroidRenderer.platformView,
      );
      expect(
        VlcPlayerConfig.defaultAndroidRenderer,
        VlcAndroidRenderer.platformView,
      );
    });

    test('is not a libVLC option', () {
      expect(
        const VlcPlayerConfig(
          androidRenderer: VlcAndroidRenderer.platformView,
        ).toOptions(),
        const VlcPlayerConfig().toOptions(),
      );
    });

    test('survives copyWith in both directions', () {
      const base = VlcPlayerConfig(
        androidRenderer: VlcAndroidRenderer.platformView,
      );

      expect(base.copyWith().androidRenderer, VlcAndroidRenderer.platformView);
      expect(
        base.copyWith(verbose: true).androidRenderer,
        VlcAndroidRenderer.platformView,
      );
      expect(
        const VlcPlayerConfig()
            .copyWith(androidRenderer: VlcAndroidRenderer.platformView)
            .androidRenderer,
        VlcAndroidRenderer.platformView,
      );
    });
  });

  group('VlcPlayer on Android', () {
    testWidgets('renders the platform view by default', (tester) async {
      // The view keeps MediaCodec hardware decode alive on libVLC 3; the
      // texture does not yet. Default follows the decoder, not the tidiness.
      await runAsAndroid(() async {
        final calls = mockPlugin();
        final platformViews = _PlatformViewsRecorder(onCreate: mockEventChannel)
          ..install();
        final controller = VlcPlayerController();

        await tester.pumpWidget(
          MaterialApp(home: VlcPlayer(controller: controller)),
        );
        await tester.pump();

        expect(find.byType(AndroidView), findsOneWidget);
        expect(find.byType(Texture), findsNothing);
        expect(platformViews.createdViews, hasLength(1));
        expect(
          calls.map((call) => call.method),
          isNot(contains('create')),
          reason: 'the platform-view path must never mint a texture player',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
    });

    testWidgets('renders the texture the plugin replied with', (tester) async {
      await runAsAndroid(() async {
        final calls = mockPlugin(viewId: -1, textureId: 88);
        _PlatformViewsRecorder(onCreate: mockEventChannel).install();
        final controller = VlcPlayerController(
          options: const <String>['--network-caching=300'],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: VlcPlayer(
              controller: controller,
              androidRenderer: VlcAndroidRenderer.texture,
            ),
          ),
        );
        await tester.pump();

        final texture = tester.widget<Texture>(find.byType(Texture));
        expect(texture.textureId, 88);

        // A Texture contributes no focus node, so there is nothing for a TV
        // remote to land on and nothing that needed excluding.
        expect(find.byType(ExcludeFocus), findsNothing);
        final scope = FocusScope.of(tester.element(find.byType(VlcPlayer)));
        expect(scope.traversalDescendants, isEmpty);

        final create = calls.singleWhere((call) => call.method == 'create');
        expect((create.arguments as Map)['options'], <String>[
          '--network-caching=300',
        ]);

        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      });
    });

    testWidgets('an explicit platform view matches the default', (tester) async {
      // Hosts that pin the renderer must get the same thing the default gives,
      // so the flag can be set unconditionally without changing behaviour.
      await runAsAndroid(() async {
        final calls = mockPlugin();
        final platformViews = _PlatformViewsRecorder(onCreate: mockEventChannel)
          ..install();
        final controller = VlcPlayerController();

        await tester.pumpWidget(
          MaterialApp(
            home: VlcPlayer(
              controller: controller,
              androidRenderer: VlcAndroidRenderer.platformView,
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(AndroidView), findsOneWidget);
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
