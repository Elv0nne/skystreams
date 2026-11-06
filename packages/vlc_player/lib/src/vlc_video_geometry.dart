import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'vlc_video_fit.dart';

/// The crop and aspect ratio libVLC is told for the fit on screen.
///
/// libVLC draws subtitles into the picture. A fit that crops or stretches the
/// picture after that takes the subtitles with it: Zoom enlarged them and cut
/// them off along the bottom edge, and on Android, where libvlc-android sizes
/// the view from a report only its native display sends, Zoom and Stretch did
/// nothing at all on hardware-decoded video. Told the crop or aspect ratio
/// itself, libVLC produces - or at least lays its subtitles out for - the
/// picture that is actually shown, so they stay inside it at their usual size.
///
/// Internal to the package: the `VlcPlayer` widget derives it from its fit and
/// its own size, and the controller hands it to the native player - on
/// Android's platform view, the one renderer where libVLC shapes the picture
/// itself. Everywhere else Flutter fits a whole picture.
@immutable
class VlcVideoGeometry {
  const VlcVideoGeometry({this.crop, this.aspectRatio});

  /// libVLC's own picture, uncropped and at its own aspect ratio.
  static const VlcVideoGeometry none = VlcVideoGeometry();

  /// A libVLC crop geometry: `W:H` crops the middle of the picture to that
  /// shape, `WxH+X+Y` to that region in video pixels. Null for no crop.
  final String? crop;

  /// A libVLC aspect ratio, `W:H`. Null for the video's own.
  final String? aspectRatio;

  /// The geometry under which libVLC's picture is what [fit] shows of a
  /// [videoSize] video in a [viewSize] view.
  ///
  /// * Fit shows the whole picture: nothing to tell.
  /// * Zoom shows the middle of it, cut to the view's shape.
  /// * Stretch shows all of it at the view's shape.
  /// * Original shows one video pixel per logical pixel, centred, which on a
  ///   video bigger than the view is its middle.
  ///
  /// [videoSize] is only a shortcut for Zoom and Stretch - a video already the
  /// view's shape needs neither - but Original needs it to know the middle.
  static VlcVideoGeometry forFit(
    VlcVideoFit fit, {
    required Size viewSize,
    Size? videoSize,
  }) {
    if (!viewSize.isFinite || viewSize.isEmpty) return none;
    switch (fit) {
      case VlcVideoFit.contain:
        return none;
      case VlcVideoFit.cover:
        if (_sameShape(viewSize, videoSize)) return none;
        return VlcVideoGeometry(crop: _ratio(viewSize));
      case VlcVideoFit.fill:
        if (_sameShape(viewSize, videoSize)) return none;
        return VlcVideoGeometry(aspectRatio: _ratio(viewSize));
      case VlcVideoFit.none:
        final video = videoSize;
        if (video == null || video.isEmpty) return none;
        final width = math.min(video.width, viewSize.width).round();
        final height = math.min(video.height, viewSize.height).round();
        if (width >= video.width.round() && height >= video.height.round()) {
          return none;
        }
        final x = ((video.width - width) / 2).floor();
        final y = ((video.height - height) / 2).floor();
        return VlcVideoGeometry(crop: '${width}x$height+$x+$y');
    }
  }

  /// Within a percent: a rounding difference between the two is not a reason
  /// to have libVLC crop or rescale anything.
  static bool _sameShape(Size view, Size? video) {
    if (video == null || video.isEmpty) return false;
    final viewShape = view.width / view.height;
    final videoShape = video.width / video.height;
    return (viewShape - videoShape).abs() / videoShape < 0.01;
  }

  /// The shape of [size] as the smallest whole `W:H`.
  static String _ratio(Size size) {
    final width = size.width.round();
    final height = size.height.round();
    final divisor = _gcd(width, height);
    return '${width ~/ divisor}:${height ~/ divisor}';
  }

  static int _gcd(int a, int b) => b == 0 ? (a == 0 ? 1 : a) : _gcd(b, a % b);

  @override
  bool operator ==(Object other) =>
      other is VlcVideoGeometry &&
      other.crop == crop &&
      other.aspectRatio == aspectRatio;

  @override
  int get hashCode => Object.hash(crop, aspectRatio);

  @override
  String toString() =>
      'VlcVideoGeometry(crop: $crop, aspectRatio: $aspectRatio)';
}
