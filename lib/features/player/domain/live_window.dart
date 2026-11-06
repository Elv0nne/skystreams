/// Where a live HLS or DASH stream can be moved: the stretch of the window
/// the server still lists that libVLC will play from (spec section 8).
///
/// libVLC 3 won't use the two oldest segments or the newest one, so the
/// stretch runs from about two target durations after the window's start to
/// one before its end. libVLC keeps nothing it has played: a step back is
/// fetched again from the window.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:vlc_player/vlc_player.dart';

/// The target duration to assume when the playlist's own can't be read.
const Duration kAssumedTargetDuration = Duration(seconds: 10);

/// A live window, and where playback is in it.
@immutable
class LiveWindow {
  const LiveWindow._({
    required this.length,
    required this.fraction,
    required this.segment,
    required this.liveDelay,
  });

  /// The window [value] reports, or null when there is none to move in: a
  /// feed that reports no window at all (TS, UDP), one whose window hasn't
  /// arrived yet, or one too short to leave a stretch between the segments
  /// libVLC won't use.
  ///
  /// [targetDuration] is the playlist's `#EXT-X-TARGETDURATION`, or null for
  /// [kAssumedTargetDuration]. [liveDelay] is how far behind the edge the
  /// stream is opened to play: see [atLive].
  static LiveWindow? of(
    VlcPlayerValue value, {
    Duration? targetDuration,
    Duration liveDelay = Duration.zero,
  }) {
    final fraction = value.positionFraction;
    if (fraction == null || value.duration <= Duration.zero) return null;
    final window = LiveWindow._(
      length: value.duration,
      fraction: fraction,
      segment: targetDuration ?? kAssumedTargetDuration,
      liveDelay: liveDelay,
    );
    return window.startFraction < window.endFraction ? window : null;
  }

  /// The window's length.
  final Duration length;

  /// Where playback is in it, 0..1.
  final double fraction;

  /// The playlist's target duration: about one segment.
  final Duration segment;

  /// How far behind the edge the stream is opened to play.
  final Duration liveDelay;

  /// The earliest place libVLC will play from: two segments in.
  double get startFraction => _share(segment * 2);

  /// The latest: one segment before the end, which is as close to live as
  /// libVLC 3 plays.
  double get endFraction => _share(length - segment);

  /// How far behind the live edge playback is.
  Duration get behind => length * (1 - fraction);

  /// Whether playback counts as live: see [countsAsLive].
  bool get atLive =>
      countsAsLive(behind, segment: segment, liveDelay: liveDelay);

  /// Whether [behind] the edge counts as live: at most three segments
  /// further back than the [liveDelay] the stream opens at. libVLC never
  /// plays the newest segment, starts the delay further back and rounds back
  /// to a segment's start (spec 1.9), and the edge itself is known to about a
  /// segment: a stream just joined, or just sent back to live, played 12-15 s
  /// behind on 4 s segments at an 8 s delay (SkyStream's QoE suite,
  /// 2026-10-13). Two segments from the edge alone called that behind.
  static bool countsAsLive(
    Duration behind, {
    required Duration segment,
    required Duration liveDelay,
  }) => behind <= liveDelay + segment * 3;

  /// [fraction] kept inside the stretch.
  double clamp(double fraction) =>
      fraction.clamp(startFraction, endFraction).toDouble();

  /// Where a step of [by] from [from] (this window's fraction by default)
  /// lands inside the stretch, or null when it doesn't move: a step back at
  /// the start, or forward at the end.
  double? step(Duration by, {double? from}) {
    final origin = from ?? fraction;
    final next = clamp(origin + _share(by));
    return (next - origin).abs() < _share(const Duration(milliseconds: 500))
        ? null
        : next;
  }

  /// The fraction of a place given in the stream's own timeline, as
  /// [VlcPlayerValue.position] and a seek's target are: [position] is where
  /// playback is now in that timeline.
  double fractionAt(Duration place, {required Duration position}) =>
      fraction + _share(place - position);

  double _share(Duration part) => part.inMilliseconds / length.inMilliseconds;
}

final RegExp _targetDuration = RegExp(
  r'^#EXT-X-TARGETDURATION:\s*(\d+)',
  multiLine: true,
);

/// A media playlist's `#EXT-X-TARGETDURATION`, or null when it has none.
Duration? targetDurationOf(String playlist) {
  final match = _targetDuration.firstMatch(playlist);
  final seconds = match == null ? 0 : int.parse(match.group(1)!);
  return seconds > 0 ? Duration(seconds: seconds) : null;
}

/// The first variant a master playlist lists, resolved against [base], or
/// null when [master] lists none.
Uri? firstVariantOf(String master, {required Uri base}) {
  final lines = const LineSplitter().convert(master);
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    for (final line in lines.skip(i + 1)) {
      final uri = line.trim();
      if (uri.isEmpty || uri.startsWith('#')) continue;
      return base.resolve(uri);
    }
  }
  return null;
}

/// How far behind live, as the clock shows it: "−0:42", with a real minus.
String behindLiveClock(Duration behind) {
  final seconds = behind.inSeconds;
  final hours = seconds ~/ 3600;
  final minutes = (seconds ~/ 60) % 60;
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '−$hours:${minutes.toString().padLeft(2, '0')}:$rest'
      : '−$minutes:$rest';
}
