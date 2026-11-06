import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'test_support.dart';

final GlobalKey _screen = GlobalKey();

const String _fixture = 'assets/format_fixtures/video_subtitles.mkv';

/// A text track inside the video takes a new look while it plays.
///
/// libVLC 3 fixes a subtitle style when its instance is created; the look is
/// changed underneath it, on every platform's libVLC (see
/// src/native/vlc_subtitle_look.h). The fixture is a grey 640x360 picture
/// whose text track shows the same white line every half second, and a new
/// look is drawn from a line's start, so each check waits for it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a text track inside the video changes look while it plays', (
    WidgetTester tester,
  ) async {
    final controller = await _player(tester);
    await _play(tester, controller);

    await _until(
      tester,
      'the white line',
      (shown) => shown.white.count > 150 && shown.red.count < 30,
      within: const Duration(seconds: 10),
    );

    expect(await controller.setSubtitleLook(_red), isTrue);
    final restyled = await _until(
      tester,
      'the red line on a blue box',
      (shown) =>
          shown.red.count > 150 &&
          shown.white.count < 30 &&
          shown.blue.count > shown.red.count,
    );

    expect(await controller.setSubtitleLook(_raised), isTrue);
    final up = await _until(
      tester,
      'the raised line',
      (shown) => shown.red.bottom < restyled.red.bottom - 5,
    );
    // Of the picture, whatever pixels libVLC counts it in on this platform.
    final picture = _pictureHeight(tester);
    expect(
      (restyled.red.bottom - up.red.bottom) / picture,
      closeTo(_raised.raise, 0.03),
      reason: 'Raised from $restyled to $up, in a picture $picture high.',
    );

    // Half as large again: twice the size wraps the line on Windows, whose
    // default font is wider.
    const larger = VlcSubtitleLook(
      textScale: 150,
      color: Color(0xFFFF0000),
      backgroundColor: Color(0xFF0000FF),
      backgroundOpacity: 255,
      outlineThickness: 0,
    );
    expect(await controller.setSubtitleLook(larger), isTrue);
    final big = await _until(
      tester,
      'the larger line',
      (shown) => shown.red.rows > restyled.red.rows * 1.25,
    );
    expect(
      big.red.rows / restyled.red.rows,
      inInclusiveRange(1.3, 1.7),
      reason: 'From $restyled to $big.',
    );

    await _stop(tester, controller);
  });

  testWidgets('a look set before the media is there reaches its lines', (
    WidgetTester tester,
  ) async {
    final controller = await _player(tester);
    // As an app restoring a saved look does: before any media, when there is
    // no picture yet for the raise to be a share of.
    await controller.setSubtitleLook(_raised);
    await _play(tester, controller);

    await _until(
      tester,
      'the red line',
      (shown) => shown.red.count > 150 && shown.white.count < 30,
      within: const Duration(seconds: 10),
    );
    // The raise reaches the line once the engine knows the picture's size.
    await tester.pump(const Duration(milliseconds: 1500));
    final up = await _shown();

    expect(await controller.setSubtitleLook(_red), isTrue);
    final down = await _until(
      tester,
      'the line lowered',
      (shown) => shown.red.bottom > up.red.bottom + 5,
    );
    final picture = _pictureHeight(tester);
    expect(
      (down.red.bottom - up.red.bottom) / picture,
      closeTo(_raised.raise, 0.03),
      reason: 'Raised at $up, lowered to $down, in a picture $picture high.',
    );

    await _stop(tester, controller);
  });
}

const VlcSubtitleLook _red = VlcSubtitleLook(
  color: Color(0xFFFF0000),
  backgroundColor: Color(0xFF0000FF),
  backgroundOpacity: 255,
  outlineThickness: 0,
);

const VlcSubtitleLook _raised = VlcSubtitleLook(
  color: Color(0xFFFF0000),
  backgroundColor: Color(0xFF0000FF),
  backgroundOpacity: 255,
  outlineThickness: 0,
  raise: 0.15,
);

/// A player in a 640x360 box, attached.
Future<VlcPlayerController> _player(WidgetTester tester) async {
  final controller = VlcPlayerController(
    options: <String>[
      ...headlessPlayerOptions(),
      // Letters a tenth of the picture high, whose colour survives 4:2:0
      // chroma.
      ...const VlcSubtitleStyle(relativeFontSize: 10).toOptions(),
    ],
  );
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 640,
            height: 360,
            child: RepaintBoundary(
              key: _screen,
              child: VlcPlayer(controller: controller),
            ),
          ),
        ),
      ),
    ),
  );
  // A first player can take over ten seconds to start where libVLC is slow
  // to load: an x64 build emulated on ARM, an Android emulator.
  await pumpUntil(
    tester,
    () => controller.isAttached,
    description: 'native player attachment',
    attempts: 160,
  );
  return controller;
}

/// Plays the fixture with its text track on.
Future<void> _play(WidgetTester tester, VlcPlayerController controller) async {
  await controller.setMedia(
    VlcMediaSource(uri: await materializeAsset(_fixture)),
    autoPlay: true,
  );
  await pumpUntil(
    tester,
    () =>
        controller.value.position >= const Duration(milliseconds: 500) ||
        controller.value.hasError,
    description: 'playback',
    // Likewise the first media an Android emulator opens.
    attempts: 160,
  );
  debugPrint('subtitle look: playing at ${controller.value.position}');
  expect(
    controller.value.hasError,
    isFalse,
    reason: '${controller.value.error}',
  );
  final track = (await controller.getSubtitleTracks())
      .where((track) => track.id >= 0)
      .firstOrNull;
  expect(track, isNotNull, reason: 'The fixture carries a text track.');
  await controller.setSubtitleTrack(track!.id);
}

Future<void> _stop(WidgetTester tester, VlcPlayerController controller) async {
  await controller.stop();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
}

/// The height of the 16:9 picture in the box: a phone narrower than the box
/// letterboxes it.
double _pictureHeight(WidgetTester tester) {
  final box = tester.getSize(find.byType(VlcPlayer));
  return math.min(box.height, box.width * 9 / 16);
}

/// Captures what the player shows until [shows] holds, failing after
/// [within]: a new look is drawn from the next line, and the first line after
/// a track is picked takes about a second.
Future<_Picture> _until(
  WidgetTester tester,
  String description,
  bool Function(_Picture shown) shows, {
  Duration within = const Duration(seconds: 4),
}) async {
  final watch = Stopwatch()..start();
  while (true) {
    final shown = await _shown();
    if (shows(shown)) {
      debugPrint(
        'subtitle look: $description after ${watch.elapsedMilliseconds} ms: '
        '$shown',
      );
      return shown;
    }
    if (watch.elapsed > within) {
      fail('Never showed $description: $shown');
    }
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// What the player shows, as Flutter draws it. Not libVLC's own snapshot,
/// which lacks the subtitles of a VideoToolbox picture on Darwin, and is a
/// copy of the window on Android, where Flutter draws on a surface of its own.
Future<_Picture> _shown() async {
  final boundary =
      _screen.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final picture = _Picture.read(image.width, image.height, rgba!);
  image.dispose();
  return picture;
}

/// Pixels of one colour, and the rows they span.
class _Ink {
  _Ink();

  int count = 0;
  int top = 1 << 30;
  int bottom = -1;

  int get rows => count == 0 ? 0 : bottom - top + 1;

  void add(int y) {
    count += 1;
    if (y < top) top = y;
    if (y > bottom) bottom = y;
  }

  @override
  String toString() => '$count px, rows $top..$bottom';
}

/// The white, red and blue in a snapshot: the grey picture has none.
class _Picture {
  _Picture(this.width, this.height);

  factory _Picture.read(int width, int height, ByteData rgba) {
    final picture = _Picture(width, height);
    for (var y = 0; y < height; y += 1) {
      for (var x = 0; x < width; x += 1) {
        final i = (y * width + x) * 4;
        final r = rgba.getUint8(i);
        final g = rgba.getUint8(i + 1);
        final b = rgba.getUint8(i + 2);
        if (r > 200 && g > 200 && b > 200) {
          picture.white.add(y);
        } else if (r > 150 && g < 90 && b < 90) {
          picture.red.add(y);
        } else if (b > 150 && r < 90 && g < 90) {
          picture.blue.add(y);
        }
      }
    }
    return picture;
  }

  final int width;
  final int height;
  final _Ink white = _Ink();
  final _Ink red = _Ink();
  final _Ink blue = _Ink();

  @override
  String toString() => '${width}x$height: white $white, red $red, blue $blue';
}
