/// What the three subtitle providers put on the wire for one search target,
/// pinned through a stubbed Dio adapter (no sockets).
///
/// The notifier's fallback chain relies on each provider preferring an id
/// over the title and on SubSource filtering by episode client-side; these
/// are the facts it relies on.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/data/subtitle_providers.dart';

/// The provider no longer carries a baked-in key (it was a literal in a public
/// repo), so a test that wants to see the wire format has to supply one.
const String _kTestKey = 'test-api-key';

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

(Dio, _StubAdapter) _dio(Object? Function(RequestOptions request) respond) {
  final adapter = _StubAdapter(respond);
  final dio = Dio()..httpClientAdapter = adapter;
  return (dio, adapter);
}

Map<String, Object?> _osResult(String release) => {
  'id': '1',
  'attributes': {
    'release': release,
    'language': 'en',
    'hearing_impaired': false,
    'files': [
      {'file_id': 11},
    ],
  },
};

void main() {

  group('OpenSubtitles without a key', () {
    // The key used to be a literal in the source of a public repository. It is
    // now a --dart-define, so a build that supplies neither it nor a viewer key
    // must return nothing rather than firing a request with an empty Api-Key
    // header and reporting the 401 as a search failure.
    test('returns nothing instead of searching', () async {
      final dio = Dio();
      var called = false;
      dio.httpClientAdapter = _RecordingAdapter(() => called = true);
      final provider = OpenSubtitlesProvider(dio);

      final results = await provider.search(query: 'The Matrix');

      expect(results, isEmpty);
      expect(called, isFalse, reason: 'no key means no request at all');
    });
  });
  // As OpenSubtitles' own documentation asks (its OpenAPI file, 2026-10-11):
  // an episode by its show's id - parent_imdb_id - with the season and the
  // episode; ids without leading zeros and parameters in alphabetical order,
  // or every search is redirected first.
  group('OpenSubtitles', () {
    test('asks for an episode by its show: parent_imdb_id', () async {
      final (dio, adapter) = _dio(
        (_) => {
          'data': [_osResult('Show.S02E05.720p')],
        },
      );
      final results = await OpenSubtitlesProvider(dio, apiKey: _kTestKey).search(
        query: 'The Show',
        imdbId: 'tt0903747',
        tmdbId: 1396,
        season: 2,
        episode: 5,
        language: 'en',
      );

      final request = adapter.requests.single;
      expect(request.uri.path, endsWith('/subtitles'));
      final q = request.uri.queryParameters;
      expect(q['parent_imdb_id'], '903747');
      expect(q['season_number'], '2');
      expect(q['episode_number'], '5');
      expect(q['languages'], 'en');
      expect(q, isNot(contains('imdb_id')));
      expect(q, isNot(contains('parent_tmdb_id')), reason: 'imdb beats tmdb');
      expect(q, isNot(contains('query')), reason: 'imdb beats title');
      expect(results.single.name, 'Show.S02E05.720p');
      expect(results.single.metadata?['file_id'], 11);
    });

    test('asks for a film by imdb_id, without leading zeros', () async {
      final (dio, adapter) = _dio((_) => {'data': <Object>[]});
      await OpenSubtitlesProvider(
        dio,
        apiKey: _kTestKey,
      ).search(query: 'The Matrix', imdbId: 'tt0133093');
      final q = adapter.requests.single.uri.queryParameters;
      expect(q['imdb_id'], '133093');
      expect(q, isNot(contains('parent_imdb_id')));
    });

    test('sends its parameters in alphabetical order', () async {
      final (dio, adapter) = _dio((_) => {'data': <Object>[]});
      await OpenSubtitlesProvider(dio, apiKey: _kTestKey).search(
        query: 'The Show',
        imdbId: 'tt0903747',
        season: 2,
        episode: 5,
        language: 'en',
      );
      expect(
        adapter.requests.single.uri.query,
        'episode_number=5&languages=en&parent_imdb_id=903747&season_number=2',
      );
    });

    test('tmdb_id when there is no imdb id; query only when neither', () async {
      final (dio, adapter) = _dio((_) => {'data': <Object>[]});
      final provider = OpenSubtitlesProvider(dio, apiKey: _kTestKey);

      await provider.search(query: 'The Show', tmdbId: 1396);
      expect(adapter.requests.last.uri.queryParameters['tmdb_id'], '1396');
      expect(
        adapter.requests.last.uri.queryParameters,
        isNot(contains('query')),
      );

      await provider.search(query: 'The Show', tmdbId: 1396, season: 2);
      expect(
        adapter.requests.last.uri.queryParameters['parent_tmdb_id'],
        '1396',
      );

      // In lower case, as the documentation asks.
      await provider.search(query: 'The Show');
      expect(adapter.requests.last.uri.queryParameters['query'], 'the show');
      expect(
        adapter.requests.last.uri.queryParameters,
        isNot(contains('imdb_id')),
      );
    });

    test('no season/episode -> no season_number/episode_number', () async {
      final (dio, adapter) = _dio((_) => {'data': <Object>[]});
      await OpenSubtitlesProvider(dio, apiKey: _kTestKey).search(query: 'Film', imdbId: 'tt1');
      final q = adapter.requests.single.uri.queryParameters;
      expect(q, isNot(contains('season_number')));
      expect(q, isNot(contains('episode_number')));
    });

    // OpenSubtitles files Chinese and Portuguese only by their variants: zh
    // and pt alone found nothing for Top Gun: Maverick, its variants 7 and 12.
    test('asks for Chinese and Portuguese by their variants', () async {
      for (final (code, codes) in const [
        ('zh', 'ze,zh-cn,zh-tw'),
        ('pt', 'pt-br,pt-pt'),
        ('fa', 'fa'),
      ]) {
        final (dio, adapter) = _dio((_) => {'data': <Object>[]});
        await OpenSubtitlesProvider(
          dio,
          apiKey: _kTestKey,
        ).search(query: 'Top Gun', imdbId: 'tt1745960', language: code);
        expect(
          adapter.requests.single.uri.queryParameters['languages'],
          codes,
          reason: code,
        );
      }
    });

    // A VIP account is sent to its own server, which the rest of the session
    // has to use.
    test('goes on with the server the login names', () async {
      final (dio, adapter) = _dio((request) {
        if (request.uri.path.endsWith('/login')) {
          return {'token': 't', 'base_url': 'vip-api.opensubtitles.com'};
        }
        if (request.uri.path.endsWith('/download')) {
          return {'link': 'https://example.com/a.srt'};
        }
        return {
          'data': [_osResult('Film.1080p')],
        };
      });
      final provider = OpenSubtitlesProvider(
        dio,
        apiKey: _kTestKey,
        username: 'u',
        password: 'p',
      );
      final results = await provider.search(query: 'Film', imdbId: 'tt1');
      await provider.getDownloadUrl(results.single);

      expect(adapter.requests.first.uri.host, 'api.opensubtitles.com');
      expect(adapter.requests[1].uri.host, 'vip-api.opensubtitles.com');
      expect(adapter.requests.last.uri.path, endsWith('/download'));
      expect(adapter.requests.last.uri.host, 'vip-api.opensubtitles.com');
    });
  });

  group('SubDL', () {
    test("sends a 'tt'-prefixed imdb_id plus season/episode", () async {
      final (dio, adapter) = _dio(
        (_) => {
          'status': true,
          'subtitles': [
            {
              'id': 7,
              'release_name': 'Show.S02E05',
              'language': 'en',
              'url': '/subtitle/7.zip',
              'hi': 0,
            },
          ],
        },
      );
      final results = await SubDLProvider(dio, apiKey: 'key').search(
        query: 'The Show',
        imdbId: '0903747',
        tmdbId: 1396,
        season: 2,
        episode: 5,
        language: 'en',
      );

      final q = adapter.requests.single.uri.queryParameters;
      expect(q['imdb_id'], 'tt0903747');
      expect(q['season_number'], '2');
      expect(q['episode_number'], '5');
      expect(q['api_key'], 'key');
      expect(q, isNot(contains('tmdb_id')));
      expect(q, isNot(contains('film_name')));
      expect(results.single.downloadUrl, 'https://dl.subdl.com/subtitle/7.zip');
    });

    test("an already 'tt'-prefixed id is not doubled", () async {
      final (dio, adapter) = _dio(
        (_) => {'status': true, 'subtitles': <Object>[]},
      );
      await SubDLProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'x', imdbId: 'tt0903747');
      expect(
        adapter.requests.single.uri.queryParameters['imdb_id'],
        'tt0903747',
      );
    });

    test(
      'without an API key it returns [] and never hits the network',
      () async {
        final (dio, adapter) = _dio(
          (_) => {'status': true, 'subtitles': <Object>[]},
        );
        final results = await SubDLProvider(
          dio,
        ).search(query: 'x', imdbId: 'tt0903747');
        expect(results, isEmpty);
        expect(adapter.requests, isEmpty);
      },
    );

    // As SubDL answers (2026-10-11): ten results unless asked for more, and
    // no id on any of them.
    test('asks for thirty results, the most SubDL gives', () async {
      final (dio, adapter) = _dio(
        (_) => {'status': true, 'subtitles': <Object>[]},
      );
      await SubDLProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'x', imdbId: 'tt0903747', season: 2, episode: 5);
      expect(
        adapter.requests.single.uri.queryParameters['subs_per_page'],
        '30',
      );
    });

    test('gives each result its own id, from its download', () async {
      final (dio, _) = _dio(
        (_) => {
          'status': true,
          'subtitles': [
            {'release_name': 'A', 'url': '/subtitle/3602674-8520054.zip'},
            {'release_name': 'B', 'url': '/subtitle/3602675-8520055.zip'},
          ],
        },
      );
      final results = await SubDLProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'x', imdbId: 'tt0133093');
      expect(results.map((s) => s.id), [
        '3602674-8520054',
        '3602675-8520055',
      ]);
    });

    test('reads hearing impaired as SubDL sends it', () async {
      final (dio, _) = _dio(
        (_) => {
          'status': true,
          'subtitles': [
            {'release_name': 'A', 'url': '/subtitle/1.zip', 'hi': true},
            {'release_name': 'B', 'url': '/subtitle/2.zip', 'hi': false},
          ],
        },
      );
      final results = await SubDLProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'x', imdbId: 'tt0133093');
      expect(results.map((s) => s.isHearingImpaired), [true, false]);
    });

    // An episode's search also lists the season's other episodes: Breaking
    // Bad S02E05 came with two of E01 and 21 season packs before its own six.
    test('keeps the episode and the season packs, the episode first', () async {
      final (dio, _) = _dio(
        (_) => {
          'status': true,
          'subtitles': [
            {'release_name': 'Pack', 'url': '/subtitle/1.zip', 'season': 2},
            {
              'release_name': 'E01',
              'url': '/subtitle/2.zip',
              'season': 2,
              'episode': 1,
            },
            {
              'release_name': 'E05',
              'url': '/subtitle/3.zip',
              'season': 2,
              'episode': 5,
            },
            {
              'release_name': 'E04-E06',
              'url': '/subtitle/4.zip',
              'season': 2,
              'episode_from': 4,
              'episode_end': 6,
            },
            {
              'release_name': 'E07-E09',
              'url': '/subtitle/5.zip',
              'season': 2,
              'episode_from': 7,
              'episode_end': 9,
            },
          ],
        },
      );
      final provider = SubDLProvider(dio, apiKey: 'key');
      final results = await provider.search(
        query: 'x',
        imdbId: 'tt0903747',
        season: 2,
        episode: 5,
      );
      expect(results.map((s) => s.name), ['E05', 'Pack', 'E04-E06']);

      // The season-only pass keeps them all.
      final season = await provider.search(
        query: 'x',
        imdbId: 'tt0903747',
        season: 2,
      );
      expect(season, hasLength(5));
    });

    // SubDL files Brazil's Portuguese and Chinese beside another apart: pt
    // alone found 1 subtitle of Top Gun: Maverick, br_pt,pt 6.
    test('asks for Portuguese and Chinese by their variants', () async {
      for (final (code, codes) in const [
        ('pt', 'br_pt,pt'),
        ('zh', 'zh,zh_bg'),
        ('en', 'en'),
      ]) {
        final (dio, adapter) = _dio(
          (_) => {'status': true, 'subtitles': <Object>[]},
        );
        await SubDLProvider(
          dio,
          apiKey: 'key',
        ).search(query: 'x', imdbId: 'tt1745960', language: code);
        expect(
          adapter.requests.single.uri.queryParameters['languages'],
          codes,
          reason: code,
        );
      }
    });
  });

  // The player names a language by its ISO 639-1 code - Filipino by its ISO
  // 639-2 one, which none of the services takes - and each service is asked
  // in its own terms.
  group('the language a search is asked in', () {
    test('Filipino is Tagalog to OpenSubtitles', () async {
      final (dio, adapter) = _dio((_) => {'data': <Object?>[]});
      await OpenSubtitlesProvider(
        dio,
        apiKey: _kTestKey,
      ).search(query: 'Heneral Luna', language: 'fil');

      expect(adapter.requests.single.uri.queryParameters['languages'], 'tl');
    });

    test('and to SubDL', () async {
      final (dio, adapter) = _dio(
        (_) => {'status': true, 'subtitles': <Object?>[]},
      );
      await SubDLProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'Heneral Luna', language: 'fil');

      expect(adapter.requests.single.uri.queryParameters['languages'], 'tl');
    });

    // As subsource.net names them in its language table (2026-10-11:
    // farsi_persian, thai, chinese_bg_code - Simplified; big_5_code is
    // Traditional - azerbaijani, and tagalog beside filipino).
    test('SubSource is asked by the names its site gives languages', () async {
      Object? respond(RequestOptions request) =>
          request.uri.path.endsWith('/movies/search')
          ? {
              'data': [
                {'movieId': 77, 'title': 'The Show'},
              ],
            }
          : {
              'data': {'results': <Object?>[]},
            };
      // With a key as without: every Chinese the site has, and both names
      // Filipino is filed under (its API takes them comma-separated).
      for (final (code, name) in const [
        ('fa', 'farsi_persian'),
        ('th', 'thai'),
        (
          'zh',
          'chinese,chinese_simplified,chinese_traditional,chinese_bg_code,'
              'big_5_code,chinese_bilingual,chinese_cantonese',
        ),
        ('az', 'azerbaijani'),
        ('fil', 'filipino,tagalog'),
        ('en', 'english'),
      ]) {
        final (dio, adapter) = _dio(respond);
        await SubSourceProvider(
          dio,
          apiKey: 'key',
        ).search(query: 'The Show', imdbId: '0903747', language: code);

        expect(
          adapter.requests.last.uri.queryParameters['language'],
          name,
          reason: code,
        );
      }
    });
  });

  group('SubSource V1 (API key)', () {
    Object? respond(RequestOptions request) {
      if (request.uri.path.endsWith('/movies/search')) {
        return {
          'data': [
            {'movieId': 77, 'title': 'The Show'},
          ],
        };
      }
      if (request.uri.path.endsWith('/subtitles')) {
        return {
          'data': {
            'results': [
              {'subtitleId': 1, 'releaseInfo': 'The.Show.S02E05.1080p'},
              {'subtitleId': 2, 'releaseInfo': 'The.Show.S02E06.1080p'},
              {'subtitleId': 3, 'releaseInfo': 'The.Show.Season.2.Pack'},
              {
                'subtitleId': 4,
                'releaseInfo': ['The.Show.S02E05.WEB', 'alt'],
              },
            ],
          },
        };
      }
      fail('unexpected request ${request.uri}');
    }

    test(
      'sends searchType=imdb with a tt id and never a tmdb parameter',
      () async {
        final (dio, adapter) = _dio(respond);
        await SubSourceProvider(dio, apiKey: 'key').search(
          query: 'The Show',
          imdbId: '0903747',
          tmdbId: 1396,
          season: 2,
          episode: 5,
          language: 'en',
        );

        expect(adapter.requests, hasLength(2));
        final search = adapter.requests[0];
        expect(search.uri.path, endsWith('/movies/search'));
        expect(search.uri.queryParameters['searchType'], 'imdb');
        expect(search.uri.queryParameters['imdb'], 'tt0903747');
        expect(search.headers['X-API-Key'], 'key');

        final subs = adapter.requests[1];
        expect(subs.uri.path, endsWith('/subtitles'));
        expect(subs.uri.queryParameters['movieId'], '77');
        expect(subs.uri.queryParameters['language'], 'english');

        for (final request in adapter.requests) {
          final flat = request.uri.query.toLowerCase();
          expect(flat, isNot(contains('tmdb')), reason: request.uri.toString());
          expect(flat, isNot(contains('1396')), reason: request.uri.toString());
        }
      },
    );

    test('filters results by the E{nn} tag when episode is set', () async {
      final (dio, _) = _dio(respond);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2, episode: 5);
      expect(results.map((s) => s.id), ['1', '4']);
      expect(results.first.metadata?['mode'], 'v1');
      expect(
        results.first.downloadUrl,
        'https://api.subsource.net/api/v1/subtitles/1/download',
      );
    });

    test('episode null (season-only pass) keeps every result', () async {
      final (dio, _) = _dio(respond);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2);
      expect(results.map((s) => s.id), ['1', '2', '3', '4']);
    });

    test('episode 0 is "unknown" and does not filter', () async {
      final (dio, _) = _dio(respond);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 0, episode: 0);
      expect(results, hasLength(4));
    });

    // V1's /subtitles takes movieId + language only, so one multi-season show
    // comes back as a single list of every season. Matching E{nn} alone would
    // hand S01E05 and S03E05 to a viewer watching S02E05.
    Object? respondMultiSeason(RequestOptions request) {
      if (request.uri.path.endsWith('/movies/search')) {
        return {
          'data': [
            {'movieId': 77, 'title': 'The Show'},
          ],
        };
      }
      if (request.uri.path.endsWith('/subtitles')) {
        return {
          'data': {
            'results': [
              {'subtitleId': 1, 'releaseInfo': 'The.Show.S01E05.1080p'},
              {'subtitleId': 2, 'releaseInfo': 'The.Show.S02E05.1080p'},
              {'subtitleId': 3, 'releaseInfo': 'The.Show.S03E05.1080p'},
              {'subtitleId': 4, 'releaseInfo': 'The.Show.E05.720p'},
              {'subtitleId': 5, 'releaseInfo': 'The.Show.Season.1.Pack'},
              {'subtitleId': 6},
            ],
          },
        };
      }
      fail('unexpected request ${request.uri}');
    }

    test('the E{nn} filter is scoped to the season, not just the '
        'episode', () async {
      final (dio, _) = _dio(respondMultiSeason);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2, episode: 5);
      // Only S02E05. Never S01E05/S03E05, and never the season-less E05,
      // which cannot be proven to be this season.
      expect(results.map((s) => s.id), ['2']);
    });

    test('the season-only pass drops other seasons but keeps untagged '
        'entries', () async {
      final (dio, _) = _dio(respondMultiSeason);
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2);
      // '2' is S02; '4' (E05, no season) and '6' (no release name at all)
      // declare no season, so the fallback pass still surfaces them.
      // '1'/'3'/'5' positively declare another season.
      expect(results.map((s) => s.id), ['2', '4', '6']);
    });

    test('opens the season being watched, not the first season listed', () async {
      // SubSource lists a show once per season, each with its own id.
      final (dio, adapter) = _dio((request) {
        if (request.uri.path.endsWith('/movies/search')) {
          return {
            'data': [
              {'movieId': 11, 'title': 'The Show', 'season': 1},
              {'movieId': 22, 'title': 'The Show', 'season': 2},
              {'movieId': 33, 'title': 'The Show', 'season': 3},
            ],
          };
        }
        return {
          'data': {
            'results': [
              {'subtitleId': 1, 'releaseInfo': ['The.Show.S02E05.1080p']},
            ],
          },
        };
      });

      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2, episode: 5);

      expect(adapter.requests[1].uri.queryParameters['movieId'], '22');
      expect(results.map((s) => s.id), ['1']);
    });

    test('never opens another show\'s season from a text search', () async {
      // A text search lists other shows too; their season 2 is no answer.
      final (dio, adapter) = _dio((request) {
        if (request.uri.path.endsWith('/movies/search')) {
          return {
            'data': [
              {'movieId': 11, 'title': 'The Show', 'season': 1},
              {'movieId': 44, 'title': 'Another Show', 'season': 2},
              {'movieId': 22, 'title': 'The Show', 'season': 2},
            ],
          };
        }
        return {'data': {'results': <Object?>[]}};
      });

      await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', season: 2, episode: 5);

      expect(adapter.requests[1].uri.queryParameters['movieId'], '22');
    });

    test('a film search opens the film, whatever else is listed', () async {
      final (dio, adapter) = _dio((request) {
        if (request.uri.path.endsWith('/movies/search')) {
          return {
            'data': [
              {'movieId': 46839, 'title': 'Inception', 'season': null},
              {'movieId': 143170, 'title': 'Cruel Intentions', 'season': 1},
            ],
          };
        }
        return {'data': {'results': <Object?>[]}};
      });

      await SubSourceProvider(dio, apiKey: 'key').search(query: 'Inception');

      expect(adapter.requests[1].uri.queryParameters['movieId'], '46839');
    });

    // The list comes twenty at a time unless asked for more, a hundred at
    // most: The Matrix has 134 English subtitles, and the first twenty of
    // Breaking Bad's second season held two of E05's six (2026-10-11).
    test('reads every page of a long list, a hundred at a time', () async {
      final (dio, adapter) = _dio((request) {
        if (request.uri.path.endsWith('/movies/search')) {
          return {
            'data': [
              {'movieId': 77, 'title': 'The Film'},
            ],
          };
        }
        final page = int.parse(request.uri.queryParameters['page'] ?? '1');
        return {
          'data': [
            for (var i = 0; i < (page == 1 ? 3 : 2); i++)
              {
                'subtitleId': page * 10 + i,
                'language': 'english',
                'releaseInfo': ['The.Film.$page.$i'],
              },
          ],
          'pagination': {'page': page, 'limit': 100, 'total': 5, 'pages': 2},
        };
      });
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Film', imdbId: 'tt1', language: 'en');

      final pages = adapter.requests.skip(1).toList();
      expect(pages.map((r) => r.uri.queryParameters['page']), ['1', '2']);
      expect(pages.map((r) => r.uri.queryParameters['limit']), ['100', '100']);
      expect(results, hasLength(5));
      // Labelled with the language asked for, as without a key.
      expect(results.first.language, 'en');
    });

    // A subtitle lists every release it fits; the episode may be named only
    // in a later one (2026-10-11: one of Breaking Bad S02E05's six).
    test('finds the episode in any of a subtitle\'s release names', () async {
      final (dio, _) = _dio((request) {
        if (request.uri.path.endsWith('/movies/search')) {
          return {
            'data': [
              {'movieId': 22, 'title': 'The Show', 'season': 2},
            ],
          };
        }
        return {
          'data': [
            {
              'subtitleId': 1,
              // As SubSource sends some: with a space around.
              'releaseInfo': ['The.Show.Season.2.WEB', ' The.Show.S02E05.WEB '],
            },
            {
              'subtitleId': 2,
              'releaseInfo': ['The.Show.S02E06.WEB'],
            },
          ],
        };
      });
      final results = await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', imdbId: 'tt1', season: 2, episode: 5);
      expect(results.map((s) => s.id), ['1']);
      expect(results.single.name, 'The.Show.S02E05.WEB');
    });

    test('reads five pages at most', () async {
      final (dio, adapter) = _dio((request) {
        if (request.uri.path.endsWith('/movies/search')) {
          return {
            'data': [
              {'movieId': 77, 'title': 'The Film'},
            ],
          };
        }
        return {
          'data': [
            {
              'subtitleId': 1,
              'releaseInfo': ['x'],
            },
          ],
          'pagination': {'page': 1, 'limit': 100, 'total': 900, 'pages': 9},
        };
      });
      await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Film', imdbId: 'tt1');
      expect(adapter.requests, hasLength(1 + 5));
    });

    test('a tmdb-only target is a title search (searchType=text)', () async {
      final (dio, adapter) = _dio(respond);
      await SubSourceProvider(
        dio,
        apiKey: 'key',
      ).search(query: 'The Show', tmdbId: 1396);
      final search = adapter.requests.first;
      expect(search.uri.queryParameters['searchType'], 'text');
      expect(search.uri.queryParameters['q'], 'The Show');
      expect(search.uri.queryParameters, isNot(contains('imdb')));
    });
  });

  // Without a key SubSource is asked the way its own site asks it: the old
  // keyless endpoints under /api answer 404 (2026-10-11), and the site's API
  // needs no key. A search names the film or show, a show's season is a list
  // of its own, and a subtitle's page hands out its download token.
  group('SubSource without a key', () {
    const show = {
      'id': 22748,
      'title': 'The Show',
      'type': 'tvseries',
      'link': '/series/the-show',
      'seasons': [
        {'season': 1, 'id': 26604, 'link': '/subtitles/the-show/season=1'},
        {'season': 2, 'id': 23145, 'link': '/subtitles/the-show/season=2'},
      ],
    };

    Object? Function(RequestOptions) site(List<Object?> found) =>
        (request) {
          final path = request.uri.path;
          if (path.endsWith('/v1/movie/search')) {
            return {'success': true, 'results': found};
          }
          if (path.contains('/v1/subtitles/')) {
            return {
              'subtitles': [
                {
                  'id': 1,
                  'language': 'english',
                  'release_info': 'The.Show.S02E05.720p',
                  'hearing_impaired': 0,
                  'link': 'the-show/english/1',
                },
                {
                  'id': 2,
                  'language': 'english',
                  'release_info': 'The.Show.S02E06.720p',
                  'hearing_impaired': 1,
                  'link': 'the-show/english/2',
                },
              ],
            };
          }
          if (path.endsWith('/v1/subtitle/the-show/english/1')) {
            return {
              'subtitle': {'id': 1, 'download_token': 'token1'},
            };
          }
          fail('unexpected request ${request.uri}');
        };

    test('searches by the tt id and opens the season being watched', () async {
      final (dio, adapter) = _dio(site([show]));
      final results = await SubSourceProvider(dio).search(
        query: 'The Show',
        imdbId: '0903747',
        tmdbId: 1396,
        season: 2,
        episode: 5,
        language: 'en',
      );

      expect(adapter.requests, hasLength(2));
      final search = adapter.requests[0];
      expect(search.method, 'POST');
      expect(search.uri.path, endsWith('/v1/movie/search'));
      expect((search.data as Map<String, dynamic>)['query'], 'tt0903747');
      final list = adapter.requests[1];
      expect(list.uri.path, endsWith('/v1/subtitles/the-show/season-2'));
      expect(list.uri.queryParameters['language'], 'english');
      for (final request in adapter.requests) {
        expect('${request.uri}${request.data}', isNot(contains('1396')));
      }
      expect(results.map((s) => s.id), ['1']);
      expect(results.single.name, 'The.Show.S02E05.720p');
      expect(results.single.language, 'en');
      expect(results.single.metadata?['mode'], 'keyless');
    });

    test('episode null keeps every episode of the season', () async {
      final (dio, _) = _dio(site([show]));
      final results = await SubSourceProvider(
        dio,
      ).search(query: 'The Show', imdbId: 'tt0903747', season: 2);
      expect(results.map((s) => s.id), ['1', '2']);
      expect(results.map((s) => s.isHearingImpaired), [false, true]);
    });

    // The site ranks "Escape The Matrix" above "The Matrix" for "the matrix".
    test('a title search opens the title of that name, not the first', () async {
      final (dio, adapter) = _dio(
        site([
          {
            'id': 9,
            'title': 'Escape The Show',
            'type': 'tvseries',
            'link': '/series/escape-the-show',
          },
          show,
        ]),
      );
      await SubSourceProvider(
        dio,
      ).search(query: 'the show', season: 2, episode: 5);

      expect(
        (adapter.requests[0].data as Map<String, dynamic>)['query'],
        'the show',
      );
      expect(
        adapter.requests[1].uri.path,
        endsWith('/v1/subtitles/the-show/season-2'),
      );
    });

    test('a film opens its own list', () async {
      final (dio, adapter) = _dio(
        site([
          {
            'id': 15185,
            'title': 'The Film',
            'type': 'movie',
            'link': '/subtitles/the-film-1999',
          },
        ]),
      );
      await SubSourceProvider(dio).search(query: 'The Film', imdbId: 'tt1');
      expect(adapter.requests[1].uri.path, endsWith('/v1/subtitles/the-film-1999'));
    });

    test('a season the site has no list for finds nothing', () async {
      final (dio, adapter) = _dio(site([show]));
      final results = await SubSourceProvider(dio).search(
        query: 'The Show',
        imdbId: 'tt0903747',
        season: 3,
        episode: 1,
      );
      expect(results, isEmpty);
      expect(adapter.requests, hasLength(1));
    });

    // The site's own language names (its LANGUAGES table, 2026-10-11): one
    // Chinese pick is every Chinese the site has - on 7 popular films, 94
    // chinese_bg_code, 10 big_5_code and 2 chinese_cantonese - and Filipino
    // is filed under both of its names.
    test('asks for every name the site gives a language', () async {
      for (final (code, names) in const [
        (
          'zh',
          'chinese,chinese_simplified,chinese_traditional,chinese_bg_code,'
              'big_5_code,chinese_bilingual,chinese_cantonese',
        ),
        ('fil', 'filipino,tagalog'),
        ('fa', 'farsi_persian'),
        ('az', 'azerbaijani'),
      ]) {
        final (dio, adapter) = _dio(site([show]));
        await SubSourceProvider(dio).search(
          query: 'The Show',
          imdbId: 'tt0903747',
          season: 2,
          language: code,
        );
        expect(
          adapter.requests[1].uri.queryParameters['language'],
          names,
          reason: code,
        );
      }
    });

    test('a subtitle\'s page hands out its download', () async {
      final (dio, adapter) = _dio(site([show]));
      final provider = SubSourceProvider(dio);
      final results = await provider.search(
        query: 'The Show',
        imdbId: 'tt0903747',
        season: 2,
        episode: 5,
      );

      expect(
        await provider.getDownloadUrl(results.single),
        'https://api.subsource.net/v1/subtitle/download/token1',
      );
      expect(
        adapter.requests.last.uri.path,
        endsWith('/v1/subtitle/the-show/english/1'),
      );
      expect(
        provider.getDownloadHeaders(results.single)['Referer'],
        'https://subsource.net/',
      );
    });

    test('the connection check asks the site', () async {
      final (dio, adapter) = _dio(site([show]));
      expect(await SubSourceProvider(dio).verifyKey(), isTrue);
      expect(adapter.requests.single.uri.path, endsWith('/v1/movie/search'));
    });
  });
}

/// Fails the test if any request is actually dispatched.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.onCall);
  final void Function() onCall;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onCall();
    return ResponseBody.fromString('{}', 200);
  }
}
