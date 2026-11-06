import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/domain/media_options.dart'
    show kLiveCachingMs, kVodCachingMs;

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

/// `--network-caching` is output latency, and it is the delay on a track switch.
///
/// A stream selected mid-playback has to accumulate the whole caching interval
/// before it emits anything, while the picture - whose buffer is already full -
/// carries on. So the viewer sees video with no audio for exactly one interval.
/// This was measured at 60 seconds when the value was fed from a buffer-depth
/// setting in minutes, and a seek hid it, because a seek refills every stream
/// at once.
///
/// The number is therefore a user-visible latency budget, not a tuning knob,
/// and these tests exist to stop it drifting back up. Each media carries its
/// own (spec 1.1): libvlc-android adds `:network-caching=1500` to any media
/// that names none, so only a media option makes Android follow the app.
void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  /// The instance options libVLC was actually created with.
  List<String> createdOptions() {
    final create = engine.callsTo('create').single;
    final arguments = create.arguments as Map<Object?, Object?>;
    return (arguments['options'] as List<Object?>).cast<String>();
  }

  /// The options the last media was opened with.
  List<String> lastMediaOptions() {
    final open = engine.callsTo('setSource').last;
    final arguments = open.arguments as Map<Object?, Object?>;
    return (arguments['mediaOptions'] as List<Object?>).cast<String>();
  }

  test('the caching intervals stay inside a tolerable switch delay', () {
    // 1 s on demand starts a file at 8 Mbit/s in 1.5 s instead of 2.6 s; a
    // live feed, which can't read ahead, gets half a second more for jitter.
    expect(kVodCachingMs, 1000);
    expect(kLiveCachingMs, 1500);
  });

  testWidgets('libVLC is created with the on-demand interval', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);
    await settle(tester);

    expect(createdOptions(), contains('--network-caching=$kVodCachingMs'));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a film carries the on-demand interval', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(tester);
    await settle(tester);

    expect(
      lastMediaOptions().where((o) => o.startsWith(':network-caching=')),
      [':network-caching=$kVodCachingMs'],
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a live feed carries the live interval, and live-caching is gone', variant: texturePlatform, (
    tester,
  ) async {
    await pumpPlayer(
      tester,
      item: MultimediaItem(
        title: 'Channel',
        url: 'https://example.com/live.ts',
        posterUrl: '',
        contentType: MultimediaContentType.livestream,
        provider: 'Remote',
      ),
      videoUrl: 'https://example.com/live.ts',
    );
    await settle(tester);

    expect(lastMediaOptions(), contains(':network-caching=$kLiveCachingMs'));
    expect(
      lastMediaOptions().where((o) => o.contains('live-caching')),
      isEmpty,
      reason: 'live-caching only ever applied to capture devices',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no setting reaches the caching interval', variant: texturePlatform, (
    tester,
  ) async {
    // A settings row used to offer 1 to 20 minutes of buffer depth and feed it
    // here, clamped onto the same 60000. The control did nothing except set
    // the length of the silence, and libVLC 3 has no read-ahead-in-seconds
    // option for a replacement to drive.
    await pumpPlayer(tester);
    await settle(tester);

    final caching = createdOptions()
        .where((o) => o.startsWith('--network-caching='))
        .toList();

    expect(caching, hasLength(1));
    expect(
      caching.single,
      isNot('--network-caching=60000'),
      reason: 'A buffer depth in minutes must not become a minute of latency.',
    );

    await tester.pumpWidget(const SizedBox());
  });
}
