import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'tracking_service.dart';
import '../domain/sync_progress_item.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/logger/app_logger.dart';
import '../../../../core/network/dio_client_provider.dart';
import '../../../../core/storage/secure_token_storage.dart';
import '../../../../core/config/sync_config.dart';

part 'simkl_service.g.dart';

/// Query parameters and headers for one Simkl call, built when it is sent.
typedef _SimklCall = ({Map<String, String> query, Map<String, String> headers});

/// Simkl, signed in on AUTH V2 (docs/superpowers/specs/
/// 2026-10-10-simkl-auth-v2-design.md).
///
/// Simkl ends its V1 PIN sign-in around April 2027, and new Simkl apps are
/// V2 only. New sign-ins are a device code from SkyStream's V2 app, a public
/// client with no secret; its access tokens last seven days and are
/// refreshed. Someone signed in on V1 before stays signed in, on the V1 app,
/// until Simkl refuses that token; then the account tile asks them to connect
/// again, on V2. A build without the V2 app ([SyncConfig.simklV2ClientId]
/// empty) signs in with V1's PIN as before.
class SimklService implements TrackingService {
  final Dio _dio;
  final SecureTokenStorage _storage;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final Future<String> Function() _appVersion;
  final String _v1ClientId;
  final String _v2ClientId;

  static const String _api = 'https://api.simkl.com';
  static const String _kAccessTokenKey = 'simkl_access_token';
  static const String _kRefreshTokenKey = 'simkl_refresh_token';
  static const String _kExpiresAtKey = 'simkl_token_expires_at';

  /// What a sign-in asks for: the person's lists and history, to read and
  /// write.
  static const String _scope = 'media:read media:write';

  static const String _deviceGrant =
      'urn:ietf:params:oauth:grant-type:device_code';

  /// V2's access tokens last seven days. Refreshing a day early means an app
  /// opened at all regularly never presents an expired one; one that has been
  /// off for longer recovers through the 401 path.
  static const Duration _refreshSkew = Duration(days: 1);

  String? _accessToken;
  String? _refreshToken;
  int? _expiresAtMs;
  Future<void>? _initFuture;

  /// Serialises refreshes. Simkl keeps one live access token per sign-in and
  /// a refresh invalidates the one before it at once, so two refreshes at the
  /// same time would leave every call but the last one's signed out.
  Future<bool>? _refreshInFlight;

  SimklService(
    this._dio,
    this._storage, {
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    Future<String> Function()? appVersion,
    String v1ClientId = SyncConfig.simklClientId,
    String v2ClientId = SyncConfig.simklV2ClientId,
  }) : _clock = clock ?? DateTime.now,
       _delay = delay ?? _wait,
       _appVersion = appVersion ?? _packageVersion,
       _v1ClientId = v1ClientId,
       _v2ClientId = v2ClientId {
    _initFuture = _initToken();
  }

  static Future<void> _wait(Duration duration) =>
      Future<void>.delayed(duration);

  static Future<String>? _version;

  /// The app's version, as Simkl asks every call to name it.
  static Future<String> _packageVersion() =>
      _version ??= PackageInfo.fromPlatform().then((info) => info.version);

  Future<void> _initToken() async {
    _accessToken = await _storage.read(_kAccessTokenKey);
    _refreshToken = await _storage.read(_kRefreshTokenKey);
    _expiresAtMs = int.tryParse(await _storage.read(_kExpiresAtKey) ?? '');
  }

  Future<void> _ensureInit() async {
    if (_initFuture != null) {
      await _initFuture;
    }
  }

  /// Signed in on AUTH V2: a refresh token is stored, and V2's access tokens
  /// start with `simkl_at_`. Anything else came from V1's PIN, whose token
  /// never expires and can't be refreshed.
  bool get _isV2Session =>
      _refreshToken != null || (_accessToken?.startsWith('simkl_at_') ?? false);

  /// The app a call names: the one that issued the session's token - V1's for
  /// a session from before V2 - else the V2 app, when the build has one.
  String get _clientId {
    if (_accessToken != null && !_isV2Session) return _v1ClientId;
    return _v2ClientId.isNotEmpty ? _v2ClientId : _v1ClientId;
  }

  Future<String> _appVersionOrUnknown() async {
    try {
      return await _appVersion();
    } catch (_) {
      return 'unknown';
    }
  }

  /// How every call names the app, as Simkl's rules ask: the app's client,
  /// name and version as URL parameters, and a User-Agent saying SkyStream.
  /// Its per-person daily limits are counted across every V2 app the person
  /// uses.
  _SimklCall _named(String version, {String? clientId}) => (
    query: {
      'client_id': clientId ?? _clientId,
      'app-name': 'skystream',
      'app-version': version,
    },
    headers: {'User-Agent': 'SkyStream/$version'},
  );

  /// [_named], in the person's name, with the token as it is now.
  _SimklCall _signed(String version) {
    final named = _named(version);
    return (
      query: named.query,
      headers: {
        ...named.headers,
        'Authorization': 'Bearer $_accessToken',
        'simkl-api-key': _clientId,
      },
    );
  }

  static Options _form(_SimklCall call) => Options(
    contentType: Headers.formUrlEncodedContentType,
    headers: call.headers,
  );

  /// The OAuth `error` of a refused request, when Simkl said one.
  static String? _oauthError(DioException error) {
    final data = error.response?.data;
    return data is Map ? data['error']?.toString() : null;
  }

  @override
  String get name => 'Simkl';

  @override
  String get idPrefix => 'simkl';

  @override
  String get mainUrl => 'https://simkl.com';

  @override
  Future<bool> get isLoggedIn async {
    await _ensureInit();
    return _accessToken != null;
  }

  /// A device code from the V2 app (RFC 8628), shown with the page to enter
  /// it on, then polled until the person approves it or it expires.
  @override
  Future<bool> login({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    Future<void> Function(String url)? onWebViewRequested,
    bool Function()? isCancelled,
  }) async {
    if (_v2ClientId.isEmpty) {
      return _loginWithPin(
        onDeviceCodeGenerated: onDeviceCodeGenerated,
        isCancelled: isCancelled,
      );
    }
    try {
      final call = _named(await _appVersionOrUnknown(), clientId: _v2ClientId);
      talker.debug('SimklService: requesting a device code (AUTH V2)...');
      final response = await _dio.post<dynamic>(
        '$_api/oauth2/device',
        queryParameters: call.query,
        data: {'client_id': _v2ClientId, 'scope': _scope},
        options: _form(call),
      );
      final code = Map<String, dynamic>.from(response.data as Map);
      final deviceCode = code['device_code'] as String;
      final userCode = code['user_code'] as String;
      final verificationUri =
          code['verification_uri'] as String? ?? 'https://simkl.com/pin';
      var interval = Duration(
        seconds: (code['interval'] as num?)?.toInt() ?? 5,
      );
      // The poll ends when the code does, not after a count: a person who
      // declines is answered "pending" like one who hasn't looked yet.
      final deadline = _clock().add(
        Duration(seconds: (code['expires_in'] as num?)?.toInt() ?? 900),
      );

      talker.debug(
        'SIMKL DEVICE LOGIN — go to $verificationUri and enter code $userCode',
      );
      await onDeviceCodeGenerated?.call(verificationUri, userCode);

      while (_clock().isBefore(deadline)) {
        if (isCancelled?.call() ?? false) return false;
        await _delay(interval);
        if (isCancelled?.call() ?? false) return false;
        try {
          final answer = await _dio.post<dynamic>(
            '$_api/oauth2/token',
            queryParameters: call.query,
            data: {
              'grant_type': _deviceGrant,
              'device_code': deviceCode,
              'client_id': _v2ClientId,
            },
            options: _form(call),
          );
          final data = answer.data;
          if (data is Map && data['access_token'] != null) {
            await _storeTokens(Map<String, dynamic>.from(data));
            talker.debug('SimklService: Login successful!');
            return true;
          }
        } on DioException catch (e) {
          final error = _oauthError(e);
          switch (error) {
            case 'authorization_pending':
              break;
            case 'slow_down':
              interval += const Duration(seconds: 5);
            case 'expired_token' ||
                'access_denied' ||
                'invalid_grant' ||
                'invalid_client' ||
                'unauthorized_client':
              talker.debug('SimklService: sign-in ended: $error');
              return false;
            default:
              // No answer, or one that says nothing of the code: ask again.
              talker.debug(
                'SimklService: polling error: '
                '${e.response?.statusCode} ${e.message}',
              );
          }
        }
      }
      talker.debug('SimklService: the sign-in code expired.');
      return false;
    } catch (e) {
      talker.error('SimklService: Login failed', e);
      return false;
    }
  }

  /// V1's PIN sign-in, for a build without the V2 app. Its token never
  /// expires and can't be refreshed.
  Future<bool> _loginWithPin({
    Future<void> Function(String url, String code)? onDeviceCodeGenerated,
    bool Function()? isCancelled,
  }) async {
    try {
      final call = _named(await _appVersionOrUnknown(), clientId: _v1ClientId);
      talker.debug('SimklService: Initiating Device PIN Flow...');
      final response = await _dio.get<dynamic>(
        '$_api/oauth/pin',
        queryParameters: call.query,
        options: Options(headers: call.headers),
      );

      final userCode = response.data['user_code'] as String;
      final verificationUrl = response.data['verification_url'] as String;
      final interval = (response.data['interval'] as num?)?.toInt() ?? 5;

      talker.debug(
        'SIMKL DEVICE LOGIN — go to $verificationUrl and enter code $userCode',
      );

      if (onDeviceCodeGenerated != null) {
        await onDeviceCodeGenerated(verificationUrl, userCode);
      }

      // Polling
      int attempts = 0;
      while (attempts < 60) {
        // Timeout after ~5 mins (assuming 5s interval)
        if (isCancelled != null && isCancelled()) {
          talker.debug('SimklService: Polling cancelled by user.');
          return false;
        }
        await _delay(Duration(seconds: interval));
        if (isCancelled != null && isCancelled()) return false;

        try {
          talker.debug('SimklService: Polling for token...');
          final tokenResponse = await _dio.get<dynamic>(
            '$_api/oauth/pin/$userCode',
            queryParameters: call.query,
            options: Options(headers: call.headers),
          );

          final data = tokenResponse.data;
          if (data is Map &&
              data['result'] == 'OK' &&
              data['access_token'] != null) {
            await _clearSession('a new V1 sign-in');
            _accessToken = data['access_token'].toString();
            await _storage.write(_kAccessTokenKey, _accessToken!);
            talker.debug('SimklService: Login successful!');
            return true;
          }
        } on DioException catch (e) {
          if (e.response?.statusCode != 400) {
            talker.debug('SimklService: Polling error: ${e.message}');
          }
        }
        attempts++;
      }
      talker.debug('SimklService: Login timed out.');
      return false;
    } catch (e) {
      talker.error('SimklService: Login failed', e);
      return false;
    }
  }

  /// Keeps a token pair from a device grant or a refresh.
  Future<void> _storeTokens(Map<String, dynamic> data) async {
    _accessToken = data['access_token'].toString();
    final refresh = data['refresh_token']?.toString();
    if (refresh != null && refresh.isNotEmpty) _refreshToken = refresh;
    final expiresIn = (data['expires_in'] as num?)?.toInt();
    _expiresAtMs = expiresIn != null && expiresIn > 0
        ? _clock().millisecondsSinceEpoch + expiresIn * 1000
        : null;

    // The refresh token first: an app killed between the writes keeps the
    // one Simkl just issued, so its next start can still refresh. A missing
    // later write costs one more refresh at most.
    if (_refreshToken != null) {
      await _storage.write(_kRefreshTokenKey, _refreshToken!);
    }
    await _storage.write(_kAccessTokenKey, _accessToken!);
    if (_expiresAtMs != null) {
      await _storage.write(_kExpiresAtKey, _expiresAtMs!.toString());
    } else {
      await _storage.delete(_kExpiresAtKey);
    }
  }

  /// Drops the session, so [isLoggedIn] reports false and the account tile
  /// asks the person to connect again.
  Future<void> _clearSession(String reason) async {
    talker.debug('SimklService: clearing the session — $reason');
    _accessToken = null;
    _refreshToken = null;
    _expiresAtMs = null;
    await _storage.delete(_kAccessTokenKey);
    await _storage.delete(_kRefreshTokenKey);
    await _storage.delete(_kExpiresAtKey);
  }

  @override
  Future<void> logout() async {
    talker.debug('SimklService: Logging out...');
    await _ensureInit();
    await _clearSession('signed out');
  }

  /// True when there is a token to send: refreshed first when a V2 token is
  /// within a day of expiring. A refresh that gets no answer leaves a token
  /// with time left on it usable.
  Future<bool> _ensureFreshToken() async {
    await _ensureInit();
    if (_accessToken == null) return false;
    final expiresAt = _expiresAtMs;
    // V1 tokens never expire; a V2 session with no expiry on file is left to
    // the 401 path.
    if (!_isV2Session || expiresAt == null) return true;
    final now = _clock().millisecondsSinceEpoch;
    if (now + _refreshSkew.inMilliseconds < expiresAt) return true;
    if (await _refreshAccessToken()) return true;
    return _accessToken != null && now < expiresAt;
  }

  Future<bool> _refreshAccessToken() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final refresh = _doRefreshAccessToken();
    _refreshInFlight = refresh;
    refresh.whenComplete(() => _refreshInFlight = null);
    return refresh;
  }

  Future<bool> _doRefreshAccessToken() async {
    final refresh = _refreshToken;
    if (refresh == null) {
      await _clearSession('no refresh token stored');
      return false;
    }
    try {
      talker.debug('SimklService: Refreshing access token...');
      final call = _named(await _appVersionOrUnknown(), clientId: _v2ClientId);
      final response = await _dio.post<dynamic>(
        '$_api/oauth2/token',
        queryParameters: call.query,
        data: {
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
          'client_id': _v2ClientId,
        },
        options: _form(call),
      );
      final data = response.data;
      if (data is Map && data['access_token'] != null) {
        await _storeTokens(Map<String, dynamic>.from(data));
        talker.debug('SimklService: Token refreshed successfully');
        return true;
      }
      // An answer with no tokens is a refusal only when it says so. A bot
      // check the app couldn't clear comes back as an answer too (the
      // clearance interceptor), and spends nothing.
      final status = response.statusCode;
      if (status == 400 || status == 401) {
        await _clearSession('refresh refused with $status');
      } else {
        talker.error(
          'SimklService: refresh answered $status without a token, '
          'will retry',
        );
      }
      return false;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // A 400 (invalid_grant) or 401 (invalid_client) is Simkl ending the
      // sign-in. Anything else - no answer, a 5xx, a rate limit (429) -
      // spends nothing, and signing someone out for a dropped connection
      // would be worse than waiting.
      if (status == 400 || status == 401) {
        await _clearSession('refresh refused with $status');
      } else {
        talker.error('SimklService: Token refresh failed, will retry', e);
      }
      return false;
    } catch (e) {
      talker.error('SimklService: Token refresh failed, will retry', e);
      return false;
    }
  }

  /// Sends a call in the person's name, refreshing once on a 401.
  ///
  /// [send] builds its request from the call it is handed, so a retry
  /// carries the token the refresh produced. Null when the call couldn't be
  /// made or didn't succeed.
  Future<Response<dynamic>?> _sendAuthorized(
    String label,
    Future<Response<dynamic>> Function(_SimklCall call) send,
  ) async {
    if (!await _ensureFreshToken()) return null;
    final version = await _appVersionOrUnknown();
    final sentWith = _accessToken;
    if (sentWith == null) return null;
    try {
      return await send(_signed(version));
    } on DioException catch (e) {
      if (e.response?.statusCode != 401) {
        talker.error('SimklService: $label failed', e);
        return null;
      }
      if (!_isV2Session) {
        // A V1 token never expires and can't be refreshed: a 401 means the
        // app was revoked, or Simkl has ended V1. The account tile then asks
        // the person to connect again, on V2.
        await _clearSession('V1 token refused (401)');
        return null;
      }
      // Sent with a token a refresh has since replaced: the new one is here.
      if (_accessToken == sentWith && !await _refreshAccessToken()) {
        return null;
      }
      if (_accessToken == null) return null;
      try {
        return await send(_signed(version));
      } catch (retryError) {
        talker.error('SimklService: $label failed after refresh', retryError);
        return null;
      }
    } catch (e) {
      talker.error('SimklService: $label failed', e);
      return null;
    }
  }

  /// Whether the V1 app has been refused a lookup: once Simkl ends V1,
  /// lookups go out in a V2 session's name from then on.
  bool _v1LookupsRefused = false;

  /// A catalogue lookup: [path] with [params].
  ///
  /// Simkl answers a call without a person's token for the V1 app only; the
  /// V2 app is refused it ("requires a user access token on every request",
  /// measured 2026-10-12). So lookups go out on the V1 app with no token, as
  /// they always have. Once that is refused - V1 has ended - or the build has
  /// no V1 app, they go out in the name of a person signed in on V2, and count
  /// against that person's daily limits. Null when nobody can ask.
  Future<dynamic> _lookup(String path, Map<String, String> params) async {
    await _ensureInit();
    final version = await _appVersionOrUnknown();
    if (_v1ClientId.isNotEmpty && !_v1LookupsRefused) {
      final call = _named(version, clientId: _v1ClientId);
      try {
        final response = await _dio.get<dynamic>(
          '$_api$path',
          queryParameters: {...call.query, ...params},
          options: Options(headers: call.headers),
        );
        return response.data;
      } on DioException catch (e) {
        if (e.response?.statusCode != 401) rethrow;
        talker.debug('SimklService: the V1 app was refused a lookup (401)');
        _v1LookupsRefused = true;
      }
    }
    if (!_isV2Session) return null;
    final response = await _sendAuthorized(
      'Lookup $path',
      (call) => _dio.get<dynamic>(
        '$_api$path',
        queryParameters: {...call.query, ...params},
        options: Options(headers: call.headers),
      ),
    );
    return response?.data;
  }

  @override
  Future<List<MultimediaItem>> search(String query) async {
    if (_accessToken == null) return [];

    // Search implementation
    return [];
  }

  @override
  Future<Map<String, String>> syncIds(MultimediaItem item) async {
    final Map<String, String> resolvedIds = {};

    try {
      final params = <String, String>{};
      if (item.imdbId != null) {
        params['imdb'] = item.imdbId!;
      } else if (item.tmdbId != null) {
        params['tmdb'] = item.tmdbId.toString();
      } else {
        talker.debug(
          'SimklService.syncIds: No imdbId or tmdbId found on item: ${item.title}',
        );
        return {};
      }

      talker.debug(
        'SimklService.syncIds: Querying Simkl for ${item.title} with params: $params',
      );

      final found = await _lookup('/search/id', params);

      talker.debug('SimklService.syncIds: Response: $found');

      if (found is List && found.isNotEmpty) {
        final result = found.first as Map<String, dynamic>;
        final type = result['type'] as String?;
        final ids = result['ids'] as Map<String, dynamic>?;

        if (ids != null && ids['simkl'] != null) {
          final simklId = ids['simkl'].toString();
          resolvedIds['simkl'] = simklId;

          // Determine correct details endpoint path
          String detailsPath;
          if (type == 'movie') {
            detailsPath = 'movies';
          } else if (type == 'tv') {
            detailsPath = 'tv';
          } else if (type == 'anime') {
            detailsPath = 'anime';
          } else {
            detailsPath = item.contentType == MultimediaContentType.movie
                ? 'movies'
                : 'tv';
          }

          talker.debug(
            'SimklService.syncIds: Fetching full details from /$detailsPath/$simklId',
          );

          final details = await _lookup('/$detailsPath/$simklId', const {});

          if (details is Map) {
            final detailsIds = details['ids'] as Map<String, dynamic>?;
            if (detailsIds != null) {
              if (detailsIds['simkl'] != null) {
                resolvedIds['simkl'] = detailsIds['simkl'].toString();
              }
              if (detailsIds['mal'] != null) {
                resolvedIds['mal'] = detailsIds['mal'].toString();
              }
              if (detailsIds['anilist'] != null) {
                resolvedIds['anilist'] = detailsIds['anilist'].toString();
              }
              if (detailsIds['tmdb'] != null) {
                resolvedIds['tmdb'] = detailsIds['tmdb'].toString();
              }
              if (detailsIds['imdb'] != null) {
                resolvedIds['imdb'] = detailsIds['imdb'].toString();
              }
            }
          }
        }
        talker.debug('SimklService.syncIds: Resolved ids: $resolvedIds');
      } else {
        talker.debug('SimklService.syncIds: Empty or non-200 response.');
      }
    } catch (e, st) {
      talker.error('SimklService.syncIds error for item: ${item.title}', e, st);
    }

    return resolvedIds;
  }

  Future<bool> _syncList(
    MultimediaItem item,
    Episode? episode,
    String listType,
    Map<String, String>? resolvedIds,
  ) async {
    final simklId = resolvedIds?['simkl'];
    // We need simkl id or other ids. We'll send TMDB/IMDB directly if available.
    if (simklId == null && item.tmdbId == null && item.imdbId == null) {
      return false;
    }

    final payload = <String, dynamic>{};
    final ids = <String, dynamic>{
      'simkl': ?simklId,
      if (simklId == null && item.tmdbId != null) 'tmdb': item.tmdbId,
      if (simklId == null && item.imdbId != null) 'imdb': item.imdbId,
    };

    if (item.contentType == MultimediaContentType.movie) {
      payload['movies'] = [
        {'to': listType, 'ids': ids},
      ];
    } else {
      payload['shows'] = [
        {'to': listType, 'ids': ids},
      ];
    }

    final response = await _sendAuthorized(
      'Add to list $listType',
      (call) => _dio.post<dynamic>(
        '$_api/sync/add-to-list',
        queryParameters: call.query,
        data: payload,
        options: Options(headers: call.headers),
      ),
    );
    if (response == null) return false;
    talker.debug(
      'SimklService: Add to list $listType success: ${response.statusCode}',
    );
    return response.statusCode == 200 || response.statusCode == 201;
  }

  @override
  Future<bool> markWatched(
    MultimediaItem item,
    Episode? episode, {
    Map<String, String>? resolvedIds,
  }) async {
    final simklId = resolvedIds?['simkl'];
    if (simklId == null && item.tmdbId == null && item.imdbId == null) {
      return false;
    }

    final payload = <String, dynamic>{};
    final ids = <String, dynamic>{
      'simkl': ?simklId,
      if (simklId == null && item.tmdbId != null) 'tmdb': item.tmdbId,
      if (simklId == null && item.imdbId != null) 'imdb': item.imdbId,
    };

    if (item.contentType == MultimediaContentType.movie) {
      payload['movies'] = [
        {'ids': ids},
      ];
    } else {
      if (episode == null) return false;
      payload['shows'] = [
        {
          'ids': ids,
          'episodes': [
            {'season': episode.season, 'number': episode.episode},
          ],
        },
      ];
    }

    final response = await _sendAuthorized(
      'Mark watched',
      (call) => _dio.post<dynamic>(
        '$_api/sync/history',
        queryParameters: call.query,
        data: payload,
        options: Options(headers: call.headers),
      ),
    );
    if (response == null) return false;
    talker.debug('SimklService: Mark watched success: ${response.statusCode}');
    return response.statusCode == 200 || response.statusCode == 201;
  }

  @override
  Future<bool> scrobbleStart(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) async {
    // Simkl doesn't have real-time scrobble, so we add to watching list
    return _syncList(item, episode, 'watching', resolvedIds);
  }

  @override
  Future<bool> scrobblePause(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) async {
    // No-op for Simkl
    return true;
  }

  @override
  Future<bool> scrobbleStop(
    MultimediaItem item,
    Episode? episode,
    double progress, {
    Map<String, String>? resolvedIds,
  }) async {
    // No-op for Simkl. Actual completion is handled by markWatched.
    return true;
  }

  @override
  Future<bool> addToPlanToWatch(
    MultimediaItem item, {
    Map<String, String>? resolvedIds,
  }) async {
    return _syncList(item, null, 'plantowatch', resolvedIds);
  }

  @override
  Future<List<SyncProgressItem>> pullPlaybackProgress() async {
    return [];
  }

  @override
  Future<bool> removePlaybackProgress(String id) async {
    return false;
  }
}

@riverpod
SimklService simklService(Ref ref) {
  return SimklService(
    ref.watch(dioClientProvider),
    ref.watch(secureTokenStorageProvider),
  );
}
