import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_stream_service.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';

/// Scraper bridges search their sites by title and sometimes take the wrong
/// page. Asked for The Vvaan (2026), CNCVerse answered with 81 links, 14 of
/// them FourKHDHub's 4K links to The Twilight Saga: Breaking Dawn - Part 2 -
/// and the resolution score alone made one of those the top pick. The names
/// below are CNCVerse's own, as it sent them.
void main() {
  AddonStreamSource stream(
    String name,
    String title, {
    String addon = 'cncverse',
    String url = 'https://files.example/v',
  }) => AddonStreamSource(
    addonId: addon,
    addonName: addon,
    name: name,
    title: title,
    url: url,
  );

  final twilight4k = stream(
    'The Twilight Saga: Breaking Dawn - Part 2\nFourKHDHub - 2160p',
    'HubCloud [FSL Server] BLURAY DOLBYVISION HDR HEVC DDP5 ATMOS X265 '
        '[32.97 GB]',
  );
  final twilight1080 = stream(
    'The Twilight Saga: Breaking Dawn - Part 2\nFourKHDHub - 1080p',
    'HubCloud [Pixeldrain] BLURAY HEVC X265 DDP5 DDP7 [4.08 GB]',
  );
  final younger = stream(
    'The Younger Generation (1929) Dual Audio {Hindi-English} BluRay 720p '
        '[850MB] | 1080p [1.5GB] x264\nVegaMovies - 1080p',
    'V-Cloud[FSL Server] The.Younger.Generation.(1929).BluRay.1080p.x264.'
        'Hindi.Eng.AAC.2.0.1VegaMovies.tw.mkv[1.5 GB]',
  );
  final vvaan1080 = stream(
    'The Vvaan (2026) V2 HQ-HDTC Hindi (LiNE) 1080p 720p & 480p [x264/HEVC] '
        '| Full Movie\nHDhub4u',
    'HubCloud [FSL Server] HEVC [1.2 GB] 1080p',
  );
  final vvaanCastle = stream(
    'Vvan - Force of the Forrest\nCastleTvProvider - 720p',
    'Castle TV (Use VLC) - Hindi',
  );

  const vvaan = 'The Vvaan: Force of the Forrest';

  List<String?> names(List<AddonStreamSource> ranked) => [
    for (final s in ranked) s.name?.split('\n').first,
  ];

  group('links that name a different film', () {
    test('go after the links to the film asked for', () {
      final ranked = rankAddonStreams(
        [twilight4k, younger, vvaanCastle, twilight1080, vvaan1080],
        title: vvaan,
        year: 2026,
      );
      expect(ranked.take(2), [vvaan1080, vvaanCastle]);
      expect(ranked.skip(2).toSet(), {twilight4k, twilight1080, younger});
      // Among themselves they keep the score's order.
      expect(ranked[2], twilight4k);
    });

    test('are found under a catalog name full of release words', () {
      // A CNCVerse catalog entry's name: HEVC, Hindi, 1080p are in the
      // Twilight links too, and must not count as naming the film.
      final ranked = rankAddonStreams(
        [twilight4k, vvaan1080],
        title:
            'The Vvaan (2026) V2 HQ-HDTC Hindi (LiNE) 1080p 720p & 480p '
            '[x264/HEVC] | Full Movie',
      );
      expect(ranked.first, vvaan1080);
    });

    test('keep a release under a translated name that has the year', () {
      final dune = stream(
        'Torrentio\n1080p',
        'Dune.Part.Two.2024.1080p.WEB-DL.mkv',
        addon: 'torrentio',
      );
      final duna = stream(
        'Torrentio\n4k',
        'Duna - Parte Dois 2024 2160p WEB-DL DUAL 5.1',
        addon: 'torrentio',
      );
      final other = stream(
        'Torrentio\n4k',
        'Druhá světová válka s Tomem Hanksem E05-06 [SATRip] [CZ] 2160p',
        addon: 'torrentio',
      );
      final ranked = rankAddonStreams(
        [other, dune, duna],
        title: 'Dune: Part Two',
        year: 2024,
      );
      expect(ranked, [duna, dune, other]);
    });
  });

  group('the score alone decides', () {
    test('for an add-on that never names the film', () {
      final bare4k = stream('WebStreamr\n4K', 'VidSrc', addon: 'webstreamr');
      final ranked = rankAddonStreams(
        [vvaan1080, bare4k, twilight4k],
        title: vvaan,
        year: 2026,
      );
      expect(ranked.first, bare4k);
      expect(ranked.last, twilight4k);
    });

    test('for a title with no word distinctive enough to look for', () {
      final ranked = rankAddonStreams([vvaan1080, twilight4k], title: 'F1');
      expect(names(ranked), names([twilight4k, vvaan1080]));
    });

    test('when no link names the film', () {
      final ranked = rankAddonStreams(
        [younger, twilight4k],
        title: vvaan,
        year: 2026,
      );
      expect(ranked, [twilight4k, younger]);
    });
  });

  test('the sources sheet opens on a link to the film asked for', () async {
    final manifest = AddonManifest.fromJson({
      'id': 'cncverse',
      'name': 'CNCVerse Bridge',
      'version': '1.0.0',
      'types': const ['movie'],
      'resources': const ['stream'],
    });
    final addon = ManagedAddon(
      manifestUrl: 'https://cncverse.example/manifest.json',
      manifest: manifest,
      addedAt: DateTime(2026),
    );
    final service = AddonStreamService(
      _FakeClient(
        (addon, type, id) async => [
          twilight4k,
          younger,
          vvaan1080,
          vvaanCastle,
        ],
      ),
    );
    AddonStreamProgress? last;
    await for (final progress in service.resolve(
      addons: [addon],
      request: const AddonStreamRequest(
        type: 'movie',
        contentId: 'tt34498564',
        imdbId: 'tt34498564',
        title: vvaan,
        year: 2026,
      ),
    )) {
      last = progress;
    }
    expect(last!.streams.first, vvaan1080);
    expect(last.streams, hasLength(4));
  });
}

typedef _StreamsHandler = Future<List<AddonStreamSource>> Function(
  ManagedAddon addon,
  String type,
  String id,
);

class _FakeClient extends AddonClient {
  _FakeClient(this.handler) : super(Dio());

  final _StreamsHandler handler;

  @override
  Future<List<AddonStreamSource>> streams(
    ManagedAddon addon, {
    required String type,
    required String id,
    bool forceRefresh = false,
    CancelToken? cancelToken,
    bool personWaiting = false,
  }) => handler(addon, type, id);
}
