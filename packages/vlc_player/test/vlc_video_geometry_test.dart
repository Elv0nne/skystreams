import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/src/vlc_video_geometry.dart';
import 'package:vlc_player/vlc_player.dart';

/// What libVLC is told about the fit, so it draws subtitles inside the part of
/// the picture the viewer sees.
///
/// libVLC draws subtitles into the picture. A fit that crops or stretches the
/// picture after that - Zoom cropping the bottom off, Stretch squashing it -
/// takes the subtitles with it: they grew with the zoom and fell off the
/// bottom of the screen. Told the same crop or aspect ratio, libVLC places and
/// sizes them for the picture that is actually shown.
void main() {
  const phone = Size(914, 411); // a 20:9 handset in landscape, in dp
  const hd = Size(1920, 1080);

  group('Fit', () {
    test('asks for nothing', () {
      expect(
        VlcVideoGeometry.forFit(
          VlcVideoFit.contain,
          viewSize: phone,
          videoSize: hd,
        ),
        VlcVideoGeometry.none,
      );
    });
  });

  group('Zoom', () {
    test('crops to the shape of the view', () {
      expect(
        VlcVideoGeometry.forFit(
          VlcVideoFit.cover,
          viewSize: phone,
          videoSize: hd,
        ),
        const VlcVideoGeometry(crop: '914:411'),
      );
    });

    test('reduces the ratio, which is all libVLC reads', () {
      expect(
        VlcVideoGeometry.forFit(
          VlcVideoFit.cover,
          viewSize: const Size(1200, 540),
          videoSize: hd,
        ).crop,
        '20:9',
      );
    });

    test('asks for nothing when the video is already the view\'s shape', () {
      expect(
        VlcVideoGeometry.forFit(
          VlcVideoFit.cover,
          viewSize: const Size(960, 540),
          videoSize: hd,
        ),
        VlcVideoGeometry.none,
      );
    });

    test('does not wait for the video size, which is only a shortcut', () {
      expect(
        VlcVideoGeometry.forFit(VlcVideoFit.cover, viewSize: phone),
        const VlcVideoGeometry(crop: '914:411'),
      );
    });
  });

  group('Stretch', () {
    test('sets the aspect ratio to the view\'s', () {
      expect(
        VlcVideoGeometry.forFit(
          VlcVideoFit.fill,
          viewSize: phone,
          videoSize: hd,
        ),
        const VlcVideoGeometry(aspectRatio: '914:411'),
      );
    });

    test('asks for nothing when the video is already the view\'s shape', () {
      expect(
        VlcVideoGeometry.forFit(
          VlcVideoFit.fill,
          viewSize: const Size(640, 360),
          videoSize: hd,
        ),
        VlcVideoGeometry.none,
      );
    });
  });

  group('Original', () {
    test('crops the middle of a video bigger than the view', () {
      // One video pixel to one logical pixel, centred: the 914x411 middle of
      // the 1920x1080 frame.
      expect(
        VlcVideoGeometry.forFit(
          VlcVideoFit.none,
          viewSize: phone,
          videoSize: hd,
        ),
        const VlcVideoGeometry(crop: '914x411+503+334'),
      );
    });

    test('crops only the axis that overflows', () {
      expect(
        VlcVideoGeometry.forFit(
          VlcVideoFit.none,
          viewSize: const Size(640, 900),
          videoSize: const Size(1280, 720),
        ).crop,
        '640x720+320+0',
      );
    });

    test('asks for nothing when the whole video fits', () {
      expect(
        VlcVideoGeometry.forFit(
          VlcVideoFit.none,
          viewSize: phone,
          videoSize: const Size(640, 360),
        ),
        VlcVideoGeometry.none,
      );
    });

    test('asks for nothing until the video size is known', () {
      expect(
        VlcVideoGeometry.forFit(VlcVideoFit.none, viewSize: phone),
        VlcVideoGeometry.none,
      );
    });
  });

  test('a view with no area asks for nothing', () {
    for (final fit in VlcVideoFit.values) {
      expect(
        VlcVideoGeometry.forFit(fit, viewSize: Size.zero, videoSize: hd),
        VlcVideoGeometry.none,
        reason: fit.name,
      );
      expect(
        VlcVideoGeometry.forFit(
          fit,
          viewSize: const Size(double.infinity, 400),
          videoSize: hd,
        ),
        VlcVideoGeometry.none,
        reason: '${fit.name}, unbounded',
      );
    }
  });
}
