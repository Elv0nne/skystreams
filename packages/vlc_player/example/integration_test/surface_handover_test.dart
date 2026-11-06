import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

const String _film = 'assets/format_fixtures/keep_picture/film.mp4';

/// The same film's first 8 s as MPEG-TS: the fixture's first four HLS
/// segments, one after the other.
const List<String> _opening = <String>[
  'assets/format_fixtures/keep_picture/hls/seg00.ts',
  'assets/format_fixtures/keep_picture/hls/seg01.ts',
  'assets/format_fixtures/keep_picture/hls/seg02.ts',
  'assets/format_fixtures/keep_picture/hls/seg03.ts',
];

/// How long every release waits before its stop: the package's test hook
/// (`VlcReleaseDelay`), standing in for a stop that is slow to return.
const Duration _releaseDelay = Duration(seconds: 10);

/// How long a new picture may take: about twice the TV emulator's slowest.
const Duration _pictureWithin = Duration(seconds: 6);

final GlobalKey _screen = GlobalKey();

/// A reopened player draws while the player it replaced still holds its
/// output (FORK.md 29).
///
/// libVLC 3's video output keeps its EGL window surface on its view until it
/// closes: when its video track is turned off (which libVLC's input thread
/// does between reads), or at its player's stop. Every player used to share
/// one TextureView, so a new player whose output was asked for first
/// couldn't draw: its hardware decoder gave up ("Opaque Vout request
/// failed"), it fell back to software, and its pictures failed until the old
/// output let go. In P1 Part 2's memory-4k run that was never.
///
/// Here the old player plays the film's first 8 s from a server that then
/// sends nothing more, so it runs dry and its input thread waits in a read,
/// and every release waits 10 s before its stop: the old output keeps its
/// surface for those seconds, as a stuck player's does. The new source is the
/// film as a local file. Its first 2 s are solid magenta, then grained green:
/// a reopen from 0 shows magenta only if the new player draws, and a playing
/// picture changes between captures while a frozen one doesn't.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a reopen shows its picture while the replaced player still '
      'holds its output', (tester) async {
    final (controller, server, film) = await _playUntilDry(tester);

    final asked = DateTime.now();
    await controller.setMedia(VlcMediaSource(uri: film), autoPlay: true);
    Duration? newPictureAt;
    while (newPictureAt == null &&
        DateTime.now().difference(asked) < _pictureWithin) {
      await tester.pump(const Duration(milliseconds: 200));
      if ((await _shown()).magenta) {
        newPictureAt = DateTime.now().difference(asked);
      }
    }
    // For the device matrix's record.
    debugPrint(
      'surface_handover (reopen): the new picture at '
      '${newPictureAt?.inMilliseconds} ms',
    );

    expect(
      newPictureAt,
      isNotNull,
      reason:
          'the reopened film\'s opening never showed while the replaced '
          'player held its output',
    );
    await _leave(tester, controller, server);
  });

  testWidgets('a park played while the replaced player still holds its '
      'output shows a moving picture', (tester) async {
    // Part 3's wait: the film set again with the picture kept and not
    // played, then played once its source answers.
    final (controller, server, film) = await _playUntilDry(tester);

    await controller.setMedia(
      VlcMediaSource(uri: film, startPosition: controller.value.position),
      keepPicture: true,
    );
    await tester.pump(const Duration(seconds: 1));
    final asked = DateTime.now();
    await controller.play();
    var last = await _shown();
    var changes = 0;
    Duration? movingAt;
    while (movingAt == null &&
        DateTime.now().difference(asked) < _pictureWithin) {
      await tester.pump(const Duration(milliseconds: 200));
      final look = await _shown();
      changes = !look.black && look.signature != last.signature
          ? changes + 1
          : 0;
      last = look;
      if (changes >= 3) movingAt = DateTime.now().difference(asked);
    }
    debugPrint(
      'surface_handover (park): moving at ${movingAt?.inMilliseconds} ms',
    );

    expect(
      movingAt,
      isNotNull,
      reason:
          'the played park showed no moving picture while the replaced '
          'player held its output',
    );
    await _leave(tester, controller, server);
  });

  testWidgets('leaving while replaced players are still stopping is '
      'immediate, and the next player shows its picture', (tester) async {
    final (controller, server, film) = await _playUntilDry(tester);
    await controller.setMedia(VlcMediaSource(uri: film), autoPlay: true);
    await tester.pump(const Duration(milliseconds: 500));
    await controller.setMedia(VlcMediaSource(uri: film), autoPlay: true);
    await tester.pump(const Duration(milliseconds: 500));

    final clock = Stopwatch()..start();
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    // A round trip through the event loop only completes once the main
    // thread is free again.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    clock.stop();
    debugPrint('surface_handover (leave): ${clock.elapsedMilliseconds} ms');
    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'leaving waited on the players still stopping',
    );

    // Their releases are still held back: a new player beside them plays.
    final next = await _mountPlayer(tester);
    await next.setMedia(VlcMediaSource(uri: film), autoPlay: true);
    await pumpUntil(
      tester,
      () => next.value.position >= const Duration(seconds: 3),
      description: 'the next player playing past the opening',
      attempts: 240,
    );
    expect((await _shown()).black, isFalse, reason: 'the next picture shows');
    await _leave(tester, next, server);
  });
}

Future<VlcPlayerController> _mountPlayer(WidgetTester tester) async {
  final controller = VlcPlayerController(
    options: <String>[
      ...headlessPlayerOptions(),
      '--vlc-player-release-delay-ms=${_releaseDelay.inMilliseconds}',
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(
            width: 320,
            height: 180,
            child: RepaintBoundary(
              key: _screen,
              child: VlcPlayer(controller: controller),
            ),
          ),
        ),
      ),
    ),
  );
  // A first player can take over ten seconds to start on an emulator.
  await pumpUntil(
    tester,
    () => controller.isAttached,
    description: 'native player attachment',
    attempts: 160,
  );
  return controller;
}

/// Plays the film's first 8 s from a server that then holds, past the
/// opening and on until it runs dry. Returns the player, the server and the
/// whole film as a local file, for the next source.
Future<(VlcPlayerController, _HoldingServer, Uri)> _playUntilDry(
  WidgetTester tester,
) async {
  final film = await materializeAsset(_film);
  final folder = File.fromUri(film).parent.path;
  final opening = File('$folder/opening.ts').openWrite();
  for (final segment in _opening) {
    final data = await rootBundle.load(segment);
    opening.add(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }
  await opening.close();
  final server = await _HoldingServer.start(folder);
  final controller = await _mountPlayer(tester);
  await controller.setMedia(
    VlcMediaSource(uri: server.uri('opening.ts')),
    autoPlay: true,
  );
  await pumpUntil(
    tester,
    () => controller.value.position >= const Duration(seconds: 3),
    description: 'three seconds of the film',
    attempts: 240,
  );
  expect((await _shown()).magenta, isFalse, reason: 'past the opening');
  await pumpUntil(
    tester,
    () => controller.value.isStalled,
    description: 'the player waiting on its server',
    attempts: 120,
  );
  return (controller, server, film);
}

/// Leaves the player, then waits out the held-back releases, so the next
/// test's player doesn't share the device with them.
Future<void> _leave(
  WidgetTester tester,
  VlcPlayerController controller,
  _HoldingServer server,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  final until = DateTime.now().add(_releaseDelay + const Duration(seconds: 2));
  while (DateTime.now().isBefore(until)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  server.close();
}

/// What a capture shows, read from its pixels.
class _Look {
  _Look({required this.magenta, required this.black, required this.signature});

  /// Most of the picture is the fixture's opening colour.
  final bool magenta;

  /// The picture has gone dark.
  final bool black;

  /// A digest of the middle of the picture: the grain changes it every frame.
  final int signature;
}

/// What the player shows, as Flutter draws it: the platform view's layer.
Future<_Look> _shown() async {
  final boundary =
      _screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final width = image.width;
  final height = image.height;
  image.dispose();
  var magenta = 0;
  var luminance = 0;
  var counted = 0;
  var signature = 17;
  // Every fourth pixel of the middle half, away from any edge rounding.
  for (var y = height ~/ 4; y < height * 3 ~/ 4; y += 4) {
    for (var x = width ~/ 4; x < width * 3 ~/ 4; x += 4) {
      final i = (y * width + x) * 4;
      final r = bytes.getUint8(i);
      final g = bytes.getUint8(i + 1);
      final b = bytes.getUint8(i + 2);
      if (r > 180 && g < 90 && b > 180) magenta += 1;
      luminance += (r * 299 + g * 587 + b * 114) ~/ 1000;
      counted += 1;
      signature = (signature * 31 + r + (g << 8) + (b << 16)) & 0x3fffffff;
    }
  }
  return _Look(
    magenta: magenta * 2 > counted,
    black: luminance ~/ counted < 16,
    signature: signature,
  );
}

/// Serves a folder over HTTP from its own isolate, the way a live stream is
/// served: no length and no ranges, so libVLC reads on and never seeks. A
/// response sends its whole file, then holds its connection open, sending
/// nothing more, until the server closes.
///
/// An MP4 served with ranges and held part-way never started playing here:
/// libVLC's buffering stayed at 0 %.
class _HoldingServer {
  _HoldingServer._(this._isolate, this.port);

  final Isolate _isolate;
  final int port;

  Uri uri(String path) => Uri.parse('http://127.0.0.1:$port/$path');

  static Future<_HoldingServer> start(String root) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_serveFiles, <Object>[
      ready.sendPort,
      root,
    ]);
    return _HoldingServer._(isolate, await ready.first as int);
  }

  void close() => _isolate.kill(priority: Isolate.immediate);
}

Future<void> _serveFiles(List<Object> args) async {
  final ready = args[0] as SendPort;
  final root = args[1] as String;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  ready.send(server.port);

  await for (final request in server) {
    unawaited(() async {
      try {
        final file = File('$root${request.uri.path}');
        if (!file.existsSync()) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType('video', 'mp2t');
        request.response.add(await file.readAsBytes());
        await request.response.flush();
        // The rest never comes: the isolate's end closes the connection.
        await Completer<void>().future;
      } catch (_) {
        // libVLC hung up first, which a stop does.
      }
    }());
  }
}
