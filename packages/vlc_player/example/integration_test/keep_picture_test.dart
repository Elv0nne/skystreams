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

const String _fixtureRoot = 'assets/format_fixtures/keep_picture';

final GlobalKey _screen = GlobalKey();

/// A reopen of the same film at a position, asked to keep its picture, never
/// shows the film's opening and never goes black (spec 2, "How the picture
/// stays").
///
/// libVLC 3 shows a new media's first decoded picture at once, and for a media
/// given a start position that is the picture at 0: it decodes the first
/// samples before it seeks to the start. On a slow link that picture stayed up
/// for as long as the seek took - 7 s on the iOS simulator and 9 s on the
/// Android emulator at 1.5 Mbit/s (SkyStream's reopen spike, 2026-10-14). The
/// fixture's first two seconds are solid magenta so that a capture can tell.
///
/// The server runs on its own isolate and slows to about 16 KB/s for the
/// reopen, so the seek takes seconds here too.
///
/// The rest hold the output to the contract every backend reports
/// (`pictureHeld`, FORK.md 30): a plain setMedia never holds, a hold outlives a
/// media that fails before it plays, and the report that ends a hold carries
/// the new picture's shape.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final kind in const <String>['mp4', 'hls']) {
    testWidgets('a reopen that keeps the picture never shows the film\'s '
        'opening ($kind)', (tester) async {
      final server = await _ThrottledServer.start(await _materializeFixtures());
      addTearDown(server.close);
      final controller = VlcPlayerController(options: headlessPlayerOptions());
      addTearDown(controller.dispose);
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
      // A first player can take over ten seconds to start where libVLC is
      // slow to load: an x64 build emulated on ARM, an Android emulator.
      await pumpUntil(
        tester,
        () => controller.isAttached,
        description: 'native player attachment',
        attempts: 160,
      );

      final path = kind == 'mp4' ? 'film.mp4' : 'hls/index.m3u8';
      await controller.setMedia(
        VlcMediaSource(uri: server.uri(path)),
        autoPlay: true,
      );
      await pumpUntil(
        tester,
        () => controller.value.position >= const Duration(seconds: 6),
        description: 'six seconds of the film',
        attempts: 240,
      );
      expect((await _shown()).magenta, isFalse, reason: 'past the opening');

      server.slow();
      final at = controller.value.position;
      await controller.setMedia(
        VlcMediaSource(uri: server.uri('$path?again'), startPosition: at),
        autoPlay: true,
        keepPicture: true,
      );
      var sawHeld = false;
      final seen = <_Look>[];
      // When a capture was neither the held picture nor the new one, and
      // whether the hold was on then: the record a rare one needs.
      final marks = <String>[];
      final reopenedAt = DateTime.now();
      final gapEnds = reopenedAt.add(const Duration(seconds: 6));
      while (DateTime.now().isBefore(gapEnds)) {
        await tester.pump(const Duration(milliseconds: 200));
        final held = controller.value.isPictureHeld;
        sawHeld |= held;
        final look = await _shown();
        seen.add(look);
        if (look.magenta || look.black) {
          marks.add(
            '$look at ${DateTime.now().difference(reopenedAt).inMilliseconds} '
            'ms, held $held',
          );
        }
      }
      server.fast();
      await pumpUntil(
        tester,
        () =>
            !controller.value.isPictureHeld &&
            controller.value.position > at + const Duration(seconds: 1),
        description: 'the reopened film playing from where it was',
        attempts: 240,
      );
      final last = await _shown();
      seen.add(last);
      if (last.magenta || last.black) marks.add('$last after the hold');
      // For the device matrix's record.
      debugPrint(
        'keep_picture ($kind): ${seen.length} captures, '
        '${seen.where((look) => look.magenta).length} magenta, '
        '${seen.where((look) => look.black).length} black, held: $sawHeld'
        '${marks.isEmpty ? '' : '; ${marks.join(', ')}'}',
      );

      expect(sawHeld, isTrue, reason: 'the output held the picture');
      expect(
        seen.where((look) => look.magenta),
        isEmpty,
        reason: 'the film\'s opening never showed (${seen.length} captures)',
      );
      expect(
        seen.where((look) => look.black),
        isEmpty,
        reason: 'the picture never went black',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a hold after a kept-picture media that failed still keeps the '
      'picture', (tester) async {
    // A reconnect that fails reports opening, then an error, and keeps its
    // hold (FORK.md 30); the attempt after it carries the hold on, and the
    // first picture it decodes is its frame 0, which must not end it
    // (SkyStream's whole-part review of P1 Part 2, 2026-10-15).
    final server = await _ThrottledServer.start(await _materializeFixtures());
    addTearDown(server.close);
    final controller = VlcPlayerController(options: headlessPlayerOptions());
    addTearDown(controller.dispose);
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
    await pumpUntil(
      tester,
      () => controller.isAttached,
      description: 'native player attachment',
      attempts: 160,
    );
    await controller.setMedia(
      VlcMediaSource(uri: server.uri('film.mp4')),
      autoPlay: true,
    );
    await pumpUntil(
      tester,
      () => controller.value.position >= const Duration(seconds: 6),
      description: 'six seconds of the film',
      attempts: 240,
    );
    final at = controller.value.position;

    await controller.setMedia(
      VlcMediaSource(uri: server.uri('missing.mp4')),
      autoPlay: true,
      keepPicture: true,
    );
    // libVLC reports a media it cannot open as an error on some backends and
    // as stopped on others (Darwin).
    await pumpUntil(
      tester,
      () => const <VlcPlaybackState>{
        VlcPlaybackState.error,
        VlcPlaybackState.stopped,
        VlcPlaybackState.ended,
      }.contains(controller.value.state),
      description: 'the missing media giving up',
      attempts: 160,
    );

    server.slow();
    await controller.setMedia(
      VlcMediaSource(uri: server.uri('film.mp4?again'), startPosition: at),
      autoPlay: true,
      keepPicture: true,
    );
    final seen = <_Look>[];
    final gapEnds = DateTime.now().add(const Duration(seconds: 6));
    while (DateTime.now().isBefore(gapEnds)) {
      await tester.pump(const Duration(milliseconds: 200));
      seen.add(await _shown());
    }
    server.fast();
    await pumpUntil(
      tester,
      () =>
          !controller.value.isPictureHeld &&
          controller.value.position > at + const Duration(seconds: 1),
      description: 'the reopened film playing from where it was',
      attempts: 240,
    );
    seen.add(await _shown());
    debugPrint(
      'keep_picture (after a failure): ${seen.length} captures, '
      '${seen.where((look) => look.magenta).length} magenta, '
      '${seen.where((look) => look.black).length} black',
    );

    expect(
      seen.where((look) => look.magenta),
      isEmpty,
      reason: 'the film\'s opening never showed (${seen.length} captures)',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a plain setMedia never reports a held picture', (tester) async {
    // Darwin's renderer bridges every change of source - it keeps the last
    // picture until the new media's first, or its texture would go black - and
    // reported that as a hold, so the old picture's size stayed through a
    // failover's opening (P1 Part 2's whole-part review, M1).
    final server = await _ThrottledServer.start(await _materializeFixtures());
    addTearDown(server.close);
    final (controller, at) = await _playPastTheOpening(
      tester,
      server,
      'film.mp4',
    );

    server.slow();
    await controller.setMedia(
      VlcMediaSource(uri: server.uri('film.mp4?plain'), startPosition: at),
      autoPlay: true,
    );
    // Every backend sends the new media's opening snapshot before it answers
    // setSource, so this reads it already.
    var sawHeld = controller.value.isPictureHeld;
    final watchEnds = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(watchEnds)) {
      await tester.pump(const Duration(milliseconds: 100));
      sawHeld |= controller.value.isPictureHeld;
    }
    server.fast();
    await pumpUntil(
      tester,
      () => controller.value.position > at + const Duration(seconds: 1),
      description: 'the new media playing',
      attempts: 240,
    );
    sawHeld |= controller.value.isPictureHeld;

    expect(sawHeld, isFalse, reason: 'only keepPicture holds the picture');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a held media that fails keeps reporting and showing the '
      'picture', (tester) async {
    // A recovery parks a source over the held picture or tries it again, so
    // the picture has to stay, and say so, on every platform. Android dropped
    // its copy at once and showed whatever the failed media had drawn under it
    // (P1 Part 2's whole-part review, M2).
    final server = await _ThrottledServer.start(await _materializeFixtures());
    addTearDown(server.close);
    final (controller, _) = await _playPastTheOpening(
      tester,
      server,
      'film.mp4',
    );

    await controller.setMedia(
      VlcMediaSource(uri: server.uri('missing.mp4')),
      autoPlay: true,
      keepPicture: true,
    );
    // libVLC reports a media it cannot open as an error on some backends and
    // as stopped on others (Darwin).
    await pumpUntil(
      tester,
      () => const <VlcPlaybackState>{
        VlcPlaybackState.error,
        VlcPlaybackState.stopped,
        VlcPlaybackState.ended,
      }.contains(controller.value.state),
      description: 'the missing media giving up',
      attempts: 160,
    );
    final heldEach = <bool>[];
    final seen = <_Look>[];
    final watchEnds = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(watchEnds)) {
      await tester.pump(const Duration(milliseconds: 200));
      heldEach.add(controller.value.isPictureHeld);
      seen.add(await _shown());
    }
    debugPrint(
      'keep_picture (held after a failure): ${seen.length} captures, '
      '${seen.where((look) => look.magenta).length} magenta, '
      '${seen.where((look) => look.black).length} black, '
      'held ${heldEach.where((held) => held).length} of ${heldEach.length}',
    );

    expect(
      heldEach,
      everyElement(isTrue),
      reason: 'the hold outlives a media that fails before it plays',
    );
    expect(
      seen.where((look) => look.magenta || look.black),
      isEmpty,
      reason: 'and the held picture stays on screen',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the first report that moves after a held reopen already says '
      'not held, at the new picture\'s shape', (tester) async {
    // The output shows the new media's pictures from the hold's end, and Dart
    // lays the texture out at the size the value carries. The report that
    // ended a hold came up to a second later on Windows and Linux (the pump's
    // heartbeat) and on Darwin (VLCKit's next time callback), with the new
    // picture laid out at the old shape meanwhile (P1 Part 2's review, M4).
    final server = await _ThrottledServer.start(await _materializeFixtures());
    addTearDown(server.close);
    final (controller, at) = await _playPastTheOpening(
      tester,
      server,
      'film.mp4',
    );

    final values = <VlcPlayerValue>[];
    void record() => values.add(controller.value);
    controller.addListener(record);
    await controller.setMedia(
      VlcMediaSource(uri: server.uri('film_4x3.mp4'), startPosition: at),
      autoPlay: true,
      keepPicture: true,
    );
    await pumpUntil(
      tester,
      () => controller.value.position > at + const Duration(seconds: 1),
      description: 'the 4:3 film playing from where the other was',
      attempts: 240,
    );
    controller.removeListener(record);

    // The new media reports 0 until it plays: its first report past 0 is the
    // time report that ends the hold.
    final opened = values.indexWhere(
      (value) => value.position == Duration.zero,
    );
    expect(
      opened,
      isNonNegative,
      reason: 'the new media said it had played nothing yet',
    );
    final moved = values
        .skip(opened)
        .where((value) => value.position > Duration.zero)
        .firstOrNull;
    debugPrint(
      'keep_picture (shape): ${values.length} values, at the first move held '
      '${moved?.isPictureHeld}, size ${moved?.videoSize}',
    );

    expect(
      values.any((value) => value.isPictureHeld),
      isTrue,
      reason: 'the reopen held the picture',
    );
    expect(moved, isNotNull, reason: 'the new media moved');
    expect(
      moved!.isPictureHeld,
      isFalse,
      reason: 'the report that ends the hold says so',
    );
    final size = moved.videoSize;
    expect(size, isNotNull, reason: 'and carries a size');
    expect(
      size!.width / size.height,
      closeTo(4 / 3, 0.02),
      reason: 'the new picture\'s shape, not the held one\'s',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a held reopen says so by the time setMedia returns', (
    tester,
  ) async {
    // Every backend sends the new media's opening snapshot before it answers
    // setSource, and a host reads the hold right after the await: SkyStream's
    // recovery parks a failed source and keeps the picture only if the output
    // says it holds (FORK.md 33). Darwin queued its events for a later turn
    // of the main queue, so the answer came first (P1 Part 3's macOS rows).
    final server = await _ThrottledServer.start(await _materializeFixtures());
    addTearDown(server.close);
    final (controller, at) = await _playPastTheOpening(
      tester,
      server,
      'film.mp4',
    );

    await controller.setMedia(
      VlcMediaSource(uri: server.uri('film.mp4'), startPosition: at),
      keepPicture: true,
    );
    final held = controller.value.isPictureHeld;
    debugPrint('keep_picture (answer): held $held when setMedia returned');

    expect(held, isTrue, reason: 'the opening snapshot came before the answer');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// What a capture shows, read from its pixels.
class _Look {
  _Look({required this.magenta, required this.black});

  /// Most of the picture is the fixture's opening colour.
  final bool magenta;

  /// The picture has gone dark: a cleared output.
  final bool black;

  @override
  String toString() => magenta ? 'magenta' : (black ? 'black' : 'picture');
}

/// What the player shows, as Flutter draws it: the texture on Darwin, Windows
/// and Linux, the platform view's layer on Android.
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
    }
  }
  return _Look(
    magenta: magenta * 2 > counted,
    black: luminance ~/ counted < 16,
  );
}

/// A 320x180 player playing [path] from [server] past the film's opening, and
/// where it was then.
Future<(VlcPlayerController, Duration)> _playPastTheOpening(
  WidgetTester tester,
  _ThrottledServer server,
  String path,
) async {
  final controller = VlcPlayerController(options: headlessPlayerOptions());
  addTearDown(controller.dispose);
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
  // A first player can take over ten seconds to start where libVLC is slow to
  // load: an x64 build emulated on ARM, an Android emulator.
  await pumpUntil(
    tester,
    () => controller.isAttached,
    description: 'native player attachment',
    attempts: 160,
  );
  await controller.setMedia(
    VlcMediaSource(uri: server.uri(path)),
    autoPlay: true,
  );
  await pumpUntil(
    tester,
    () => controller.value.position >= const Duration(seconds: 6),
    description: 'six seconds of the film',
    attempts: 240,
  );
  expect((await _shown()).magenta, isFalse, reason: 'past the opening');
  return (controller, controller.value.position);
}

/// Writes the fixture's assets to a folder of their own and returns its path.
Future<String> _materializeFixtures() async {
  final directory = await Directory.systemTemp.createTemp(
    'vlc_player_keep_picture_',
  );
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  for (final asset in manifest.listAssets()) {
    if (!asset.startsWith('$_fixtureRoot/')) continue;
    final file = File(
      '${directory.path}/${asset.substring(_fixtureRoot.length + 1)}',
    );
    await file.parent.create(recursive: true);
    final data = await rootBundle.load(asset);
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }
  return directory.path;
}

/// Serves a folder over HTTP with ranges, from its own isolate, at a rate the
/// test sets: unlimited, or about 16 KB/s per connection.
class _ThrottledServer {
  _ThrottledServer._(this._isolate, this.port, this._control);

  final Isolate _isolate;
  final int port;
  final SendPort _control;

  Uri uri(String path) => Uri.parse('http://127.0.0.1:$port/$path');

  void slow() => _control.send(16 * 1024);

  void fast() => _control.send(0);

  static Future<_ThrottledServer> start(String root) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_serveFiles, <Object>[
      ready.sendPort,
      root,
    ]);
    final reply = await ready.first as List<Object?>;
    return _ThrottledServer._(isolate, reply[0]! as int, reply[1]! as SendPort);
  }

  void close() => _isolate.kill(priority: Isolate.immediate);
}

Future<void> _serveFiles(List<Object> args) async {
  final ready = args[0] as SendPort;
  final root = args[1] as String;
  var bytesPerSecond = 0;
  final control = ReceivePort()
    ..listen((rate) => bytesPerSecond = rate! as int);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  ready.send(<Object>[server.port, control.sendPort]);

  await for (final request in server) {
    unawaited(() async {
      try {
        final file = File('$root${request.uri.path}');
        if (!file.existsSync()) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final bytes = await file.readAsBytes();
        var start = 0;
        var end = bytes.length - 1;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        final match = range == null
            ? null
            : RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (match != null) {
          start = int.parse(match.group(1)!);
          if (match.group(2)!.isNotEmpty) end = int.parse(match.group(2)!);
          if (start >= bytes.length) {
            request.response.statusCode =
                HttpStatus.requestedRangeNotSatisfiable;
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */${bytes.length}',
            );
            await request.response.close();
            return;
          }
          if (end >= bytes.length) end = bytes.length - 1;
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          );
        }
        final path = request.uri.path;
        request.response.headers
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..contentType = path.endsWith('.m3u8')
              ? ContentType('application', 'vnd.apple.mpegurl')
              : path.endsWith('.ts')
              ? ContentType('video', 'mp2t')
              : ContentType('video', 'mp4');
        request.response.contentLength = end - start + 1;
        const chunk = 4096;
        for (var at = start; at <= end; at += chunk) {
          final last = at + chunk - 1 > end ? end : at + chunk - 1;
          request.response.add(bytes.sublist(at, last + 1));
          await request.response.flush();
          if (bytesPerSecond > 0) {
            await Future<void>.delayed(
              Duration(
                microseconds: (last - at + 1) * 1000000 ~/ bytesPerSecond,
              ),
            );
          }
        }
        await request.response.close();
      } catch (_) {
        // libVLC hung up first, which a reopen does.
      }
    }());
  }
}
