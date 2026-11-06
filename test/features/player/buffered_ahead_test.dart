import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/buffered_ahead.dart';

/// The estimate behind the buffered segment of the seek bar.
///
/// libVLC 3 publishes no buffered range, so this is derived from byte
/// counters. Every rule here exists because the alternative is a bar that
/// confidently shows a wrong number, which is worse than a bar that shows
/// nothing - a viewer who learns the buffered line lies stops reading it.
void main() {
  group('the ordinary case', () {
    test('read-ahead is bytes fetched over the rate they are consumed at', () {
      // 1 MB/s consumed, 5 MB sitting ahead of the demuxer: five seconds.
      final ahead = bufferedAhead(
        readBytes: 15000000,
        demuxReadBytes: 10000000,
        previousDemuxReadBytes: 9000000,
        sampleInterval: const Duration(seconds: 1),
      );

      expect(ahead, isNotNull);
      expect(ahead!.inSeconds, 5);
    });

    test('a slower interval measures the same rate', () {
      // Same 1 MB/s, sampled over two seconds instead of one.
      final ahead = bufferedAhead(
        readBytes: 15000000,
        demuxReadBytes: 10000000,
        previousDemuxReadBytes: 8000000,
        sampleInterval: const Duration(seconds: 2),
      );

      expect(ahead!.inSeconds, 5);
    });
  });

  group('refusing to guess', () {
    test('a demuxer that consumed nothing gives no rate', () {
      // Paused or stalled. Dividing by this would be infinity.
      expect(
        bufferedAhead(
          readBytes: 15000000,
          demuxReadBytes: 10000000,
          previousDemuxReadBytes: 10000000,
          sampleInterval: const Duration(seconds: 1),
        ),
        isNull,
      );
    });

    test('counters that reset under us are refused, not believed', () {
      // A reopen resets them natively, and one can land before the other.
      expect(
        bufferedAhead(
          readBytes: 500,
          demuxReadBytes: 10000000,
          previousDemuxReadBytes: 12000000,
          sampleInterval: const Duration(seconds: 1),
        ),
        isNull,
      );
    });

    test('an absurd read-ahead is an artefact, not a big buffer', () {
      // 1 KB/s consumed with 1 GB ahead is eleven days. Something is wrong -
      // most likely the demuxer barely moved - and the bar must not say so.
      expect(
        bufferedAhead(
          readBytes: 1000000000,
          demuxReadBytes: 1000,
          previousDemuxReadBytes: 0,
          sampleInterval: const Duration(seconds: 1),
        ),
        isNull,
      );
    });

    test('a zero interval has no rate to offer', () {
      expect(
        bufferedAhead(
          readBytes: 15000000,
          demuxReadBytes: 10000000,
          previousDemuxReadBytes: 9000000,
          sampleInterval: Duration.zero,
        ),
        isNull,
      );
    });

    test('the demuxer caught up, which is zero ahead and not unknown', () {
      // A real answer: nothing is buffered. Distinct from null, because the
      // bar should show an empty buffer rather than hide the segment.
      expect(
        bufferedAhead(
          readBytes: 10000000,
          demuxReadBytes: 10000000,
          previousDemuxReadBytes: 9000000,
          sampleInterval: const Duration(seconds: 1),
        ),
        Duration.zero,
      );
    });
  });

  group('a seek, which is where the counters part company', _seekTests);
  group('the numbers a real engine gives', _measuredTests);

  group('turning it into a bar', () {
    test('the segment ends where the buffer runs out', () {
      final fraction = bufferedFraction(
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 100),
        ahead: const Duration(minutes: 5),
      );

      expect(fraction, closeTo(0.15, 1e-9));
    });

    test('a buffer past the end of the film stops at the end', () {
      final fraction = bufferedFraction(
        position: const Duration(minutes: 99),
        duration: const Duration(minutes: 100),
        ahead: const Duration(minutes: 5),
      );

      expect(fraction, 1.0);
    });

    test('a live stream has no length to measure against', () {
      expect(
        bufferedFraction(
          position: const Duration(minutes: 10),
          duration: Duration.zero,
          ahead: const Duration(minutes: 5),
        ),
        isNull,
      );
    });

    test('no estimate draws no segment', () {
      expect(
        bufferedFraction(
          position: const Duration(minutes: 10),
          duration: const Duration(minutes: 100),
          ahead: null,
        ),
        isNull,
      );
    });
  });
}

/// What a seek does to the two counters, and why the band used to vanish.
///
/// `readBytes - demuxReadBytes` is only a buffer while every byte the access
/// reads is eventually demuxed. A seek breaks that: libVLC's prefetch filter
/// empties its window when the target lands past the end of it, and those
/// bytes are counted as read and never as demuxed. The gap stays that much
/// too wide for the rest of the session.
///
/// The numbers below are a stream running at 1 MB/s, sampled once a second,
/// which is what the player actually does.
void _seekTests() {
  const second = Duration(seconds: 1);
  const rate = 1000000; // bytes per second, and so bytes per sample

  /// Drives the estimator through [samples] seconds of ordinary playback,
  /// keeping a full [bufferBytes] buffer ahead of the demuxer.
  ({int read, int demux, Duration position, Duration at, int seeks}) play(
    BufferedAheadEstimator estimator, {
    required int read,
    required int demux,
    required Duration position,
    required Duration at,
    required int seeks,
    required int bufferBytes,
    int samples = 1,
  }) {
    for (var i = 0; i < samples; i++) {
      demux += rate;
      read = demux + bufferBytes;
      position += second;
      at += second;
      estimator.sample(
        readBytes: read,
        demuxReadBytes: demux,
        position: position,
        at: at,
        seekRequests: seeks,
      );
    }
    return (read: read, demux: demux, position: position, at: at, seeks: seeks);
  }

  test('an untouched stream reports the buffer it holds', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 4,
    );

    final ahead = estimator.sample(
      readBytes: s.demux + rate + 8 * rate,
      demuxReadBytes: s.demux + rate,
      position: s.position + second,
      at: s.at + second,
      seekRequests: 0,
    );

    expect(ahead, isNotNull);
    expect(ahead!.inSeconds, 8);
    expect(estimator.strandedBytes, 0);
  });

  test('a forward seek past the buffer empties it, and says so', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 4,
    );

    // Ten minutes forward. The prefetch window is discarded: the access
    // starts again at the new offset, so the demuxer gets almost nothing this
    // second and the 8 MB that was buffered is never demuxed.
    final ahead = estimator.sample(
      readBytes: s.read + 200000,
      demuxReadBytes: s.demux + 100000,
      position: s.position + const Duration(minutes: 10),
      at: s.at + second,
      seekRequests: 1,
    );

    expect(
      ahead,
      Duration.zero,
      reason: 'the buffer really is empty, and an empty buffer is a fact '
          'rather than the "I do not know" that hides the band',
    );
  });

  test('and the band comes back as the buffer refills', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 4,
    );

    var read = s.read + 200000;
    var demux = s.demux + 100000;
    var position = s.position + const Duration(minutes: 10);
    var at = s.at + second;
    estimator.sample(
      readBytes: read,
      demuxReadBytes: demux,
      position: position,
      at: at,
      seekRequests: 1,
    );

    // Three seconds of refilling: the demuxer consumes its 1 MB a second and
    // the access runs 3 MB ahead of it.
    //
    // `readBytes` is cumulative and still carries the bytes the seek stranded,
    // so the gap between the counters is those plus the 3 MB actually held.
    // Writing it as a bare 3 MB is the mistake the correction exists to stop
    // anyone making, including here.
    final stranded = estimator.strandedBytes;
    for (var i = 0; i < 3; i++) {
      demux += rate;
      read = demux + stranded + 3 * rate;
      position += second;
      at += second;
    }
    final ahead = estimator.sample(
      readBytes: read,
      demuxReadBytes: demux,
      position: position,
      at: at,
      seekRequests: 1,
    );

    expect(ahead, isNotNull, reason: 'this is the regression: it used to be '
        'suppressed as an absurd read-ahead and the band stayed blank');
    expect(ahead!.inSeconds, closeTo(3, 1));
  });

  test('the old arithmetic would have claimed ten minutes of buffer', () {
    // The same sample, read the way it was before stranded bytes were
    // accounted for: the 8 MB discarded window plus the 3 MB really held,
    // over a 1 MB/s rate. Eleven seconds claimed for three seconds held - and
    // it compounds with every seek until it trips the cap and the band
    // disappears for good.
    final naive = bufferedAhead(
      readBytes: 11 * rate,
      demuxReadBytes: 0,
      previousDemuxReadBytes: -rate,
      sampleInterval: second,
    );

    expect(naive!.inSeconds, 11);

    final corrected = bufferedAhead(
      readBytes: 11 * rate,
      demuxReadBytes: 0,
      previousDemuxReadBytes: -rate,
      sampleInterval: second,
      strandedBytes: 8 * rate,
    );

    expect(corrected!.inSeconds, 3);
  });

  test('a seek inside the buffer spends part of it, not all of it', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 30 * rate,
      samples: 4,
    );

    // Ten seconds forward with thirty buffered: the window is not discarded,
    // the demuxer just repositions over ten seconds of it. Nine of those are
    // skipped and one is the second that elapsed.
    final ahead = estimator.sample(
      readBytes: s.read + rate,
      demuxReadBytes: s.demux + rate,
      position: s.position + const Duration(seconds: 10),
      at: s.at + second,
      seekRequests: 1,
    );

    expect(ahead, isNotNull);
    expect(
      ahead!.inSeconds,
      closeTo(21, 1),
      reason: 'thirty seconds held, nine of them skipped past',
    );
  });

  test('scrubbing repeatedly does not accumulate a phantom buffer', () {
    final estimator = BufferedAheadEstimator();
    var read = 0;
    var demux = 0;
    var position = Duration.zero;
    var at = Duration.zero;

    for (var seek = 1; seek <= 5; seek++) {
      // Settle with 8 MB buffered.
      for (var i = 0; i < 3; i++) {
        demux += rate;
        read = demux + 8 * rate;
        position += second;
        at += second;
        estimator.sample(
          readBytes: read,
          demuxReadBytes: demux,
          position: position,
          at: at,
          seekRequests: seek - 1,
        );
      }
      // Scrub five minutes on, discarding the window.
      demux += 100000;
      read += 200000;
      position += const Duration(minutes: 5);
      at += second;
      estimator.sample(
        readBytes: read,
        demuxReadBytes: demux,
        position: position,
        at: at,
        seekRequests: seek,
      );
    }

    // Refill to a known 4 MB and read it back.
    for (var i = 0; i < 3; i++) {
      demux += rate;
      read = demux + estimator.strandedBytes + 4 * rate;
      position += second;
      at += second;
    }
    final ahead = estimator.sample(
      readBytes: read,
      demuxReadBytes: demux,
      position: position,
      at: at,
      seekRequests: 5,
    );

    expect(ahead, isNotNull, reason: 'five seeks used to be five times the '
        'phantom, and the band never returned');
    expect(ahead!.inSeconds, closeTo(4, 1));
  });

  // libVLC's prefetch keeps next to nothing it has already handed on - unread
  // data takes precedence once the buffer is full - so a seek behind the read
  // point empties it, forward part included, and the access starts again from
  // the new place. Counting those bytes as still held is what made the band
  // vanish for good after a few steps back.
  test('a backward seek strands the whole buffer', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: const Duration(minutes: 5),
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 4,
    );

    // Thirty seconds back. The access re-reads 1 MB from the new place and
    // the demuxer takes all of it.
    final ahead = estimator.sample(
      readBytes: s.read + rate,
      demuxReadBytes: s.demux + rate,
      position: s.position - const Duration(seconds: 30),
      at: s.at + second,
      seekRequests: 1,
    );

    expect(estimator.strandedBytes, 8 * rate);
    expect(ahead, Duration.zero, reason: 'refilling, not eight seconds held');
  });

  test('stepping back again and again leaves the band standing', () {
    final estimator = BufferedAheadEstimator();
    var demux = 0;
    // Everything the access read that libVLC then threw away. `readBytes` is
    // cumulative, so it carries all of it for the rest of the session.
    var discarded = 0;
    var position = const Duration(minutes: 30);
    var at = Duration.zero;
    const held = 240 * rate; // four minutes

    Duration? sample({required int buffer, required int seeks}) =>
        estimator.sample(
          readBytes: demux + discarded + buffer,
          demuxReadBytes: demux,
          position: position,
          at: at,
          seekRequests: seeks,
        );

    for (var seek = 1; seek <= 5; seek++) {
      // Three seconds of playback with the buffer full.
      for (var i = 0; i < 3; i++) {
        demux += rate;
        position += second;
        at += second;
        sample(buffer: held, seeks: seek - 1);
      }
      // Ten seconds back: the whole buffer goes, and the access re-reads
      // 1 MB from the new place, which the demuxer takes.
      discarded += held;
      demux += rate;
      position -= const Duration(seconds: 10);
      at += second;
      sample(buffer: 0, seeks: seek);
    }

    // Refill to a known 4 MB and read it back.
    for (var i = 0; i < 3; i++) {
      demux += rate;
      position += second;
      at += second;
    }
    final ahead = sample(buffer: 4 * rate, seeks: 5);

    expect(
      ahead,
      isNotNull,
      reason:
          'five buffers thrown away read as twenty minutes held, past the '
          'cap, and the band never returned',
    );
    expect(ahead!.inSeconds, closeTo(4, 1));
  });

  test('a media change forgets the correction but keeps the rate baseline', () {
    final estimator = BufferedAheadEstimator();
    final s = play(
      estimator,
      read: 0,
      demux: 0,
      position: Duration.zero,
      at: Duration.zero,
      seeks: 0,
      bufferBytes: 8 * rate,
      samples: 3,
    );
    estimator.sample(
      readBytes: s.read,
      demuxReadBytes: s.demux + 100000,
      position: s.position + const Duration(minutes: 10),
      at: s.at + second,
      seekRequests: 1,
    );
    expect(estimator.strandedBytes, greaterThan(0));

    estimator.noteMediaChanged();
    expect(estimator.strandedBytes, 0);

    // The baseline survives, because this is called on the way *into* a media
    // as well - dropping it there would cost a second of blank band at the
    // start of every stream. Counters that really restarted invalidate it on
    // their own: the delta goes negative and that is already refused.
    expect(
      estimator.sample(
        readBytes: 1000,
        demuxReadBytes: 500,
        position: Duration.zero,
        at: s.at + const Duration(seconds: 2),
        seekRequests: 1,
      ),
      isNull,
      reason: 'a demux counter that went backwards is a reset, not a rate',
    );
  });
}

/// Figures measured on the Android TV emulator through a logging proxy: a
/// 3 Mbit/s stream the demuxer reads at about 0.4 MB/s, a 128 MiB prefetch
/// buffer that fills to about 137 MB between the counters, a demuxer that
/// takes 2 to 2.5 MB in the second after a seek while it prerolls and refills
/// its three seconds, and a refill from the network at about 7 MB/s.
void _measuredTests() {
  const second = Duration(seconds: 1);
  const rate = 400000;
  const held = 137000000;

  /// Plays [samples] ordinary seconds with [held] buffered, starting from
  /// what [start] says, and returns where it got to.
  ({int read, int demux, Duration position, Duration at}) steady(
    BufferedAheadEstimator estimator, {
    int read = 0,
    int demux = 0,
    Duration position = const Duration(minutes: 2),
    Duration at = Duration.zero,
    int seeks = 0,
    int samples = 8,
    int? capacity,
  }) {
    for (var i = 0; i < samples; i++) {
      demux += rate;
      read = demux + held;
      position += second;
      at += second;
      estimator.sample(
        readBytes: read,
        demuxReadBytes: demux,
        position: position,
        at: at,
        seekRequests: seeks,
        capacityBytes: capacity,
      );
    }
    return (read: read, demux: demux, position: position, at: at);
  }

  test('a skip is converted at the rate playback ran at, not the burst after '
      'it', () {
    // Ten seconds forward inside the buffer. The demuxer skips 4 MB it will
    // never read and takes 2.5 MB of burst; the prefetch reads the same back
    // in. Converted at the burst, the ten seconds came to 25 MB, and the band
    // read 47 seconds for a buffer of nearly six minutes.
    final estimator = BufferedAheadEstimator();
    final s = steady(estimator);

    final ahead = estimator.sample(
      readBytes: s.read + 6500000,
      demuxReadBytes: s.demux + 2500000,
      position: s.position + const Duration(seconds: 11),
      at: s.at + second,
      seekRequests: 1,
    );

    expect(estimator.strandedBytes, closeTo(4000000, 400000));
    expect(ahead!.inSeconds, closeTo(held / rate, held / rate / 10));
  });

  test('the band never claims more than the buffer can hold', () {
    // A step forward whose keyframe fell behind libVLC's read point: it threw
    // the whole buffer away and filled it again from the network, and a
    // forward skip only ever strands the seconds skipped. The rest was
    // counted twice, and a few seconds later the band claimed more than ten
    // minutes and disappeared.
    final estimator = BufferedAheadEstimator();
    final s = steady(estimator, capacity: held);
    var read = s.read;
    var demux = s.demux;
    var position = s.position + const Duration(seconds: 11);
    var at = s.at + second;
    read += 7000000;
    demux += 2500000;
    estimator.sample(
      readBytes: read,
      demuxReadBytes: demux,
      position: position,
      at: at,
      seekRequests: 1,
      capacityBytes: held,
    );

    Duration? ahead;
    for (var i = 0; i < 25; i++) {
      demux += rate;
      // Refilling at 7 MB/s until the buffer is full again.
      read = math.min(read + 7000000, demux + held + held);
      position += second;
      at += second;
      ahead = estimator.sample(
        readBytes: read,
        demuxReadBytes: demux,
        position: position,
        at: at,
        seekRequests: 1,
        capacityBytes: held,
      );
    }

    expect(ahead, isNotNull, reason: 'past the cap, the band disappeared');
    expect(ahead!.inSeconds, lessThanOrEqualTo(held ~/ rate));
  });

  test('the band holds steady while the demuxer reads in bursts', () {
    // It reads a cluster at a time, so a second's consumption swings between
    // 0.3 and 0.42 MB, and the band jumped between 5:24 and 7:40 with it.
    final estimator = BufferedAheadEstimator();
    var demux = 0;
    var position = const Duration(minutes: 2);
    var at = Duration.zero;
    final readings = <int>[];
    for (var i = 0; i < 20; i++) {
      demux += i.isEven ? 300000 : 420000;
      position += second;
      at += second;
      final ahead = estimator.sample(
        readBytes: demux + held,
        demuxReadBytes: demux,
        position: position,
        at: at,
        seekRequests: 0,
      );
      if (i >= 10 && ahead != null) readings.add(ahead.inSeconds);
    }

    expect(readings, hasLength(10));
    final spread = readings.reduce(math.max) - readings.reduce(math.min);
    expect(spread, lessThan(30), reason: 'seconds, on about six minutes');
  });
}
