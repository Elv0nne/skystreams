import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/providers/device_memory.dart';
import 'package:skystream/features/player/domain/network_buffer.dart';

/// A device with [ramMb] installed and [freeMb] free now.
DeviceMemory device(int ramMb, {int? freeMb}) =>
    DeviceMemory(totalMb: ramMb, freeMb: freeMb);

const twoHours = Duration(hours: 2);

void main() {
  group('the cap', () {
    test("is the device's RAM over 16, from 48 MB to 1 GB", () {
      int cap(int ramMb) => bufferCapMb(device(ramMb), fallbackRamMb: 4096);
      expect(
        [cap(512), cap(1024), cap(2048), cap(4096), cap(8192), cap(16384)],
        [48, 64, 128, 256, 512, 1024],
      );
      expect(cap(65536), 1024);
    });

    test('halves when less than four times it is free', () {
      expect(bufferCapMb(device(8192, freeMb: 1500), fallbackRamMb: 4096), 256);
      expect(bufferCapMb(device(8192, freeMb: 2048), fallbackRamMb: 4096), 512);
    });

    // Review Focus 2: an old iOS, a Linux container with no /proc/meminfo, a
    // channel that throws.
    test(
      "a failed memory read uses the tier's RAM and counts as enough free",
      () {
        expect(bufferCapMb(const DeviceMemory(), fallbackRamMb: 4096), 256);
        final plan = bufferPlanFor(
          media: BufferMedia.httpFile,
          memory: const DeviceMemory(),
          fallbackRamMb: tierRamMb(DeviceTier.low),
          metered: false,
        );
        expect(plan.capMb, 64);
        expect(plan.ringMb, 64);
      },
    );
  });

  group("the spec's worked examples", () {
    // 3.96 GB over 2 h is 4.4 Mbit/s; 19.8 GB over 2 h is 22.
    BufferPlan film(int bytes, DeviceMemory memory, {bool metered = false}) =>
        bufferPlanFor(
          media: BufferMedia.httpFile,
          memory: memory,
          fallbackRamMb: 4096,
          metered: metered,
          fileBytes: bytes,
          runtime: twoHours,
        );

    test('a 4 GB 1080p film reads 180 s ahead', () {
      final plan = film(3960000000, device(4096, freeMb: 3000));
      expect(plan.bitrateKbps, 4400);
      expect(plan.bitrateFrom, BitrateSource.sizeAndRuntime);
      expect(plan.targetSeconds, 180);
      expect(plan.ringMb, 95);
    });

    test('the same on mobile data reads 60 s ahead', () {
      final plan = film(3960000000, device(4096, freeMb: 3000), metered: true);
      expect(plan.targetSeconds, 60);
      expect(plan.ringMb, 32);
    });

    test('a 20 GB 4K film fills the cap: 128 MB on a 2 GB TV', () {
      final plan = film(19800000000, device(2048, freeMb: 1200));
      expect(plan.bitrateKbps, 22000);
      expect(plan.targetSeconds, 360);
      expect(plan.ringMb, 128);
    });

    test('512 MB on an 8 GB phone', () {
      expect(film(19800000000, device(8192, freeMb: 3000)).ringMb, 512);
    });

    test('six minutes, about 1 GB, on a 16 GB desktop', () {
      expect(film(19800000000, device(16384, freeMb: 8000)).ringMb, 945);
    });

    test('unknown size, labelled 1080p, on an 8 GB phone: 180 s at 8', () {
      final plan = bufferPlanFor(
        media: BufferMedia.httpFile,
        memory: device(8192, freeMb: 3000),
        fallbackRamMb: 4096,
        metered: false,
        label: 'MoviesDrive 1080p WEB-DL',
      );
      expect(plan.bitrateKbps, 8000);
      expect(plan.bitrateFrom, BitrateSource.label);
      expect(plan.ringMb, 172);
    });
  });

  group('the bitrate', () {
    // Review Focus 1: a runtime that belongs to something else.
    test(
      "an episode's runtime against a season pack falls back to the label",
      () {
        final (kbps, from) = estimateBitrateKbps(
          fileBytes: 40 << 30,
          runtime: const Duration(minutes: 24),
          label: 'Show S01 1080p WEB-DL',
        );
        expect((kbps, from), (8000, BitrateSource.label));
      },
    );

    test('an implausibly low one falls back too', () {
      final (kbps, from) = estimateBitrateKbps(
        fileBytes: 30 << 20,
        runtime: twoHours,
        label: '720p',
      );
      expect((kbps, from), (4000, BitrateSource.label));
    });

    test('no size and no label assumes 1080p', () {
      expect(estimateBitrateKbps(label: 'Server 2'), (
        8000,
        BitrateSource.assumed,
      ));
    });

    test('the label guesses', () {
      expect(labelGuessKbps(label: '2160p REMUX HDR'), 60000);
      expect(labelGuessKbps(label: 'Movie 4K HDR10'), 25000);
      expect(labelGuessKbps(label: 'UHD BluRay'), 25000);
      expect(labelGuessKbps(label: '1080p BluRay REMUX'), 30000);
      expect(labelGuessKbps(label: 'x265 10bit 1080p'), 8000);
      expect(labelGuessKbps(label: '720p WEB-DL'), 4000);
      expect(labelGuessKbps(label: '480p'), 2000);
      expect(labelGuessKbps(label: 'Server 2'), isNull);
    });

    test("the stream's own height wins over its label", () {
      expect(labelGuessKbps(label: '1080p', height: 720), 4000);
    });

    test("a label's size, as Stremio rows carry it", () {
      expect(
        sizeFromLabel('Torrentio · 1080p · Torrent · 2.4 GB · 120 seeds'),
        2576980378,
      );
      expect(sizeFromLabel('MovieBox 850 MB'), 891289600);
      expect(sizeFromLabel('1,5 GB'), 1610612736);
      expect(sizeFromLabel('Server 1'), isNull);
    });

    test('the runtime, in order: measured, episode, item, TMDB', () {
      expect(
        runtimeFor(
          measured: const Duration(minutes: 112),
          episodeMinutes: 24,
          itemMinutes: 120,
        ),
        const Duration(minutes: 112),
      );
      expect(
        runtimeFor(
          measured: Duration.zero,
          episodeMinutes: 24,
          itemMinutes: 120,
        ),
        const Duration(minutes: 24),
      );
      expect(
        runtimeFor(episodeMinutes: 0, itemMinutes: 120, tmdbMinutes: 95),
        const Duration(minutes: 120),
      );
      expect(runtimeFor(tmdbMinutes: 95), const Duration(minutes: 95));
      expect(runtimeFor(), isNull);
    });
  });

  group('HLS and DASH', () {
    BufferPlan hls(
      DeviceMemory memory, {
      int? maxHeight,
      bool metered = false,
    }) => bufferPlanFor(
      media: BufferMedia.adaptive,
      memory: memory,
      fallbackRamMb: 4096,
      metered: metered,
      label: '1080p',
      maxHeight: maxHeight,
    );

    test('get the target in seconds when the cap holds it', () {
      final plan = hls(device(16384, freeMb: 8000), maxHeight: 1080);
      expect(plan.adaptiveSeconds, 180);
      expect(plan.ringMb, isNull);
    });

    test('get what the cap holds at the top height allowed', () {
      // 128 MB at 4K's 25 Mbit/s is 42 s.
      expect(
        hls(device(2048, freeMb: 1200), maxHeight: 2160).adaptiveSeconds,
        42,
      );
      expect(hls(device(2048, freeMb: 1200)).adaptiveSeconds, 42);
    });

    test('never get less than 20 s', () {
      expect(
        hls(device(1024, freeMb: 100), maxHeight: 2160).adaptiveSeconds,
        20,
      );
    });

    test('get 60 s on a metered network', () {
      expect(
        hls(
          device(8192, freeMb: 3000),
          maxHeight: 1080,
          metered: true,
        ).adaptiveSeconds,
        60,
      );
    });
  });

  group('torrents, live and local files', () {
    test("a torrent gets libVLC's 16 MiB ring, and its cache on a step "
        'within the cap', () {
      final plan = bufferPlanFor(
        media: BufferMedia.torrent,
        memory: device(8192, freeMb: 3000),
        fallbackRamMb: 4096,
        metered: false,
        label: '1080p',
      );
      // 172 MB wanted, under a cap of 512: the next step up. TorrServer's
      // write costs over 2 s and drops every torrent, so values that repeat
      // let most starts skip it.
      expect((plan.ringMb, plan.torrentCacheMb), (16, 256));
    });

    test('a step past the cap stops at the cap', () {
      // 3 GB: a cap of 192.
      final plan = bufferPlanFor(
        media: BufferMedia.torrent,
        memory: device(3072, freeMb: 2000),
        fallbackRamMb: 4096,
        metered: false,
        label: '1080p',
      );
      expect((plan.ringMb, plan.torrentCacheMb), (16, 192));
    });

    test("the torrent cache never goes under TorrServer's 64 MB", () {
      final plan = bufferPlanFor(
        media: BufferMedia.torrent,
        memory: device(8192, freeMb: 3000),
        fallbackRamMb: 4096,
        metered: true,
        label: '720p',
      );
      expect((plan.ringMb, plan.torrentCacheMb), (16, 64));
    });

    test('live and local media keep libVLC defaults', () {
      for (final media in [BufferMedia.live, BufferMedia.local]) {
        final plan = bufferPlanFor(
          media: media,
          memory: device(8192),
          fallbackRamMb: 4096,
          metered: false,
        );
        expect(
          (plan.ringMb, plan.adaptiveSeconds, plan.torrentCacheMb),
          (null, null, null),
        );
      }
    });
  });

  group("the viewer's own size", () {
    BufferPlan pick(BufferMedia media) => bufferPlanFor(
      media: media,
      memory: device(2048, freeMb: 1200),
      fallbackRamMb: 4096,
      metered: false,
      maxHeight: 1080,
      overrideMb: 512,
    );

    test('replaces the rule, cap included', () {
      expect(pick(BufferMedia.httpFile).ringMb, 512);
      final torrent = pick(BufferMedia.torrent);
      // TorrServer's cache: the film isn't held twice.
      expect((torrent.ringMb, torrent.torrentCacheMb), (16, 512));
    });

    test('reaches HLS as seconds at its guess', () {
      // 512 MB at 1080p's 8 Mbit/s.
      expect(pick(BufferMedia.adaptive).adaptiveSeconds, 536);
    });
  });

  test("the QoE log's buffer event", () {
    final plan = bufferPlanFor(
      media: BufferMedia.httpFile,
      memory: device(8192, freeMb: 3000),
      fallbackRamMb: 4096,
      metered: false,
      label: '1080p',
    );
    expect(plan.toJson(), {
      'media': 'httpFile',
      'ringMb': 172,
      'adaptiveSeconds': null,
      'torrentCacheMb': null,
      'capMb': 512,
      'targetSeconds': 180,
      'bitrateKbps': 8000,
      'bitrateFrom': 'label',
    });
  });
}
