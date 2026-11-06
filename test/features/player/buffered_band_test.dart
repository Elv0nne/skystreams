import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';
import 'package:skystream/features/player/presentation/widgets/player_stream_widgets.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// The seek bar's buffered band, end to end on the real screen.
///
/// The band itself was already drawn; what it never had was a number, because
/// libVLC 3 publishes no buffered range and its buffering percentage sits at
/// 100 through healthy playback. The figure is derived from the byte counters
/// on the stats sample the video-health watchdog already takes, so these tests
/// drive real snapshots and read what the scrubber was handed.
void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  /// What the scrubber is currently told to shade.
  double bandRatio(WidgetTester tester) => tester
      .widget<PlayerScrubber>(find.byType(PlayerScrubber, skipOffstage: false))
      .bufferRatio;

  /// A stats reading with the counters the estimate reads.
  void stats({required int read, required int demux}) {
    engine.mediaStats = <String, Object?>{
      'available': true,
      'displayedPictures': 100,
      'lostPictures': 0,
      'readBytes': read,
      'demuxReadBytes': demux,
    };
  }

  testWidgets('nothing is shaded before there is anything to say', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);
    await sendEvent(tester, engine.event(<String, Object?>{'duration': 600000}));
    await settle(tester);

    expect(bandRatio(tester), 0);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('two samples give the band a width', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);

    // A ten-minute film, one minute in.
    Future<void> tick(int positionMs) => sendEvent(
      tester,
      engine.event(<String, Object?>{
        'duration': 600000,
        'position': positionMs,
      }),
    );

    await tick(60000);
    await settle(tester);

    // First sample is the datum - a rate needs two readings, so the band
    // stays empty here however inviting the numbers look.
    //
    // Two ticks, not one: the sampler asks on one and the answer lands on the
    // next, so a single pump delivers whatever the engine held *before* this.
    // The datum has to be a real reading - an unavailable sample carries
    // zeros rather than counters, and taking a baseline from those would put
    // a stream's whole cumulative total into the first rate.
    stats(read: 11000000, demux: 10000000);
    for (var i = 0; i < 2; i++) {
      // The position has to move for a health sample to be taken at all - a
      // frozen clock is the stall watchdog's business, not this one's.
      await tick(60100 + i * 100);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
    }
    expect(bandRatio(tester), 0, reason: 'one reading is not a rate');

    // Second sample: 1 MB/s consumed, 5 MB fetched ahead - five seconds. One
    // minute in, that is 65s of a 600s film.
    stats(read: 16000000, demux: 11000000);
    await tick(61000);
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);

    final ratio = bandRatio(tester);
    expect(ratio, greaterThan(0), reason: 'the band should have a width now');
    expect(ratio, closeTo(66 / 600, 0.02));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a step back is measured from where the viewer sent playback',
    variant: texturePlatform,
    (tester) async {
      // A backend keeps publishing the old position, still ticking, until the
      // seek takes. Measured from that, a step back looks like playback carrying
      // on, and the band went on claiming the buffer libVLC throws away on
      // every seek backwards.
      await pumpPlayer(tester);
      final controller = tester
          .widget<VlcPlayer>(find.byType(VlcPlayer, skipOffstage: false))
          .controller;
      Future<void> tick(int positionMs) => sendEvent(
        tester,
        engine.event(<String, Object?>{
          'duration': 600000,
          'position': positionMs,
        }),
      );

      // One minute in, 1 MB/s, thirty seconds buffered.
      await tick(60000);
      await settle(tester);
      var demux = 10000000;
      var position = 60000;
      for (var i = 0; i < 4; i++) {
        demux += 1000000;
        position += 1000;
        stats(read: demux + 30000000, demux: demux);
        await tick(position);
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect(
        bandRatio(tester),
        greaterThan(80 / 600),
        reason: 'a band to lose',
      );

      // Thirty seconds back, and the old position carries on ticking. libVLC
      // has thrown the thirty seconds away and is reading again from 0:34.
      await controller.seekTo(const Duration(seconds: 34));
      const thrownAway = 30000000;
      for (var i = 0; i < 3; i++) {
        demux += 1000000;
        position += 1000;
        stats(read: demux + thrownAway, demux: demux);
        await tick(position);
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }

      expect(
        bandRatio(tester),
        lessThan(40 / 600),
        reason: 'nothing is buffered past the target yet',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the band stops at what the buffer can hold',
    variant: texturePlatform,
    (tester) async {
      // A forward seek that emptied libVLC's buffer strands only the seconds
      // it skipped, so the counters go on showing the old buffer as well as
      // the new one. Past what the buffer can hold, the band claimed more
      // than ten minutes and disappeared.
      await pumpPlayer(tester);
      Future<void> tick(int positionMs) => sendEvent(
        tester,
        engine.event(<String, Object?>{
          'duration': 3600000,
          'position': positionMs,
        }),
      );

      await tick(60000);
      await settle(tester);
      var demux = 10000000;
      var position = 60000;
      for (var i = 0; i < 5; i++) {
        demux += 1000000;
        position += 1000;
        stats(read: demux + 1000000000, demux: demux);
        await tick(position);
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }

      // The read-ahead the buffer rule gives the harness's film, 172 MB, at
      // the rate the sampler measured - 1 MB/s, or half that where a reading
      // lands a tick late.
      const capacity = 172 * 1048576;
      expect(bandRatio(tester), greaterThan(0), reason: 'not blank');
      expect(
        bandRatio(tester),
        lessThanOrEqualTo(
          (position / 1000 + 2 * capacity / 1000000 + 1) / 3600,
        ),
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the band empties rather than freezing when the estimate goes', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);
    Future<void> tick(int positionMs) => sendEvent(
      tester,
      engine.event(<String, Object?>{
        'duration': 600000,
        'position': positionMs,
      }),
    );

    await tick(60000);
    await settle(tester);
    // Two ticks for the datum, for the round trip described below.
    stats(read: 11000000, demux: 10000000);
    for (var i = 0; i < 2; i++) {
      await tick(60100 + i * 100);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
    }
    // Tick until the reading lands. The sampler asks on one tick and the
    // answer arrives on the next, and how many ticks that works out at is the
    // harness's business rather than this test's - what is being tested is
    // what happens to a band that HAS a width once the estimate goes.
    stats(read: 16000000, demux: 11000000);
    for (var i = 0; i < 4 && bandRatio(tester) == 0; i++) {
      await tick(61000 + i * 100);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
    }
    expect(bandRatio(tester), greaterThan(0));

    // The demuxer stops consuming: stalled, or the counters were reset by a
    // reopen. A band that kept its old width would be claiming a buffer that
    // is not there, which is the one thing worse than showing nothing.
    // Two ticks: one to take the sample, one for the round trip that answers
    // it. The sampler refuses to overlap requests, so a single pump can land
    // while the previous one is still in flight.
    for (var i = 0; i < 2; i++) {
      await tick(62000 + i * 1000);
      stats(read: 16000000, demux: 11000000);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);
    }

    expect(bandRatio(tester), 0);

    await tester.pumpWidget(const SizedBox());
  });
}
