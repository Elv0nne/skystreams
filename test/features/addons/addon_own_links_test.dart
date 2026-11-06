/// A Stremio title's own add-on and its links (Stremio direct play): the
/// install that described the title, when it also serves its streams, asked
/// by the ids it published and never by anything found by name.
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_stream_service.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';
import 'package:skystream/core/addons/data/addon_own_links.dart';

ManagedAddon _install(String url, Map<String, dynamic> manifest) =>
    ManagedAddon(
      manifestUrl: url,
      manifest: AddonManifest.fromJson(manifest),
      addedAt: DateTime(2026),
    );

/// CNCVerse Bridge's shape: a catalog, its titles' meta and their streams,
/// for its own `cnc:` ids and IMDb's.
Map<String, dynamic> _bridge({List<String> prefixes = const ['cnc:', 'tt']}) =>
    {
      'id': 'com.bridge',
      'name': 'Bridge',
      'version': '1.0.0',
      'types': ['movie', 'series', 'other'],
      'idPrefixes': prefixes,
      'resources': ['catalog', 'meta', 'stream'],
      'catalogs': <Object>[],
    };

/// Cinemeta's shape: it describes titles and serves no links.
const Map<String, dynamic> _cinemeta = {
  'id': 'com.linvo.cinemeta',
  'name': 'Cinemeta',
  'version': '1.0.0',
  'types': ['movie', 'series'],
  'idPrefixes': ['tt'],
  'resources': ['catalog', 'meta'],
  'catalogs': <Object>[],
};

AddonMeta _meta(String addonId, {String id = 'cnc:show'}) => AddonMeta.fromJson(
  {'id': id, 'type': 'other', 'name': 'Money Heist'},
  addonId: addonId,
  addonName: 'Bridge',
);

AddonStreamSource _direct(String url) =>
    AddonStreamSource(addonId: 'com.bridge', addonName: 'Bridge', url: url);

const _donate = AddonStreamSource(
  addonId: 'com.bridge',
  addonName: 'Bridge',
  externalUrl: 'https://donate.test/',
);

const _trailer = AddonStreamSource(
  addonId: 'com.bridge',
  addonName: 'Bridge',
  ytId: 'abcdefghijk',
);

/// Answers the ask by published ids with [own], the ask with the title and
/// universal ids with [full], and records every ask.
class _Service implements AddonStreamService {
  _Service({this.own = const [], this.full = const [], this.fails = false});

  final List<AddonStreamSource> own;
  final List<AddonStreamSource> full;
  final bool fails;
  final asked = <({List<dynamic> addons, AddonStreamRequest request})>[];

  @override
  Stream<AddonStreamProgress> resolve({
    required List<dynamic> addons,
    required AddonStreamRequest request,
    bool forceRefresh = false,
    dynamic cancelToken,
    bool personWaiting = false,
    Set<String>? only,
  }) async* {
    asked.add((addons: addons, request: request));
    if (fails) throw StateError('host down');
    final byName = request.title != null || request.imdbId != null;
    yield const AddonStreamProgress(isLoading: true);
    yield AddonStreamProgress(streams: byName ? full : own);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An add-on host for the real [AddonStreamService]: answers every ask with
/// [links], or fails every ask when [down], and records the ids asked and the
/// titles looked up by name.
class _Client extends AddonClient {
  _Client({this.links = const [], this.down = false}) : super(Dio());

  final List<AddonStreamSource> links;
  final bool down;
  final askedIds = <String>[];
  final lookedUp = <String>[];

  @override
  Future<List<AddonStreamSource>> streams(
    ManagedAddon addon, {
    required String type,
    required String id,
    bool forceRefresh = false,
    CancelToken? cancelToken,
    bool personWaiting = false,
  }) async {
    askedIds.add(id);
    if (down) {
      throw DioException.connectionTimeout(
        timeout: const Duration(seconds: 45),
        requestOptions: RequestOptions(path: '/stream/$type/$id.json'),
      );
    }
    return links;
  }

  @override
  Future<String?> resolveImdbId({
    required String title,
    String? type,
    int? year,
    CancelToken? cancelToken,
  }) async {
    lookedUp.add(title);
    return 'tt0000001';
  }
}

const _episode = AddonStreamRequest(
  type: 'other',
  contentId: 'cnc:show',
  videoId: 'cnc:s1e1',
  season: 1,
  episode: 1,
  imdbId: 'tt6468322',
  title: 'Money Heist',
  year: 2017,
);

void main() {
  group('the title\'s own add-on', () {
    final bridge = _install('https://bridge.test/a/manifest.json', _bridge());

    test('is the install that described it, when it serves its streams', () {
      expect(
        ownStreamAddon(enabled: [bridge], meta: _meta('com.bridge')),
        same(bridge),
      );
    });

    test('is none for a title Cinemeta described: it serves no links', () {
      final cinemeta = _install(
        'https://cinemeta.test/manifest.json',
        _cinemeta,
      );
      expect(
        ownStreamAddon(
          enabled: [cinemeta, bridge],
          meta: _meta('com.linvo.cinemeta', id: 'tt6468322'),
        ),
        isNull,
      );
    });

    test('is none when its streams are for other ids', () {
      final imdbOnly = _install(
        'https://bridge.test/b/manifest.json',
        _bridge(prefixes: const ['tt']),
      );
      expect(
        ownStreamAddon(enabled: [imdbOnly], meta: _meta('com.bridge')),
        isNull,
      );
    });

    test('of two installs of one add-on, is the one whose catalog listed '
        'the title', () {
      final second = _install('https://bridge.test/b/manifest.json', _bridge());
      expect(
        ownStreamAddon(
          enabled: [bridge, second],
          meta: _meta('com.bridge'),
          routeAddonUrl: second.manifestUrl,
        ),
        same(second),
      );
      expect(
        ownStreamAddon(enabled: [bridge, second], meta: _meta('com.bridge')),
        same(bridge),
        reason: 'opened from Continue Watching: the first install',
      );
    });
  });

  group("the own add-on's links", () {
    final bridge = _install('https://bridge.test/a/manifest.json', _bridge());

    test(
      'come from that install alone, asked by the ids it published',
      () async {
        final service = _Service(own: [_direct('https://cdn.test/a.m3u8')]);
        final links = await ownPlayableLinks(service, bridge, _episode);

        expect(links.map((l) => l.url), ['https://cdn.test/a.m3u8']);
        expect(service.asked, hasLength(1));
        expect(service.asked.single.addons, [bridge]);
        final asked = service.asked.single.request;
        expect(asked.videoId, 'cnc:s1e1');
        expect(asked.type, 'other');
        // No title and no IMDb id: nothing to look up by name, which could
        // land on another show and play it.
        expect(asked.title, isNull);
        expect(asked.imdbId, isNull);
      },
    );

    test('drop what only opens elsewhere', () async {
      final service = _Service(
        own: [
          _donate,
          _direct('https://cdn.test/1.m3u8'),
          _trailer,
          _direct('https://cdn.test/2.mp4'),
        ],
      );
      final links = await ownPlayableLinks(service, bridge, _episode);
      expect(links.map((l) => l.url), [
        'https://cdn.test/1.m3u8',
        'https://cdn.test/2.mp4',
      ]);
    });

    test('fall back to the IMDb id the title came with when its own ids '
        'have none', () async {
      final service = _Service(
        own: [_donate],
        full: [_direct('https://cdn.test/imdb.mkv')],
      );
      final links = await ownPlayableLinks(service, bridge, _episode);

      expect(links.map((l) => l.url), ['https://cdn.test/imdb.mkv']);
      expect(service.asked, hasLength(2));
      expect(service.asked.last.addons, [bridge]);
      expect(service.asked.last.request.imdbId, 'tt6468322');
      // Without the title: given one and no IMDb id, the service looks an id
      // up on Cinemeta by name, which can be another show's.
      expect(service.asked.last.request.title, isNull);
    });

    test('are none when the add-on fails', () async {
      final links = await ownPlayableLinks(
        _Service(fails: true),
        bridge,
        _episode,
      );
      expect(links, isEmpty);
    });
  });

  group('asked through the stream service', () {
    final bridge = _install('https://bridge.test/a/manifest.json', _bridge());

    const vvaan = AddonStreamRequest(
      type: 'other',
      contentId: 'cnc:vvaan',
      title: 'The Vvaan',
      year: 2026,
    );

    test("put the title's links before another film's the add-on mixed "
        'in', () async {
      // Measured on CNCVerse: asked for The Vvaan (2026), its FourKHDHub
      // answered with 4K links to another film, which outscore the title's
      // own 1080p link.
      final client = _Client(
        links: const [
          AddonStreamSource(
            addonId: 'com.bridge',
            addonName: 'Bridge',
            name: 'FourKHDHub 4K',
            title: 'The Twilight Saga Breaking Dawn Part 2 2160p',
            url: 'https://cdn.test/twilight.mkv',
          ),
          AddonStreamSource(
            addonId: 'com.bridge',
            addonName: 'Bridge',
            name: 'MovieBox 1080p',
            title: 'The Vvaan (2026) 1080p',
            url: 'https://cdn.test/vvaan.mkv',
          ),
        ],
      );
      final links = await ownPlayableLinks(
        AddonStreamService(client),
        bridge,
        vvaan,
      );
      expect(links.map((l) => l.url), [
        'https://cdn.test/vvaan.mkv',
        'https://cdn.test/twilight.mkv',
      ]);
    });

    test('a host that is down is asked once, not again by IMDb id', () async {
      final client = _Client(down: true);
      final links = await ownPlayableLinks(
        AddonStreamService(client),
        bridge,
        _episode,
      );
      expect(links, isEmpty);
      expect(client.askedIds, isNotEmpty);
      expect(client.askedIds, everyElement(startsWith('cnc:')));
    });

    test('nothing is looked up by name: a title with only the add-on\'s own '
        'id is asked by that id alone', () async {
      final client = _Client();
      final links = await ownPlayableLinks(
        AddonStreamService(client),
        bridge,
        vvaan,
      );
      expect(links, isEmpty);
      expect(client.lookedUp, isEmpty);
      expect(client.askedIds, everyElement('cnc:vvaan'));
    });
  });
}
