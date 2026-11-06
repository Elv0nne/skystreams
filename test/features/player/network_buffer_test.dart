import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

import 'package:skystream/features/player/domain/network_buffer.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// Read-ahead, and why it is not the caching option.
///
/// `--network-caching` is output latency: every stream has to fill it before
/// it emits anything, so a large value there made a newly selected audio track
/// silent for exactly that long. `--prefetch-buffer-size` sits under the
/// demuxer instead and holds what has been read ahead of it, so a larger one
/// costs memory and rides out a slow patch of network.
///
/// libVLC 3 inserts the prefetch filter itself, as the cache stage of every
/// network access, so the size is the only option: naming the filter as well
/// stacked a second one and reserved the buffer twice.
void main() {
  _torrentSplitTests();
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  List<String> createdOptions() {
    final create = engine.callsTo('create').single;
    final arguments = create.arguments as Map<Object?, Object?>;
    return (arguments['options'] as List<Object?>).cast<String>();
  }

  List<String> lastMediaOptions() {
    final open = engine.callsTo('setSource').last;
    final arguments = open.arguments as Map<Object?, Object?>;
    return (arguments['mediaOptions'] as List<Object?>).cast<String>();
  }

  group('the buffer option', () {
    test('a buffer size is the size alone, with no second filter', () {
      const config = VlcNetworkConfig(prefetchBufferKiB: 16384);

      expect(config.toOptions(), <String>['--prefetch-buffer-size=16384']);
    });

    test('no buffer size means no option, so libVLC keeps its own', () {
      const config = VlcNetworkConfig();

      expect(
        config.toOptions().where((o) => o.contains('prefetch')),
        isEmpty,
      );
    });
  });

  testWidgets('each media asks for its own read-ahead, in KiB', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);
    await settle(tester);

    expect(
      createdOptions().where((o) => o.contains('prefetch')),
      isEmpty,
      reason: 'the player keeps libVLC\'s own; each media brings its size',
    );
    // The harness's 4 GB device with half of it free (a 256 MB cap), a film
    // with no size and no label (8 Mbit/s assumed), on Wi-Fi: 180 s, 172 MB.
    expect(lastMediaOptions(), contains(':prefetch-buffer-size=${172 * 1024}'));
    expect(
      lastMediaOptions().where((o) => o.contains('stream-filter')),
      isEmpty,
      reason: 'libVLC inserts the filter itself; naming it stacks a second',
    );

    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('read-ahead is not latency', variant: texturePlatform, (
    tester,
  ) async {
    // The two must not be confused again: a buffer measured in megabytes has
    // no business reaching the caching option, which is measured in
    // milliseconds and is felt on every track switch.
    await pumpPlayer(tester);
    await settle(tester);

    expect(
      createdOptions().where((o) => o.startsWith('--network-caching=')),
      ['--network-caching=1000'],
    );
    expect(
      lastMediaOptions().where((o) => o.startsWith(':network-caching=')),
      [':network-caching=1000'],
      reason: 'the buffer must not add a second caching option',
    );

    await tester.pumpWidget(const SizedBox());
  });
}

/// The torrent cache's ahead/behind split.
///
/// TorrServer holds one cache and `readerReadAHead` is the share of it kept in
/// front of the read point. The remainder is the only backward buffer anywhere
/// in this player - libVLC 3's prefetch filter takes a size and decides the
/// rest itself - so this is where "a ten second step back should not
/// re-download" is answered.
void _torrentSplitTests() {
  group('torrentReadAheadPercent', () {
    /// How much of a cache is left behind the playhead at this split.
    double behindMb(int cacheMb) =>
        cacheMb * (100 - torrentReadAheadPercent(cacheMb)) / 100;

    test('a quarter of the cache is held behind the playhead', () {
      for (final cacheMb in kNetworkBufferChoicesMb) {
        final behind = behindMb(cacheMb);
        expect(
          behind,
          greaterThan(0),
          reason: '$cacheMb MB kept nothing behind the read point',
        );
        expect(
          behind,
          lessThanOrEqualTo(kMaxTorrentBehindMb.toDouble()),
          reason: 'the behind window is capped; the rest is what plays',
        );
      }
    });

    test('and it is enough for the step the seek buttons take', () {
      // A ten second step at 1080p is roughly 10 MB - 8 Mbit/s is 1 MB/s. The
      // 95 % this replaced left about 3 MB behind a 64 MB cache, so every
      // back-step of any size re-fetched pieces the reader had just released.
      for (final cacheMb in kNetworkBufferChoicesMb) {
        expect(
          behindMb(cacheMb),
          greaterThanOrEqualTo(8),
          reason: '$cacheMb MB leaves too little behind for a 10 s step back',
        );
      }
    });

    test('the cap stops a large cache spending all of it on history', () {
      // 512 MB at a flat quarter would be 128 MB of data already watched.
      expect(behindMb(512), lessThanOrEqualTo(kMaxTorrentBehindMb.toDouble()));
      expect(
        torrentReadAheadPercent(512),
        greaterThan(torrentReadAheadPercent(128)),
        reason: 'a bigger cache spends proportionally more of it ahead',
      );
    });

    test('read-ahead never drops low enough to starve playback', () {
      for (final cacheMb in <int>[1, 8, 32, 64, 128, 256, 512, 2048]) {
        expect(torrentReadAheadPercent(cacheMb), inInclusiveRange(60, 99));
      }
    });

    test('a nonsense cache falls back rather than dividing by zero', () {
      expect(torrentReadAheadPercent(0), 95);
      expect(torrentReadAheadPercent(-1), 95);
    });
  });
}
