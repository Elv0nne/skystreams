/// Which Stremio add-ons a subtitle search asks, and how one is asked.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_subtitle_service.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';

/// Answers every request from [respond] and records what was asked.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.respond);

  final Object? Function(RequestOptions request) respond;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ManagedAddon _addon(
  String manifestUrl, {
  String name = 'Subs',
  String id = 'org.example.subs',
  List<String> resources = const ['subtitles'],
}) => ManagedAddon(
  manifestUrl: manifestUrl,
  addedAt: DateTime(2026),
  manifest: AddonManifest(
    id: id,
    name: name,
    version: '1.0.0',
    types: const ['movie', 'series'],
    idPrefixes: const ['tt'],
    resources: [for (final r in resources) AddonResource(name: r)],
  ),
);

void main() {
  group('the add-ons a subtitle search asks', () {
    final service = AddonSubtitleService(AddonClient(Dio()));

    test('are the installed ones with subtitles, and OpenSubtitles v3 after '
        'them', () {
      final subs = _addon('https://subs.example/manifest.json');
      final catalog = _addon(
        'https://catalog.example/manifest.json',
        name: 'Catalog',
        id: 'org.example.catalog',
        resources: const ['catalog'],
      );
      expect(service.sources([subs, catalog]).map((a) => a.displayName), [
        'Subs',
        'OpenSubtitles v3',
      ]);
    });

    test('ask OpenSubtitles v3 once when it is installed', () {
      final installed = _addon(
        'https://opensubtitles-v3.strem.io/manifest.json',
        name: 'OpenSubtitles v3',
        id: 'org.stremio.opensubtitlesv3',
      );
      expect(service.sources([installed]), [installed]);

      // A copy served from elsewhere is the same add-on.
      final elsewhere = _addon(
        'https://mirror.example/opensubtitles/manifest.json',
        name: 'OpenSubtitles v3',
        id: 'org.stremio.opensubtitlesv3',
      );
      expect(service.sources([elsewhere]), [elsewhere]);
    });
  });

  group('asking an add-on', () {
    test(
      'for a film by its id, and an episode by its season and episode',
      () async {
        final adapter = _StubAdapter(
          (_) => {
            'subtitles': [
              {'id': '1', 'url': 'https://subs.example/1.srt', 'lang': 'eng'},
            ],
          },
        );
        final service = AddonSubtitleService(
          AddonClient(Dio()..httpClientAdapter = adapter),
        );
        final addon = _addon('https://subs.example/manifest.json');

        final film = await service.ask(addon, type: 'movie', id: 'tt0133093');
        await service.ask(addon, type: 'series', id: 'tt0903747:2:5');

        expect(film.single.url, 'https://subs.example/1.srt');
        expect(adapter.requests.map((r) => Uri.decodeComponent(r.uri.path)), [
          '/subtitles/movie/tt0133093.json',
          '/subtitles/series/tt0903747:2:5.json',
        ]);
      },
    );

    test('gives nothing for an id the add-on does not take', () async {
      final adapter = _StubAdapter((_) => {'subtitles': <Object?>[]});
      final service = AddonSubtitleService(
        AddonClient(Dio()..httpClientAdapter = adapter),
      );
      final found = await service.ask(
        _addon('https://subs.example/manifest.json'),
        type: 'movie',
        id: 'kitsu:1376',
      );
      expect(found, isEmpty);
      expect(adapter.requests, isEmpty);
    });
  });
}
