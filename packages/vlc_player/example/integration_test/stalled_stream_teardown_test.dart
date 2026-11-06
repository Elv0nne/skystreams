import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

const String _assetRoot = 'assets/format_fixtures';

/// How long the fixture's segment hangs before giving up. Longer than any
/// sane answer to "does leaving this stream freeze the app", and short enough
/// that a run against a build that does freeze still ends.
const Duration _stall = Duration(seconds: 12);

/// Leaving a live stream whose download has stalled must not freeze the app.
///
/// libVLC 3 tears a player's stream down synchronously: `stop()` and
/// `set_media()` both stop the input thread and wait for it to exit, and they
/// hold the player's input lock while they do. A live HLS stream whose segment
/// read has stalled keeps that thread alive for as long as the read lasts.
/// The plugin made both calls on the Android main thread - which Flutter's UI
/// thread is merged into - so pressing back, or switching to another source,
/// held the whole app for as long as the download did. Past five seconds
/// Android reports the app as not responding; users saw it freeze and die.
///
/// The server runs on its own isolate: a frozen main thread would otherwise
/// freeze it too, and the stalled read would never end.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('switching away from a stalled live stream is immediate', (
    tester,
  ) async {
    final server = await _StallingHlsServer.start();
    addTearDown(server.close);
    final controller = await _playStalledStream(tester, server);

    final clock = Stopwatch()..start();
    await controller.setMedia(
      VlcMediaSource(uri: await materializeAsset('$_assetRoot/video.mp4')),
      autoPlay: true,
    );
    clock.stop();
    // For the device matrix's record.
    debugPrint(
      'stalled_stream_teardown: switch ${clock.elapsedMilliseconds} ms',
    );

    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'switching source waited on the stalled stream',
    );
    // And the source it switched to really plays, picture and all. videoSize
    // is what every backend reports for a picture; displayVideoSize is null
    // on Windows and Linux by design (it serves phones' orientation).
    await pumpUntil(
      tester,
      () => controller.value.videoSize != null,
      description: 'the new source playing',
    );
    expect(controller.value.hasError, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving the player during a stalled live stream is immediate', (
    tester,
  ) async {
    final server = await _StallingHlsServer.start();
    addTearDown(server.close);
    final controller = await _playStalledStream(tester, server);

    final clock = Stopwatch()..start();
    // What pressing back does: the player's widget goes, which disposes the
    // platform view, and the owner disposes the controller.
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    // A round trip through the event loop only completes once the main
    // thread is free again.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    clock.stop();
    debugPrint(
      'stalled_stream_teardown: leave ${clock.elapsedMilliseconds} ms',
    );

    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'leaving the player waited on the stalled stream',
    );
  });

  testWidgets('leaving the player while the stalled stream it switched away '
      'from still stops is immediate', (tester) async {
    // A replaced player stops on a thread of its own and keeps its view until
    // it has (FORK.md 29). Leaving destroys that view, and libvlc-android's
    // listener turned the video off on the main thread, behind the input
    // lock the stop holds while the read hangs: 22 minutes after a network
    // loss in SkyStream's offline row on Android (P1 Part 3). The stream shows
    // a picture first: a view that never drew has no surface to lose.
    final server = await _StallingHlsServer.start(
      film: await _materializeFilm(),
    );
    addTearDown(server.close);
    final controller = await _playStalledStream(tester, server, picture: true);
    await controller.setMedia(
      VlcMediaSource(uri: await materializeAsset('$_assetRoot/video.mp4')),
      autoPlay: true,
    );
    await tester.pump(const Duration(seconds: 1));

    final clock = Stopwatch()..start();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    clock.stop();
    debugPrint(
      'stalled_stream_teardown: leave after a switch '
      '${clock.elapsedMilliseconds} ms',
    );

    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'leaving the player waited on the stalled player it replaced',
    );
  });

  testWidgets('resizing the player while the stalled stream it switched away '
      'from still stops is immediate', (tester) async {
    // libvlc-android's layout listener on the replaced player's views
    // answered a resize of the container - a rotation, picture-in-picture -
    // by calling into libVLC on the main thread when that player had no
    // picture size yet, behind the input lock its stop holds (FORK.md 29).
    final server = await _StallingHlsServer.start();
    addTearDown(server.close);
    final size = ValueNotifier<Size>(const Size(240, 135));
    addTearDown(size.dispose);
    final controller = await _playStalledStream(tester, server, size: size);
    await controller.setMedia(
      VlcMediaSource(uri: await materializeAsset('$_assetRoot/video.mp4')),
      autoPlay: true,
    );
    await tester.pump(const Duration(seconds: 1));

    final clock = Stopwatch()..start();
    // The rotation.
    size.value = const Size(135, 240);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    clock.stop();
    debugPrint(
      'stalled_stream_teardown: resize after a switch '
      '${clock.elapsedMilliseconds} ms',
    );

    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'the resize waited on the stalled player it replaced',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

/// Mounts a player with the app's network options and has it open the stalled
/// stream, then waits until libVLC is inside the download that hangs, and with
/// [picture], until the stream's own picture is up. [size], when given, sizes
/// the player and can change under it.
Future<VlcPlayerController> _playStalledStream(
  WidgetTester tester,
  _StallingHlsServer server, {
  bool picture = false,
  ValueListenable<Size>? size,
}) async {
  final controller = VlcPlayerController(
    options: <String>[
      ...headlessPlayerOptions(),
      // What SkyStream runs with: see VlcNetworkConfig in the app.
      '--network-caching=3000',
      '--stream-filter=prefetch',
      '--prefetch-buffer-size=65536',
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder<Size>(
          valueListenable: size ?? ValueNotifier<Size>(const Size(240, 135)),
          builder: (context, size, child) =>
              SizedBox(width: size.width, height: size.height, child: child),
          child: VlcPlayer(controller: controller),
        ),
      ),
    ),
  );
  // A first player can take over ten seconds to start where libVLC is slow
  // to load: an x64 build emulated on ARM with no plugin cache yet.
  await pumpUntil(
    tester,
    () => controller.isAttached,
    description: 'native player attachment',
    attempts: 160,
  );
  // The stalled stream follows a picture, as a real switch does. On Android
  // it has to: libVLC builds its font database at the first picture after an
  // install (11.5 s on the phone emulator), on the thread that opens that
  // media, and the switch below would otherwise wait on that, not the stall.
  await controller.setMedia(
    VlcMediaSource(uri: await materializeAsset('$_assetRoot/video.mp4')),
    autoPlay: true,
  );
  await pumpUntil(
    tester,
    () => controller.value.videoSize != null,
    description: 'a first picture',
    attempts: 240,
  );
  await controller.setMedia(
    VlcMediaSource(uri: server.playlistUri),
    autoPlay: true,
  );
  await pumpUntil(
    tester,
    () => server.segmentRequests > 0,
    description: 'libVLC asking for the segment that stalls',
  );
  if (picture) {
    // The film is 320 wide, the file before it 160.
    await pumpUntil(
      tester,
      () => controller.value.videoSize?.width == 320,
      description: "the stalled stream's picture",
      attempts: 240,
    );
  }
  // Give the download a moment to be well and truly stuck.
  await tester.pump(const Duration(seconds: 2));
  return controller;
}

/// Writes the keep-picture film's HLS to a folder of its own and returns its
/// path.
Future<String> _materializeFilm() async {
  const root = '$_assetRoot/keep_picture/hls';
  final directory = await Directory.systemTemp.createTemp(
    'vlc_player_stalled_film_',
  );
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  for (final asset in manifest.listAssets()) {
    if (!asset.startsWith('$root/')) continue;
    final data = await rootBundle.load(asset);
    await File(
      '${directory.path}/${asset.substring(root.length + 1)}',
    ).writeAsBytes(data.buffer.asUint8List(), flush: true);
  }
  return directory.path;
}

/// A live HLS stream whose segments start downloading and then stop, or with
/// [film] (a folder of the keep-picture film's HLS), that film, whose first
/// segments come whole and the ones after them stop: a picture, then the stall.
class _StallingHlsServer {
  _StallingHlsServer._(this._isolate, this.port, this._requests, this._path);

  final Isolate _isolate;
  final int port;
  final ReceivePort _requests;
  final String _path;
  int segmentRequests = 0;

  Uri get playlistUri => Uri.parse('http://127.0.0.1:$port/$_path');

  static Future<_StallingHlsServer> start({String? film}) async {
    final ready = ReceivePort();
    final requests = ReceivePort();
    final isolate = await Isolate.spawn(_serve, <Object?>[
      ready.sendPort,
      requests.sendPort,
      _stall.inMilliseconds,
      film,
    ]);
    final port = await ready.first as int;
    final server = _StallingHlsServer._(
      isolate,
      port,
      requests,
      film == null ? 'live.m3u8' : 'index.m3u8',
    );
    requests.listen((_) => server.segmentRequests += 1);
    return server;
  }

  void close() {
    _requests.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

/// The film's segments that come whole: four seconds of picture.
const Set<String> _wholeSegments = {'/seg00.ts', '/seg01.ts'};

Future<void> _serve(List<Object?> args) async {
  final ready = args[0]! as SendPort;
  final requests = args[1]! as SendPort;
  final stall = Duration(milliseconds: args[2]! as int);
  final film = args[3] as String?;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  ready.send(server.port);

  var sequence = 0;
  await for (final request in server) {
    final path = request.uri.path;
    if (film != null &&
        (path.endsWith('.m3u8') || _wholeSegments.contains(path))) {
      request.response.headers.contentType = path.endsWith('.m3u8')
          ? ContentType('application', 'vnd.apple.mpegurl')
          : ContentType('video', 'mp2t');
      request.response.add(await File('$film$path').readAsBytes());
      await request.response.close();
      continue;
    }
    if (path.endsWith('.m3u8')) {
      // Live: no end tag, so the playlist is fetched again as it goes.
      request.response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
      );
      request.response.write(
        '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-MEDIA-SEQUENCE:$sequence\n'
        '#EXTINF:4.0,\nseg$sequence.ts\n'
        '#EXTINF:4.0,\nseg${sequence + 1}.ts\n',
      );
      sequence += 1;
      await request.response.close();
      continue;
    }
    requests.send(request.uri.path);
    // A segment that starts and then goes quiet: headers and a first packet,
    // then nothing until the stall runs out.
    unawaited(() async {
      try {
        request.response.headers.contentType = ContentType('video', 'mp2t');
        request.response.contentLength = 4 * 1024 * 1024;
        request.response.add(List<int>.filled(188, 0)..[0] = 0x47);
        await request.response.flush();
        await Future<void>.delayed(stall);
        await request.response.close();
      } catch (_) {
        // The client went away first, which is the point.
      }
    }());
  }
}
