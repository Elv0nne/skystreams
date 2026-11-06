import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/live_window.dart';
import 'package:vlc_player/vlc_player.dart';

/// A live HLS value: a [lengthS]-second window, [fraction] of the way in.
VlcPlayerValue live({required int lengthS, double? fraction}) => VlcPlayerValue(
  duration: Duration(seconds: lengthS),
  position: const Duration(seconds: 4000),
  positionFraction: fraction,
  isSeekable: true,
);

const fourSeconds = Duration(seconds: 4);

void main() {
  // Review Focus 4: no window, a late one, or one too short.
  group('no window to move in', () {
    test('a feed that reports none: TS, UDP', () {
      expect(LiveWindow.of(const VlcPlayerValue(isLive: true)), isNull);
    });

    test('a window whose place has not arrived yet', () {
      expect(LiveWindow.of(live(lengthS: 120)), isNull);
    });

    test('a length that has not arrived yet', () {
      expect(LiveWindow.of(live(lengthS: 0, fraction: 0.5)), isNull);
    });

    test('a window too short to leave a stretch', () {
      // Three 4 s segments: two at the start and one at the end are libVLC's.
      expect(
        LiveWindow.of(
          live(lengthS: 12, fraction: 0.5),
          targetDuration: fourSeconds,
        ),
        isNull,
      );
    });
  });

  group('a two-minute window of 4 s segments', () {
    final window = LiveWindow.of(
      live(lengthS: 120, fraction: 0.75),
      targetDuration: fourSeconds,
    )!;

    test('can be moved in from two segments in to one before the end', () {
      expect(window.startFraction, closeTo(8 / 120, 1e-9));
      expect(window.endFraction, closeTo(116 / 120, 1e-9));
    });

    test('says how far behind live playback is', () {
      expect(window.behind, const Duration(seconds: 30));
      expect(window.atLive, isFalse);
    });

    test('is live within three segments of the edge, with no delay', () {
      final near = LiveWindow.of(
        live(lengthS: 120, fraction: 0.94),
        targetDuration: fourSeconds,
      )!;
      expect(near.atLive, isTrue);
    });

    test('counts as live within three segments of its live delay', () {
      // libVLC starts a live stream its live delay behind the edge, a
      // segment more, rounded to a segment: 12 s behind on a 24 s window of
      // 4 s segments at 8 s. That is live; 21.6 s is not.
      LiveWindow at(double fraction) => LiveWindow.of(
        live(lengthS: 24, fraction: fraction),
        targetDuration: fourSeconds,
        liveDelay: const Duration(seconds: 8),
      )!;
      expect(at(0.48).atLive, isTrue);
      expect(at(0.1).atLive, isFalse);
    });

    test('steps 10 s, and the step is kept inside the stretch', () {
      expect(
        window.step(const Duration(seconds: -10)),
        closeTo(0.75 - 10 / 120, 1e-9),
      );
      expect(
        window.step(const Duration(seconds: 60)),
        closeTo(116 / 120, 1e-9),
      );
    });

    test('a step back at the start of the stretch does nothing', () {
      expect(
        window.step(const Duration(seconds: -10), from: window.startFraction),
        isNull,
      );
    });

    test('places a seek target given in the stream timeline', () {
      expect(
        window.fractionAt(
          const Duration(seconds: 3970),
          position: const Duration(seconds: 4000),
        ),
        closeTo(0.5, 1e-9),
      );
    });
  });

  test('a window with no target duration assumes 10 s segments', () {
    final window = LiveWindow.of(live(lengthS: 120, fraction: 0.5))!;
    expect(window.segment, kAssumedTargetDuration);
    expect(window.startFraction, closeTo(20 / 120, 1e-9));
  });

  test("a 24 s window of 4 s segments still has a little room", () {
    final window = LiveWindow.of(
      live(lengthS: 24, fraction: 0.6),
      targetDuration: fourSeconds,
    )!;
    expect(window.startFraction, closeTo(8 / 24, 1e-9));
    expect(window.endFraction, closeTo(20 / 24, 1e-9));
    expect(window.step(const Duration(seconds: -10)), closeTo(8 / 24, 1e-9));
  });

  test("the playlist's target duration", () {
    expect(
      targetDurationOf('#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n'),
      const Duration(seconds: 6),
    );
    expect(
      targetDurationOf('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\na.m3u8'),
      isNull,
    );
  });

  test("a master's first variant, resolved against its address", () {
    expect(
      firstVariantOf(
        '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=6400000\nv1080/index.m3u8\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=3600000\nv720/index.m3u8\n',
        base: Uri.parse('https://cdn.test/live/master.m3u8'),
      ),
      Uri.parse('https://cdn.test/live/v1080/index.m3u8'),
    );
    expect(
      firstVariantOf(
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\nseg1.ts\n',
        base: Uri.parse('https://cdn.test/live/index.m3u8'),
      ),
      isNull,
    );
  });

  test('the clock says how far behind live, with a real minus', () {
    expect(behindLiveClock(const Duration(seconds: 42)), '−0:42');
    expect(behindLiveClock(const Duration(minutes: 3, seconds: 5)), '−3:05');
    expect(
      behindLiveClock(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '−1:02:03',
    );
  });
}
