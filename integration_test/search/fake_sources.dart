/// A local Stremio add-on that searches, and a local Nuvio repository whose scraper answers at
/// once, for the device test of the search bar's Stremio and Nuvio sections.
///
/// - `/addon/manifest.json`: an add-on with a movie catalog that takes a search, and details.
///   Searched for anything with "matrix" in it, it answers The Matrix (tt0133093).
/// - `/nuvio/manifest.json`: a repository with one scraper, `plain.js`, whose stream needs no
///   site.
library;

import 'dart:convert';
import 'dart:io';

class FakeSources {
  FakeSources._(this._server);

  final HttpServer _server;

  /// Searches the add-on was asked.
  final searches = <String>[];

  static Future<FakeSources> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sources = FakeSources._(server);
    server.listen(sources._serve);
    return sources;
  }

  String get origin => 'http://127.0.0.1:${_server.port}';
  String get addonUrl => '$origin/addon/manifest.json';
  String get nuvioUrl => '$origin/nuvio/manifest.json';

  Future<void> close() => _server.close(force: true);

  static const _matrix = {
    'id': 'tt0133093',
    'type': 'movie',
    'name': 'The Matrix',
    'releaseInfo': '1999',
    'description': 'A hacker learns what the world really is.',
  };

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final path = Uri.decodeComponent(request.uri.path);
    try {
      if (path == '/addon/manifest.json') {
        return _json(response, {
          'id': 'test.search',
          'name': 'Search Test',
          'version': '1.0.0',
          'resources': ['catalog', 'meta'],
          'types': ['movie'],
          'idPrefixes': ['tt'],
          'catalogs': [
            {
              'type': 'movie',
              'id': 'top',
              'name': 'Top',
              'extra': [
                {'name': 'search'},
              ],
            },
          ],
        });
      }
      if (path.startsWith('/addon/catalog/movie/top/')) {
        final search =
            RegExp(r'search=([^/]*)\.json$').firstMatch(path)?.group(1) ?? '';
        searches.add(search);
        return _json(response, {
          'metas': [if (search.toLowerCase().contains('matrix')) _matrix],
        });
      }
      if (path == '/addon/meta/movie/tt0133093.json') {
        return _json(response, {'meta': _matrix});
      }
      if (path == '/nuvio/manifest.json') {
        return _json(response, {
          'name': 'Plain scrapers',
          'version': '1.0.0',
          'scrapers': [
            {
              'id': 'plain',
              'name': 'Plain',
              'version': '1.0.0',
              'filename': 'plain.js',
              'supportedTypes': ['movie', 'tv'],
              'enabled': true,
            },
          ],
        });
      }
      if (path == '/nuvio/plain.js') {
        response.headers.contentType = ContentType('application', 'javascript');
        response.write(
          'var BASE = ${jsonEncode(origin)};\n'
          'async function getStreams(tmdbId, type) {\n'
          '  return [{ name: "Plain", title: "Test 1080p", url: BASE + "/video.mp4",\n'
          '    quality: "1080p" }];\n'
          '}\n'
          'module.exports = { getStreams: getStreams };\n',
        );
        return;
      }
      response.statusCode = 404;
    } finally {
      await response.close();
    }
  }

  void _json(HttpResponse response, Object body) {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
  }
}
