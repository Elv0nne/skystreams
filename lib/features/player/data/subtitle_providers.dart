import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../domain/entity/subtitle_model.dart';

/// The player's language [code] as OpenSubtitles and SubDL take it: their
/// ISO 639-1 codes. Filipino has only an ISO 639-2 code (`fil`); both file it
/// as Tagalog.
String _twoLetterCode(String code) => code == 'fil' ? 'tl' : code;

/// The player's language [code] as SubDL files it: Brazil's Portuguese and
/// Chinese beside another language apart (2026-10-11: `pt` alone found 1
/// subtitle of Top Gun: Maverick, `br_pt,pt` 6).
String _subdlLanguages(String code) => switch (code.toLowerCase()) {
  'pt' => 'br_pt,pt',
  'zh' => 'zh,zh_bg',
  final other => _twoLetterCode(other),
};

/// The player's language [code] as OpenSubtitles files it: Chinese and
/// Portuguese only by their variants - `zh` and `pt` alone find nothing
/// (2026-10-11: Top Gun: Maverick, 7 and 12 by their variants) - sorted, as
/// its documentation asks.
String _openSubtitlesLanguages(String code) => switch (code.toLowerCase()) {
  'zh' => 'ze,zh-cn,zh-tw',
  'pt' => 'pt-br,pt-pt',
  final other => _twoLetterCode(other),
};

class OpenSubtitlesProvider extends SubtitleProvider {
  final Dio _dio;
  final String? _apiKey;
  static const String baseUrl = "https://api.opensubtitles.com/api/v1";

  /// Build-time fallback key, supplied by the build rather than the source.
  ///
  /// Pass via: flutter build --dart-define=OPENSUBTITLES_API_KEY=your_key
  ///
  /// This used to be a literal in this file. A key committed to a public
  /// repository is a published key: it is in the history, in every fork and in
  /// every clone, and rotating it is the only remedy. The user's own key from
  /// Settings still takes precedence over this, exactly as before; when neither
  /// is set the provider is simply skipped, which the search flow already
  /// handles because SubDL behaves the same way without a key.
  ///
  /// Public because the Accounts screen has to answer "can this provider run
  /// at all" and must read the same define rather than a second copy of its
  /// name.
  static const String buildTimeApiKey = String.fromEnvironment(
    'OPENSUBTITLES_API_KEY',
  );
  static const String _userAgent = "SkyStream v2.2.1";

  // Auth state
  final String? _username;
  final String? _password;
  String? _token;
  DateTime? _tokenExpiry;

  /// Where requests go: [baseUrl] until a login names the account's own
  /// server - a VIP account's is another - which the documentation says the
  /// rest of the session must use.
  String _apiBase = baseUrl;

  OpenSubtitlesProvider(
    this._dio, {
    String? username,
    String? password,
    String? apiKey,
  }) : _username = username,
       _password = password,
       _apiKey = apiKey;

  String get _effectiveApiKey =>
      (_apiKey != null && _apiKey!.isNotEmpty) ? _apiKey! : buildTimeApiKey;

  Future<void> _loginIfNeeded() async {
    if (_username == null ||
        _username.isEmpty ||
        _password == null ||
        _password!.isEmpty) {
      if (kDebugMode) {
        print("[OpenSubtitles] Skipping login: Credentials not set.");
      }
      return;
    }

    // Token is valid for 24 hours. We re-login if it's missing or expiring in < 5 mins.
    if (_token != null &&
        _tokenExpiry != null &&
        _tokenExpiry!.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return;
    }

    try {
      final response = await _dio.post<dynamic>(
        "$baseUrl/login",
        data: {'username': _username, 'password': _password},
        options: Options(
          headers: {
            ...SubtitleProvider.commonHeaders,
            'user-agent': _userAgent,
            'Content-Type': 'application/json',
            'Api-Key': _effectiveApiKey,
          },
        ),
      );

      if (response.data != null && response.data['token'] != null) {
        _token = response.data?['token'] as String?;
        final host = response.data?['base_url'];
        if (host is String && host.isNotEmpty) {
          final origin = host.startsWith('http') ? host : 'https://$host';
          _apiBase = origin.endsWith('/api/v1') ? origin : '$origin/api/v1';
        }
        _tokenExpiry = DateTime.now().add(
          const Duration(hours: 23),
        ); // OS tokens last 24h
        if (kDebugMode) {
          print(
            "[OpenSubtitles] Auth Success. Token: ${_token?.substring(0, 10)}...",
          );
        }
      }
    } catch (e) {
      if (e is DioException) {
        final errorBody = e.response?.data;
        if (kDebugMode) {
          print("[OpenSubtitles] Login failed: ${e.message}");
          if (errorBody != null) {
            print("[OpenSubtitles] Error body: $errorBody");
          }
        }
      } else if (kDebugMode) {
        print("[OpenSubtitles] Login error: $e");
      }
    }
  }

  /// Verifies if the credentials are valid by performing a login.
  Future<bool> verifyCredentials() async {
    if (_username == null ||
        _username.isEmpty ||
        _password == null ||
        _password!.isEmpty) {
      return false;
    }
    if (kDebugMode) {
      final keyType = (_apiKey != null && _apiKey!.isNotEmpty)
          ? "User"
          : "Default";
      final maskedKey = _effectiveApiKey.length > 5
          ? "${_effectiveApiKey.substring(0, 5)}..."
          : _effectiveApiKey;
      print(
        "[OpenSubtitles] Verifying Credentials (Mode: $keyType) for: $_username (Key: $maskedKey)",
      );
    }
    try {
      final response = await _dio.post<dynamic>(
        "$baseUrl/login",
        data: {'username': _username, 'password': _password},
        options: Options(
          headers: {
            ...SubtitleProvider.commonHeaders,
            'user-agent': _userAgent,
            'Content-Type': 'application/json',
            'Api-Key': _effectiveApiKey,
          },
        ),
      );
      return response.data != null && response.data['token'] != null;
    } catch (e) {
      return false;
    }
  }

  @override
  String get name => "OpenSubtitles";

  @override
  String get idPrefix => "opensubtitles";

  @override
  Future<List<OnlineSubtitle>> search({
    required String query,
    String? imdbId,
    int? tmdbId,
    int? season,
    int? episode,
    String? language,
    CancelToken? cancelToken,
  }) async {
    // No key, no request. The key now comes from the build or the viewer's
    // own Settings entry rather than from a literal in this file, so a build
    // with neither must degrade the way SubDL already does - return nothing
    // and let the other providers answer - rather than send an empty Api-Key
    // header and surface the 401 as "search failed".
    if (_effectiveApiKey.isEmpty) return const <OnlineSubtitle>[];
    if (kDebugMode) {
      final keyType = (_apiKey != null && _apiKey!.isNotEmpty)
          ? "User"
          : "Default";
      final maskedKey = _effectiveApiKey.length > 5
          ? "${_effectiveApiKey.substring(0, 5)}..."
          : _effectiveApiKey;
      print(
        "[OpenSubtitles] Search (Mode: $keyType): query=$query, imdb=$imdbId, lang=$language (Key: $maskedKey, Agent: $_userAgent)",
      );
    }
    try {
      final String langTag = _twoLetterCode(language ?? "en");

      // As the documentation asks: an episode by its show's id with the
      // season and episode, ids without leading zeros, the text in lower
      // case and the parameters in alphabetical order - or the search is
      // redirected first.
      final params = SplayTreeMap<String, dynamic>();
      params['languages'] = _openSubtitlesLanguages(language ?? "en");
      final episodic =
          (season != null && season > 0) || (episode != null && episode > 0);
      final imdb = imdbId == null
          ? null
          : int.tryParse(imdbId.replaceAll('tt', ''));
      if (imdb != null) {
        params[episodic ? 'parent_imdb_id' : 'imdb_id'] = imdb;
      } else if (tmdbId != null) {
        params[episodic ? 'parent_tmdb_id' : 'tmdb_id'] = tmdbId;
      } else {
        params['query'] = query.toLowerCase();
      }

      if (season != null && season > 0) params['season_number'] = season;
      if (episode != null && episode > 0) params['episode_number'] = episode;

      await _loginIfNeeded();

      final Map<String, String> headers = {
        ...SubtitleProvider.commonHeaders,
        'user-agent': _userAgent,
        'Api-Key': _effectiveApiKey,
      };

      if (_token != null) {
        headers['Authorization'] = 'Bearer $_token';
      }

      try {
        final response = await _dio.get<dynamic>(
          "$_apiBase/subtitles",
          queryParameters: params,
          cancelToken: cancelToken,
          options: Options(headers: headers),
        );

        if (response.data == null || response.data['data'] == null) return [];

        final List<dynamic> results = response.data['data'] as List;
        if (kDebugMode) {
          debugPrint("[OpenSubtitles] Found ${results.length} results.");
        }

        return results.map((dynamic item) {
          final attr = (item as Map)['attributes'] as Map<String, dynamic>;
          final files = attr['files'] as List;
          final file = files.isNotEmpty ? files.first as Map : null;
          final featureDetails = attr['feature_details'] as Map?;

          final name =
              (attr['release'] as String?) ??
              (featureDetails?['title'] as String?) ??
              (featureDetails?['movie_name'] as String?) ??
              query;

          return OnlineSubtitle(
            id: file != null
                ? file['file_id'].toString()
                : item['id'].toString(),
            name: name,
            language: (attr['language'] as String?) ?? langTag,
            source: this.name,
            downloadUrl: "", // Requires getDownloadUrl
            isHearingImpaired: (attr['hearing_impaired'] as bool?) ?? false,
            metadata: {'file_id': file != null ? file['file_id'] : null},
          );
        }).toList();
      } on DioException catch (e) {
        // If 401/403, our token might be invalid. Clear and retry once.
        if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
          if (kDebugMode) {
            print(
              "[OpenSubtitles] Auth Error (${e.response?.statusCode}): ${e.response?.data}. Retrying with fresh login...",
            );
          }
          _token = null;
          _tokenExpiry = null;
          await _loginIfNeeded();

          // Refresh headers with new token
          final Map<String, String> retryHeaders = {
            ...SubtitleProvider.commonHeaders,
            'user-agent': _userAgent,
            'Api-Key': _effectiveApiKey,
          };
          if (_token != null) {
            retryHeaders['Authorization'] = 'Bearer $_token';
          }

          final retryResponse = await _dio.get<dynamic>(
            "$_apiBase/subtitles",
            queryParameters: params,
            cancelToken: cancelToken,
            options: Options(headers: retryHeaders),
          );

          if (retryResponse.data == null ||
              retryResponse.data['data'] == null) {
            return [];
          }

          final List<dynamic> results = retryResponse.data['data'] as List;
          return results.map((dynamic item) {
            final attr = (item as Map)['attributes'] as Map<String, dynamic>;
            final files = attr['files'] as List;
            final file = files.isNotEmpty ? files.first as Map : null;
            return OnlineSubtitle(
              id: file != null
                  ? file['file_id'].toString()
                  : item['id'].toString(),
              name: (attr['release'] as String?) ?? query,
              language: (attr['language'] as String?) ?? langTag,
              source: name,
              downloadUrl: "",
              isHearingImpaired: (attr['hearing_impaired'] as bool?) ?? false,
              metadata: {'file_id': file != null ? file['file_id'] : null},
            );
          }).toList();
        }
        rethrow;
      }
    } catch (e) {
      if (e is! DioException || e.type != DioExceptionType.cancel) {
        if (kDebugMode) print("OpenSubtitles search failed: $e");
      }
      return [];
    }
  }

  @override
  Future<String?> getDownloadUrl(OnlineSubtitle subtitle) async {
    final fileId = subtitle.metadata?['file_id'];
    if (fileId == null) return null;

    try {
      await _loginIfNeeded();
      final Map<String, String> headers = {
        ...SubtitleProvider.commonHeaders,
        'user-agent': _userAgent,
        'Content-Type': 'application/json',
        'Api-Key': _effectiveApiKey,
      };
      if (_token != null) {
        headers['Authorization'] = 'Bearer $_token';
      }

      final response = await _dio.post<dynamic>(
        "$_apiBase/download",
        data: {'file_id': fileId},
        options: Options(headers: headers),
      );

      if (response.data != null && response.data?['link'] != null) {
        return response.data?['link'] as String?;
      }
    } catch (e) {
      if (kDebugMode) print("OpenSubtitles download failed: $e");
    }
    return null;
  }

  @override
  Map<String, String> getDownloadHeaders(OnlineSubtitle subtitle) {
    // OpenSubtitles download links are CDN URLs that don't need auth headers
    return SubtitleProvider.commonHeaders;
  }
}

/// Provider for SubDL.com.
class SubDLProvider extends SubtitleProvider {
  final Dio _dio;
  static const String baseUrl = "https://api.subdl.com/api/v1/subtitles";
  static const String downloadBaseUrl = "https://dl.subdl.com";
  static const String authUrl = "https://apiold.subdl.com";
  String? _apiKey;
  String? _email;
  String? _password;

  SubDLProvider(this._dio, {String? apiKey, String? email, String? password})
    : _apiKey = apiKey,
      _email = email,
      _password = password;

  String? get searchApiKey => _apiKey;

  @override
  String get name => "SubDL";

  @override
  String get idPrefix => "subdl";

  @override
  Future<List<OnlineSubtitle>> search({
    required String query,
    String? imdbId,
    int? tmdbId,
    int? season,
    int? episode,
    String? language,
    CancelToken? cancelToken,
  }) async {
    try {
      if (_apiKey == null || _apiKey!.isEmpty) {
        if (kDebugMode) print("[SubDL] Skipping search: API Key not set.");
        return [];
      }

      final String langCode = _twoLetterCode(language ?? "en");
      final Map<String, dynamic> params = {
        'api_key': _apiKey!,
        'languages': _subdlLanguages(language ?? "en"),
        // The most SubDL gives at once. Its default of ten was often all
        // season packs and nothing of the episode itself.
        'subs_per_page': 30,
      };

      if (imdbId != null) {
        params['imdb_id'] = imdbId.startsWith('tt') ? imdbId : 'tt$imdbId';
      } else if (tmdbId != null) {
        params['tmdb_id'] = tmdbId;
      } else {
        params['film_name'] = query;
      }

      if (season != null && season > 0) params['season_number'] = season;
      if (episode != null && episode > 0) params['episode_number'] = episode;

      if (kDebugMode) {
        final maskedKey = _apiKey!.length > 5
            ? "${_apiKey!.substring(0, 5)}..."
            : "None";
        print(
          "[SubDL] Search: query=$query, imdb=$imdbId, lang=$langCode (Key: $maskedKey)",
        );
      }

      final response = await _dio.get<dynamic>(
        baseUrl,
        queryParameters: params,
        cancelToken: cancelToken,
        options: Options(
          headers: SubtitleProvider.commonHeaders,
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
        ),
      );

      if (response.data == null || response.data['status'] != true) return [];

      final List<dynamic> data =
          (response.data['subtitles'] as List?) ?? const <dynamic>[];
      if (kDebugMode) debugPrint("[SubDL] Found ${data.length} results.");

      final exact = <OnlineSubtitle>[];
      final packs = <OnlineSubtitle>[];
      for (final item in data.whereType<Map<dynamic, dynamic>>()) {
        final fit = _fits(item, episode);
        if (fit == _Fit.other) continue;
        final String rawUrl = (item['url'] as String?) ?? "";
        // SubDL returns relative paths like /subtitle/123.zip
        // Must prepend the download CDN base URL
        final String fullUrl = rawUrl.isNotEmpty
            ? "$downloadBaseUrl${rawUrl.startsWith('/') ? rawUrl : '/$rawUrl'}"
            : "";
        final String release =
            (item['release_name'] as String?) ??
            (item['fileName'] as String?) ??
            query;
        final subtitle = OnlineSubtitle(
          // SubDL gives its results no id: the file's name in its download
          // path is each one's own.
          id: _idOf(rawUrl) ?? release,
          name: release,
          language: (item['language'] as String?) ?? langCode,
          source: name,
          downloadUrl: fullUrl,
          isHearingImpaired: item['hi'] == true || item['hi'] == 1,
          metadata: {'url': fullUrl},
        );
        (fit == _Fit.exact ? exact : packs).add(subtitle);
      }
      return [...exact, ...packs];
    } catch (e) {
      if (e is! DioException || e.type != DioExceptionType.cancel) {
        if (kDebugMode) debugPrint("SubDL search error: $e");
      }
      return [];
    }
  }

  /// The name of the file [url] downloads - `3602674-8520054` of
  /// `/subtitle/3602674-8520054.zip?api_key=…` - or null.
  static String? _idOf(String url) {
    final file = (Uri.tryParse(url)?.path ?? '').split('/').last;
    final dot = file.lastIndexOf('.');
    final id = dot > 0 ? file.substring(0, dot) : file;
    return id.isEmpty ? null : id;
  }

  /// How a result of an [episode]'s search fits it. SubDL lists the season's
  /// other episodes too (2026-10-11: Breaking Bad S02E05 came with two of
  /// E01 and 21 season packs beside its own six): one naming an episode must
  /// name this one, a range must take it in, and one naming none is a pack,
  /// kept for its file of the episode.
  static _Fit _fits(Map<dynamic, dynamic> item, int? episode) {
    if (episode == null || episode <= 0) return _Fit.pack;
    final own = item['episode'];
    if (own is int && own > 0) return own == episode ? _Fit.exact : _Fit.other;
    final from = item['episode_from'];
    final to = item['episode_end'];
    if (from is int && to is int && from > 0 && to >= from) {
      return episode >= from && episode <= to ? _Fit.pack : _Fit.other;
    }
    return _Fit.pack;
  }

  @override
  Future<String?> getDownloadUrl(OnlineSubtitle subtitle) async {
    return subtitle.metadata?['url'] as String?;
  }

  @override
  Map<String, String> getDownloadHeaders(OnlineSubtitle subtitle) {
    return SubtitleProvider.commonHeaders;
  }

  /// Verifies if the API key is valid by performing a dummy search.
  Future<bool> verifyKey() async {
    if (_apiKey != null && _apiKey!.isNotEmpty) {
      try {
        final response = await _dio.get<dynamic>(
          baseUrl,
          queryParameters: {
            'api_key': _apiKey!,
            'film_name': 'Inception',
            'languages': 'en',
          },
          options: Options(headers: SubtitleProvider.commonHeaders),
        );
        final bool isValid =
            response.data != null && response.data?['status'] == true;
        if (kDebugMode && !isValid) {
          debugPrint(
            "[SubDL] Key Verification Failed: ${response.statusCode} - ${response.data}",
          );
        }
        return isValid;
      } catch (e) {
        if (kDebugMode) {
          if (e is DioException) {
            print(
              "[SubDL] Key Verification Error: ${e.response?.statusCode} - ${e.response?.data}",
            );
          } else {
            print("[SubDL] Key Verification Exception: $e");
          }
        }
        // Fall through to login if key fails
      }
    }

    if (_email != null && _password != null) {
      return (await login(_email!, _password!)).key != null;
    }

    return false;
  }

  /// Authenticats with SubDL using Email/Password and fetches the user's API key.

  Future<({String? key, String? error})> login(
    String email,
    String password,
  ) async {
    try {
      if (kDebugMode) print("[SubDL] Logging in for: $email");

      // 1. Post to login
      final loginResponse = await _dio.post<Map<String, dynamic>>(
        "$authUrl/login",
        data: {'email': email, 'password': password},
      );

      if (kDebugMode) {
        print("[SubDL] Login Status: ${loginResponse.statusCode}");
      }

      if (loginResponse.data == null || loginResponse.data?['token'] == null) {
        final errorMsg =
            loginResponse.data?['error'] ?? "Login failed. Check credentials.";
        if (kDebugMode) print("[SubDL] Auth failed: $errorMsg");
        return (key: null as String?, error: errorMsg as String?);
      }

      final String jwtToken = loginResponse.data?['token'] as String;

      // 2. Fetch API Key
      final apiResponse = await _dio.get<Map<String, dynamic>>(
        "$authUrl/user/userApi",
        options: Options(
          headers: {
            'Authorization': 'Bearer $jwtToken',
            'Accept': 'application/json',
          },
        ),
      );

      if (apiResponse.data != null && apiResponse.data?['api_key'] != null) {
        _apiKey = apiResponse.data?['api_key'] as String?;
        _email = email;
        _password = password;
        if (kDebugMode) {
          print(
            "[SubDL] Login Success: API Key fetched: ${_apiKey!.substring(0, 5)}...",
          );
        }
        return (key: _apiKey, error: null);
      }
    } catch (e) {
      if (kDebugMode) {
        if (e is DioException) {
          final msg =
              e.response?.data?['error'] ??
              "Network error: ${e.response?.statusCode}";
          print("[SubDL] Fetch error: $msg");
          return (key: null as String?, error: msg as String?);
        } else {
          print("[SubDL] Login exception: $e");
          return (key: null as String?, error: e.toString() as String?);
        }
      }
    }
    return (key: null as String?, error: "Authentication failed." as String?);
  }
}

/// How a SubDL result fits the episode searched for: its own subtitle, one
/// of its season's packs, or another episode's.
enum _Fit { exact, pack, other }

/// Provider for SubSource.net.
/// Supports dual-mode: keyless (the site's own API) and authenticated (v1).
class SubSourceProvider extends SubtitleProvider {
  final Dio _dio;
  static const String baseUrlV1 = "https://api.subsource.net/api/v1";

  /// The API subsource.net's own pages use, which needs no key. The keyless
  /// endpoints SkyStream used before (`/api/searchMovie` and the rest) answer
  /// 404 since 2026.
  static const String baseUrlSite = "https://api.subsource.net/v1";

  /// V1 lists twenty subtitles at a time unless asked for more, a hundred at
  /// most (2026-10-11: The Matrix has 134 in English); a search reads up to
  /// [_maxPages] of them.
  static const int _pageSize = 100;
  static const int _maxPages = 5;
  final String? _apiKey;

  SubSourceProvider(this._dio, {String? apiKey}) : _apiKey = apiKey;

  @override
  String get name => "SubSource";

  @override
  String get idPrefix => "subsource";

  String _parseString(dynamic value, String defaultValue) {
    if (value == null) return defaultValue;
    if (value is String) return value;
    if (value is Iterable && value.isNotEmpty) return value.first.toString();
    return value.toString();
  }

  /// Neither SubSource endpoint filters by episode, so both paths keep only
  /// releases whose name carries the `E{nn}` tag (CloudStream does the same).
  /// A season pack named without the tag is dropped here; the notifier's
  /// season-only fallback pass (episode null) is what surfaces it.
  ///
  /// This is the episode half only. The keyless path is already scoped to one
  /// season server-side (`getMovie` takes `season-{n}`), so the episode tag is
  /// all it needs; V1 has no season parameter and must additionally go through
  /// [_matchesSeasonEpisode].
  static bool _matchesEpisode(String releaseName, int? episode) {
    if (episode == null || episode <= 0) return true;
    final epTag = "E${episode.toString().padLeft(2, '0')}";
    return releaseName.contains(epTag);
  }

  /// `S02E05`, `s2e5`, `S02.E05` — the season/episode pair in a release name.
  static final RegExp _seasonEpisodeTag = RegExp(
    r'\bs(\d{1,2})[\s._-]*e\d{1,3}\b',
    caseSensitive: false,
  );

  /// A bare season tag: `S02`, `Season 2`, `season.2`.
  static final RegExp _seasonOnlyTag = RegExp(
    r'\bs(?:eason)?[\s._-]*(\d{1,2})\b',
    caseSensitive: false,
  );

  /// The season a release name declares, or null when it declares none.
  static int? _seasonOf(String releaseName) {
    final pair = _seasonEpisodeTag.firstMatch(releaseName);
    if (pair != null) return int.tryParse(pair.group(1)!);
    final solo = _seasonOnlyTag.firstMatch(releaseName);
    if (solo != null) return int.tryParse(solo.group(1)!);
    return null;
  }

  /// V1's `/subtitles` takes movieId + language and nothing else, so one
  /// multi-season show hands back every season's releases in a single list and
  /// the season has to be applied here next to the episode. Matching `E{nn}`
  /// alone would present S01E05 and S03E05 as exact matches for S02E05.
  ///
  /// An entry whose own season cannot be read is ambiguous: it is dropped from
  /// an exact episode match rather than shown as one, but kept for the
  /// season-only fallback pass, which exists precisely to surface untagged
  /// season packs. That pass still drops anything that positively declares a
  /// different season.
  /// The search result to list subtitles for: the best match's entry for
  /// [season] when its show is listed once per season, as SubSource lists
  /// them - each season its own id, and /subtitles only ever sees the one id
  /// asked for. Taking the first entry found subtitles for season one alone.
  ///
  /// Only the same show's seasons are considered: a text search lists other
  /// shows too, and their season [season] is no answer. The first entry
  /// otherwise - a film, or a show listed once.
  static dynamic _entryForSeason(List<dynamic> entries, int? season) {
    final first = entries.first;
    if (season != null && season > 0 && first is Map) {
      final show = '${first['title']}'.trim().toLowerCase();
      for (final entry in entries) {
        if (entry is Map &&
            '${entry['title']}'.trim().toLowerCase() == show &&
            int.tryParse('${entry['season']}') == season) {
          return entry;
        }
      }
    }
    return first;
  }

  static bool _matchesSeasonEpisode(
    String releaseName,
    int? season,
    int? episode,
  ) {
    final wantSeason = (season != null && season > 0) ? season : null;
    final entrySeason = wantSeason == null ? null : _seasonOf(releaseName);
    if (episode == null || episode <= 0) {
      return entrySeason == null || entrySeason == wantSeason;
    }
    if (!_matchesEpisode(releaseName, episode)) return false;
    if (wantSeason == null) return true;
    return entrySeason == wantSeason;
  }

  /// Neither SubSource path has a TMDb parameter: [tmdbId] is ignored, so a
  /// TMDb-only target is a plain title search here (`searchType=text` on V1,
  /// `searchMovie` by title keyless). IMDb ids are sent with their `tt`
  /// prefix. [episode] is applied client-side by release name on both paths,
  /// and on V1 so is [season] (its `/subtitles` endpoint has no season
  /// parameter, so it returns every season of the show at once).
  @override
  Future<List<OnlineSubtitle>> search({
    required String query,
    String? imdbId,
    int? tmdbId,
    int? season,
    int? episode,
    String? language,
    CancelToken? cancelToken,
  }) async {
    // If API key is provided, use the v1 authenticated logic (Mode B)
    if (_apiKey != null && _apiKey!.isNotEmpty) {
      return _searchV1(
        query: query,
        imdbId: imdbId,
        season: season,
        episode: episode,
        language: language,
        cancelToken: cancelToken,
      );
    }

    // Otherwise, as the site's own pages ask (Mode A)
    return _searchKeyless(
      query: query,
      imdbId: imdbId,
      season: season,
      episode: episode,
      language: language,
      cancelToken: cancelToken,
    );
  }

  /// Original v1 implementation for authenticated users.
  Future<List<OnlineSubtitle>> _searchV1({
    required String query,
    String? imdbId,
    int? season,
    int? episode,
    String? language,
    CancelToken? cancelToken,
  }) async {
    if (kDebugMode) {
      final logKey = (_apiKey != null && _apiKey!.length > 5)
          ? "${_apiKey!.substring(0, 5)}..."
          : "None";
      print(
        "[SubSource V1] Search Start: query=$query, imdb=$imdbId (User Key: $logKey)",
      );
    }

    try {
      final Map<String, dynamic> searchParams = {};
      if (imdbId != null) {
        searchParams['searchType'] = 'imdb';
        searchParams['imdb'] = imdbId.startsWith('tt') ? imdbId : 'tt$imdbId';
      } else {
        searchParams['searchType'] = 'text';
        searchParams['q'] = query;
      }

      final searchResponse = await _dio.get<Map<String, dynamic>>(
        "$baseUrlV1/movies/search",
        queryParameters: searchParams,
        cancelToken: cancelToken,
        options: Options(
          headers: {...SubtitleProvider.commonHeaders, 'X-API-Key': _apiKey!},
        ),
      );

      if (searchResponse.data == null || searchResponse.data?['data'] == null) {
        return [];
      }
      final List<dynamic> movies = searchResponse.data?['data'] as List? ?? [];
      if (movies.isEmpty) return [];

      final movie = _entryForSeason(movies, season);
      final movieId = movie['movieId'] ?? movie['id'];

      final Map<String, dynamic> subParams = {
        'movieId': movieId,
        'limit': _pageSize,
      };
      if (language != null) {
        subParams['language'] = _siteLanguages(language).join(',');
      }

      // Every page of a long list: the first twenty of Breaking Bad's second
      // season held two of E05's six.
      final subs = <dynamic>[];
      for (var page = 1; page <= _maxPages; page++) {
        final subsResponse = await _dio.get<Map<String, dynamic>>(
          "$baseUrlV1/subtitles",
          queryParameters: {...subParams, 'page': page},
          cancelToken: cancelToken,
          options: Options(
            headers: {...SubtitleProvider.commonHeaders, 'X-API-Key': _apiKey!},
          ),
        );
        final data = subsResponse.data?['data'];
        subs.addAll(
          (data is Map && data['results'] != null)
              ? data['results'] as List<dynamic>
              : (data is List ? data : const <dynamic>[]),
        );
        final pagination = subsResponse.data?['pagination'];
        final pages = pagination is Map ? pagination['pages'] : null;
        if (pages is! int || page >= pages) break;
      }

      final results = <OnlineSubtitle>[];
      for (final s in subs.whereType<Map<dynamic, dynamic>>()) {
        // A subtitle lists every release it fits, and the episode may be
        // named in any of them. The V1 subtitles endpoint takes movieId +
        // language only, so both the season and the episode have to be
        // applied here (the keyless path gets its season server-side and only
        // needs the episode).
        final raw = s['releaseInfo'] ?? s['release_name'] ?? s['file_name'];
        final names = [
          if (raw is Iterable)
            ...raw.map((n) => '$n'.trim())
          else if (raw != null)
            '$raw'.trim(),
        ];
        final subName = (names.isEmpty ? [query] : names)
            .where((n) => _matchesSeasonEpisode(n, season, episode))
            .firstOrNull;
        if (subName == null) continue;
        final subId = s['subtitleId'] ?? s['id'];
        // Labelled with the language asked for, as without a key.
        final subLang = language ?? _parseString(s['language'], "Unknown");

        results.add(
          OnlineSubtitle(
            id: subId.toString(),
            name: subName,
            language: subLang,
            source: name,
            downloadUrl: "$baseUrlV1/subtitles/$subId/download",
            isHearingImpaired: s['hearingImpaired'] == true || s['hi'] == 1,
            metadata: {'id': subId, 'mode': 'v1'},
          ),
        );
      }

      if (kDebugMode) {
        debugPrint(
          "[SubSource V1] Found ${results.length} results"
          "${episode != null && episode > 0 ? ' for E$episode' : ''}.",
        );
      }
      return results;
    } catch (e) {
      if (e is! DioException || e.type != DioExceptionType.cancel) {
        if (kDebugMode) print("[SubSource V1] Search error: $e");
      }
      return [];
    }
  }

  /// The keyless path, as subsource.net's own pages ask: a search by the tt
  /// id - or the title - names the film or show, and a show's season is a
  /// list of its own (`the-show/season-2`), so only the episode is matched
  /// here, by release name. Results are labelled with [language], the code
  /// they were asked in, as the other providers' are.
  Future<List<OnlineSubtitle>> _searchKeyless({
    required String query,
    String? imdbId,
    int? season,
    int? episode,
    String? language,
    CancelToken? cancelToken,
  }) async {
    final String searchStr = imdbId != null
        ? (imdbId.startsWith('tt') ? imdbId : 'tt$imdbId')
        : query;
    if (searchStr.trim().isEmpty) {
      if (kDebugMode) {
        print(
          "[SubSource Keyless] Skipping search: Query or IMDb ID required.",
        );
      }
      return [];
    }

    if (kDebugMode) {
      final logMode = imdbId != null ? "IMDb" : "Title Fallback";
      print("[SubSource Keyless] Search Start: $searchStr (Mode: $logMode)");
    }

    try {
      final searchResponse = await _dio.post<Map<String, dynamic>>(
        "$baseUrlSite/movie/search",
        data: {'query': searchStr, 'includeSeasons': true, 'limit': 15},
        cancelToken: cancelToken,
        options: Options(headers: _keylessHeaders),
      );
      final found = searchResponse.data?['results'];
      if (searchResponse.data?['success'] != true ||
          found is! List ||
          found.isEmpty) {
        return [];
      }
      final list = _keylessList(found, imdbId == null ? query : null, season);
      if (list == null) return [];

      final code = language ?? "en";
      final listResponse = await _dio.get<Map<String, dynamic>>(
        "$baseUrlSite/subtitles/$list",
        queryParameters: {
          'language': _siteLanguages(code).join(','),
          'sort_by_date': 'false',
        },
        cancelToken: cancelToken,
        options: Options(headers: _keylessHeaders),
      );
      final subs = listResponse.data?['subtitles'];
      if (subs is! List) return [];

      final results = <OnlineSubtitle>[
        for (final s in subs.whereType<Map<dynamic, dynamic>>())
          if (s['link'] is String &&
              _matchesEpisode(_parseString(s['release_info'], ''), episode))
            OnlineSubtitle(
              id: '${s['id']}',
              name: _parseString(s['release_info'], query),
              language: code,
              source: name,
              downloadUrl: "", // The token comes from getDownloadUrl.
              isHearingImpaired:
                  s['hearing_impaired'] == 1 || s['hearing_impaired'] == true,
              metadata: {'id': s['id'], 'link': s['link'], 'mode': 'keyless'},
            ),
      ];

      if (kDebugMode) {
        print("[SubSource Keyless] Found ${results.length} results.");
      }
      return results;
    } catch (e) {
      if (e is! DioException || e.type != DioExceptionType.cancel) {
        if (kDebugMode) print("[SubSource Keyless] Search error: $e");
      }
      return [];
    }
  }

  /// The list a keyless search opens, as a path under `/subtitles`: a film's
  /// own (`the-film-1999`), or a show's season (`the-show/season-2`) when the
  /// site lists that season - none when it doesn't. A title search takes the
  /// entry named [title] over the first one: the site ranks "Escape The
  /// Matrix" above "The Matrix" for "the matrix".
  static String? _keylessList(List<dynamic> found, String? title, int? season) {
    final entries = found.whereType<Map<dynamic, dynamic>>().toList();
    if (entries.isEmpty) return null;
    final wanted = title?.trim().toLowerCase();
    final entry = entries.firstWhere(
      (e) => wanted != null && '${e['title']}'.trim().toLowerCase() == wanted,
      orElse: () => entries.first,
    );
    final slug = '${entry['link'] ?? ''}'
        .split('/')
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    if (slug == null) return null;
    final path = Uri.encodeComponent(slug);
    if (entry['type'] != 'tvseries' || season == null || season <= 0) {
      return path;
    }
    final seasons = entry['seasons'];
    if (seasons is List &&
        seasons.isNotEmpty &&
        !seasons.any((s) => s is Map && s['season'] == season)) {
      return null;
    }
    return '$path/season-$season';
  }

  /// The names subsource.net files [code]'s subtitles under, as its own
  /// language table gives them: every Chinese it has for Chinese (on popular
  /// films mostly chinese_bg_code, Simplified, and big_5_code, Traditional),
  /// and both of Filipino's.
  List<String> _siteLanguages(String code) => switch (code.toLowerCase()) {
    'zh' => const [
      'chinese',
      'chinese_simplified',
      'chinese_traditional',
      'chinese_bg_code',
      'big_5_code',
      'chinese_bilingual',
      'chinese_cantonese',
    ],
    'fil' => const ['filipino', 'tagalog'],
    _ => [_getLanguageFull(code)],
  };

  @override
  Future<String?> getDownloadUrl(OnlineSubtitle subtitle) async {
    final mode = subtitle.metadata?['mode'] ?? 'v1';

    if (mode == 'v1') {
      return subtitle.downloadUrl;
    }

    // Keyless: the subtitle's own page hands out its download token.
    final link = subtitle.metadata?['link'];
    if (link is! String || link.isEmpty) return null;

    try {
      final page = link.split('/').map(Uri.encodeComponent).join('/');
      final response = await _dio.get<Map<String, dynamic>>(
        "$baseUrlSite/subtitle/$page",
        options: Options(headers: _keylessHeaders),
      );
      final sub = response.data?['subtitle'];
      final token = sub is Map ? sub['download_token'] : null;
      if (token is String && token.isNotEmpty) {
        return "$baseUrlSite/subtitle/download/$token";
      }
    } catch (e) {
      if (kDebugMode) print("[SubSource Keyless] Download failed: $e");
    }
    return null;
  }

  /// The browser the keyless path presents itself as.
  static const String _browserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36';

  /// Browser-mimicking headers for keyless SubSource
  static const Map<String, String> _keylessBrowserHeaders = {
    'User-Agent': _browserAgent,
    'Referer': 'https://subsource.net/',
    'Origin': 'https://subsource.net/',
    'Accept': '*/*',
  };

  /// What the keyless path sends the site's API, as its own pages do.
  static const Map<String, String> _keylessHeaders = {
    'User-Agent': _browserAgent,
    'Accept': 'application/json',
    'Referer': 'https://subsource.net/',
    'Origin': 'https://subsource.net/',
  };

  @override
  Map<String, String> getDownloadHeaders(OnlineSubtitle subtitle) {
    final mode = subtitle.metadata?['mode'] ?? 'v1';
    if (mode == 'keyless') {
      return _keylessBrowserHeaders;
    }
    // V1 mode needs the API key
    return {
      ...SubtitleProvider.commonHeaders,
      if (_apiKey != null && _apiKey!.isNotEmpty) 'X-API-Key': _apiKey!,
    };
  }

  /// Helper to convert language tag to full English name.
  String _getLanguageFull(String tag) {
    const Map<String, String> langMap = {
      'en': 'english',
      'hi': 'hindi',
      'te': 'telugu',
      'ta': 'tamil',
      'ml': 'malayalam',
      'kn': 'kannada',
      'bn': 'bengali',
      'mr': 'marathi',
      'gu': 'gujarati',
      'pa': 'punjabi',
      'ar': 'arabic',
      'as': 'assamese',
      'be': 'belarusian',
      'bg': 'bulgarian',
      'cs': 'czech',
      'de': 'german',
      'el': 'greek',
      'es': 'spanish',
      'fi': 'finnish',
      'fr': 'french',
      'he': 'hebrew',
      'hr': 'croatian',
      'hu': 'hungarian',
      'id': 'indonesian',
      'it': 'italian',
      'ja': 'japanese',
      'ko': 'korean',
      'lv': 'latvian',
      'mk': 'macedonian',
      'nl': 'dutch',
      'pl': 'polish',
      'pt': 'portuguese',
      'ro': 'romanian',
      'ru': 'russian',
      'sv': 'swedish',
      'tr': 'turkish',
      'uk': 'ukrainian',
      'ur': 'urdu',
      'vi': 'vietnamese',
      // subsource.net's own names, from its language table: Simplified
      // Chinese is "chinese_bg_code" (Traditional is "big_5_code"), Persian
      // "farsi_persian", and Filipino is filed as "tagalog" (and "filipino").
      'zh': 'chinese_bg_code',
      'fa': 'farsi_persian',
      'th': 'thai',
      'az': 'azerbaijani',
      'fil': 'tagalog',
    };
    return langMap[tag.toLowerCase()] ?? tag.toLowerCase();
  }

  /// Verifies if the API key is valid (for v1) or if the endpoint is reachable (for keyless).
  Future<bool> verifyKey() async {
    if (_apiKey != null && _apiKey!.isNotEmpty) {
      if (kDebugMode) {
        final maskedKey = _apiKey!.length > 5
            ? "${_apiKey!.substring(0, 5)}..."
            : "None";
        print("[SubSource V1] Verifying User Key: $maskedKey");
      }
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          "$baseUrlV1/movies/search",
          queryParameters: {'searchType': 'text', 'q': 'Inception'},
          options: Options(
            headers: {...SubtitleProvider.commonHeaders, 'X-API-Key': _apiKey},
          ),
        );
        if (kDebugMode && response.statusCode != 200) {
          debugPrint(
            "[SubSource V1] Verification Failed: ${response.statusCode} - ${response.data}",
          );
        }
        return response.statusCode == 200;
      } catch (e) {
        if (kDebugMode) {
          if (e is DioException) {
            print(
              "[SubSource V1] Verification Error: ${e.response?.statusCode} - ${e.response?.data}",
            );
          } else {
            print("[SubSource V1] Verification Exception: $e");
          }
        }
        return false;
      }
    } else {
      // Keyless: the site's own search answers.
      if (kDebugMode) {
        print("[SubSource Keyless] Verifying Connectivity (Mode: site API)...");
      }
      try {
        final response = await _dio.post<Map<String, dynamic>>(
          "$baseUrlSite/movie/search",
          data: {'query': 'tt0133093', 'limit': 1}, // The Matrix
          options: Options(headers: _keylessHeaders),
        );
        return response.statusCode == 200 && response.data?['success'] == true;
      } catch (e) {
        return false;
      }
    }
  }
}
