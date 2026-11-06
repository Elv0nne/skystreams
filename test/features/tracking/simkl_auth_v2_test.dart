/// Simkl sign-in on AUTH V2 (the roadmap's side track): Simkl ends its V1 PIN
/// sign-in around April 2027, and new Simkl apps are V2 only. Signing in is a
/// device code from the V2 app (a public client: no secret); its tokens last
/// seven days and are refreshed. Someone signed in on V1 before stays signed
/// in, on the V1 app, until Simkl refuses that token. A build without the V2
/// app signs in on V1 as before.
///
/// Asserted against the wire: which requests go out, to which path, for
/// which app, with which token, and how the app names itself.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/secure_token_storage.dart';
import 'package:skystream/features/tracking/data/simkl_service.dart';

class _FakeTokenStorage implements SecureTokenStorage {
  _FakeTokenStorage([Map<String, String>? seed]) : values = {...?seed};

  final Map<String, String> values;

  /// Writes left before the app is "killed": every later write throws, as one
  /// the process never made.
  int? writesLeft;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    final left = writesLeft;
    if (left != null) {
      if (left <= 0) throw StateError('killed');
      writesLeft = left - 1;
    }
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// A response for one request, or a throw (a request that never got one).
typedef _Reply = FutureOr<ResponseBody> Function(RequestOptions options);

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.reply);

  _Reply reply;

  final List<RequestOptions> requests = <RequestOptions>[];

  List<RequestOptions> to(String path) =>
      requests.where((r) => r.uri.path == path).toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Map<String, dynamic> body, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

ResponseBody _oauthError(String error, {int status = 400}) =>
    _json({'error': error, 'error_description': error}, status: status);

Never _offline(RequestOptions options) => throw DioException.connectionError(
  requestOptions: options,
  reason: 'offline',
);

Map<String, dynamic> _form(RequestOptions request) =>
    Map<String, dynamic>.from(request.data as Map);

const _device = '/oauth2/device';
const _token = '/oauth2/token';
const _history = '/sync/history';

const _accessKey = 'simkl_access_token';
const _refreshKey = 'simkl_refresh_token';
const _expiryKey = 'simkl_token_expires_at';

void main() {
  late _ScriptedAdapter adapter;
  late Dio dio;
  late DateTime now;
  late List<Duration> waits;

  final film = MultimediaItem(
    title: 'Film',
    url: 'https://example.com/film',
    posterUrl: '',
    tmdbId: 603,
  );

  setUp(() {
    adapter = _ScriptedAdapter((_) => _json(const {}));
    dio = Dio()..httpClientAdapter = adapter;
    now = DateTime.utc(2026, 10, 12, 12);
    waits = <Duration>[];
  });

  SimklService serviceWith(
    _FakeTokenStorage storage, {
    String v1ClientId = 'v1-client',
    String v2ClientId = 'v2-client',
  }) => SimklService(
    dio,
    storage,
    clock: () => now,
    delay: (duration) async {
      waits.add(duration);
      now = now.add(duration);
    },
    appVersion: () async => '2.9.0',
    v1ClientId: v1ClientId,
    v2ClientId: v2ClientId,
  );

  Map<String, dynamic> deviceCode({int expiresIn = 900, int interval = 5}) => {
    'device_code': 'device-code',
    'user_code': 'ABCD-1234',
    'verification_uri': 'https://simkl.com/pin',
    'verification_uri_complete': 'https://simkl.com/pin?user_code=ABCD-1234',
    'expires_in': expiresIn,
    'interval': interval,
  };

  Map<String, dynamic> tokens({
    String access = 'simkl_at_new',
    String refresh = 'simkl_rt_new',
  }) => {
    'access_token': access,
    'token_type': 'Bearer',
    'expires_in': 604800,
    'refresh_token': refresh,
    'scope': 'media:read media:write',
  };

  /// A V2 session with [left] before its access token expires.
  Map<String, String> v2Session({Duration left = const Duration(days: 5)}) => {
    _accessKey: 'simkl_at_live',
    _refreshKey: 'simkl_rt_live',
    _expiryKey: now.add(left).millisecondsSinceEpoch.toString(),
  };

  /// What a V1 sign-in stored: one token, 64 hex characters, no expiry.
  Map<String, String> v1Session() => {_accessKey: 'ab' * 32};

  void expectNamesTheApp(RequestOptions request, {required String clientId}) {
    expect(request.uri.queryParameters['client_id'], clientId);
    expect(request.uri.queryParameters['app-name'], 'skystream');
    expect(request.uri.queryParameters['app-version'], '2.9.0');
    expect(request.headers['User-Agent'], 'SkyStream/2.9.0');
  }

  group('signing in, on AUTH V2', () {
    test('a device code from the V2 app, polled until the person approves; '
        'the token pair is kept', () async {
      var polls = 0;
      adapter.reply = (options) {
        if (options.uri.path == _device) return _json(deviceCode());
        if (options.uri.path == _token) {
          return ++polls < 2
              ? _oauthError('authorization_pending')
              : _json(tokens());
        }
        return _json(const {}, status: 404);
      };
      final storage = _FakeTokenStorage();
      final service = serviceWith(storage);
      final shown = <(String, String)>[];

      final signedIn = await service.login(
        onDeviceCodeGenerated: (url, code) async => shown.add((url, code)),
      );

      expect(signedIn, isTrue);
      final ask = adapter.to(_device).single;
      expect(ask.uri.host, 'api.simkl.com');
      expect(_form(ask), {
        'client_id': 'v2-client',
        'scope': 'media:read media:write',
      });
      expectNamesTheApp(ask, clientId: 'v2-client');
      expect(shown, [('https://simkl.com/pin', 'ABCD-1234')]);

      final asks = adapter.to(_token);
      expect(asks, hasLength(2));
      expect(_form(asks.last), {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'device_code': 'device-code',
        'client_id': 'v2-client',
      });
      expect(waits, [const Duration(seconds: 5), const Duration(seconds: 5)]);

      expect(storage.values[_accessKey], 'simkl_at_new');
      expect(storage.values[_refreshKey], 'simkl_rt_new');
      expect(
        storage.values[_expiryKey],
        now.add(const Duration(days: 7)).millisecondsSinceEpoch.toString(),
      );
      expect(await service.isLoggedIn, isTrue);
    });

    test('slow_down adds five seconds to the wait', () async {
      final answers = [
        _oauthError('slow_down'),
        _oauthError('authorization_pending'),
        _json(tokens()),
      ];
      adapter.reply = (options) => options.uri.path == _device
          ? _json(deviceCode())
          : answers.removeAt(0);

      expect(await serviceWith(_FakeTokenStorage()).login(), isTrue);
      expect(waits, const [
        Duration(seconds: 5),
        Duration(seconds: 10),
        Duration(seconds: 10),
      ]);
    });

    test('an expired code ends the sign-in', () async {
      adapter.reply = (options) => options.uri.path == _device
          ? _json(deviceCode())
          : _oauthError('expired_token');
      final storage = _FakeTokenStorage();

      expect(await serviceWith(storage).login(), isFalse);
      expect(adapter.to(_token), hasLength(1));
      expect(storage.values, isEmpty);
    });

    test('an app Simkl does not know ends the sign-in', () async {
      adapter.reply = (options) => options.uri.path == _device
          ? _json(deviceCode())
          : _oauthError('invalid_client', status: 401);

      expect(await serviceWith(_FakeTokenStorage()).login(), isFalse);
      expect(adapter.to(_token), hasLength(1));
    });

    test('a code nobody approves ends when it expires, not after a count: '
        'Simkl answers "pending" to a person who declined, too', () async {
      adapter.reply = (options) => options.uri.path == _device
          ? _json(deviceCode(expiresIn: 30))
          : _oauthError('authorization_pending');

      expect(await serviceWith(_FakeTokenStorage()).login(), isFalse);
      expect(adapter.to(_token), hasLength(6));
      expect(
        waits.fold(Duration.zero, (sum, wait) => sum + wait),
        const Duration(seconds: 30),
      );
    });

    test('cancelled after a poll, it asks no more', () async {
      var cancelled = false;
      adapter.reply = (options) {
        if (options.uri.path == _device) return _json(deviceCode());
        cancelled = true;
        return _oauthError('authorization_pending');
      };

      final signedIn = await serviceWith(_FakeTokenStorage())
          .login(isCancelled: () => cancelled);

      expect(signedIn, isFalse);
      expect(adapter.to(_token), hasLength(1));
    });

    test('cancelled during the wait, it asks nothing', () async {
      var cancelled = false;
      adapter.reply = (options) =>
          options.uri.path == _device ? _json(deviceCode()) : _json(tokens());
      final service = SimklService(
        dio,
        _FakeTokenStorage(),
        clock: () => now,
        delay: (duration) async => cancelled = true,
        appVersion: () async => '2.9.0',
        v1ClientId: 'v1-client',
        v2ClientId: 'v2-client',
      );

      expect(await service.login(isCancelled: () => cancelled), isFalse);
      expect(adapter.to(_token), isEmpty);
    });

    test('a poll that never reached Simkl does not end the sign-in', () async {
      var polls = 0;
      adapter.reply = (options) {
        if (options.uri.path == _device) return _json(deviceCode());
        return ++polls == 1 ? _offline(options) : _json(tokens());
      };

      expect(await serviceWith(_FakeTokenStorage()).login(), isTrue);
    });

    test('a build without the V2 app signs in with V1\'s PIN, as '
        'before', () async {
      adapter.reply = (options) {
        if (options.uri.path == '/oauth/pin') {
          return _json(const {
            'user_code': 'PIN123',
            'verification_url': 'https://simkl.com/pin',
            'interval': 5,
          });
        }
        if (options.uri.path == '/oauth/pin/PIN123') {
          return _json({'result': 'OK', 'access_token': 'ab' * 32});
        }
        return _json(const {}, status: 404);
      };
      final storage = _FakeTokenStorage();

      final signedIn = await serviceWith(storage, v2ClientId: '').login();

      expect(signedIn, isTrue);
      expect(adapter.to(_device), isEmpty);
      expect(
        adapter.to('/oauth/pin').single.uri.queryParameters['client_id'],
        'v1-client',
      );
      expect(storage.values, {_accessKey: 'ab' * 32});
    });
  });

  test('a V1 sign-in over a V2 session left on file keeps only the V1 '
      'token', () async {
    adapter.reply = (options) {
      if (options.uri.path == '/oauth/pin') {
        return _json(const {
          'user_code': 'PIN123',
          'verification_url': 'https://simkl.com/pin',
          'interval': 5,
        });
      }
      return _json({'result': 'OK', 'access_token': 'cd' * 32});
    };
    final storage = _FakeTokenStorage(v2Session());

    expect(await serviceWith(storage, v2ClientId: '').login(), isTrue);
    expect(storage.values, {_accessKey: 'cd' * 32});
  });

  group('a V2 session', () {
    test("its calls carry the V2 app and the person's token", () async {
      adapter.reply = (_) => _json(const {}, status: 201);
      final service = serviceWith(_FakeTokenStorage(v2Session()));

      expect(await service.markWatched(film, null), isTrue);

      final call = adapter.to(_history).single;
      expect(call.headers['Authorization'], 'Bearer simkl_at_live');
      expect(call.headers['simkl-api-key'], 'v2-client');
      expectNamesTheApp(call, clientId: 'v2-client');
      expect(adapter.to(_token), isEmpty);
    });

    test('a token within a day of expiring is refreshed first', () async {
      adapter.reply = (options) => options.uri.path == _token
          ? _json(tokens())
          : _json(const {}, status: 201);
      final storage = _FakeTokenStorage(
        v2Session(left: const Duration(hours: 12)),
      );

      expect(await serviceWith(storage).markWatched(film, null), isTrue);

      expect(adapter.requests.map((r) => r.uri.path), [_token, _history]);
      expect(_form(adapter.to(_token).single), {
        'grant_type': 'refresh_token',
        'refresh_token': 'simkl_rt_live',
        'client_id': 'v2-client',
      });
      expectNamesTheApp(adapter.to(_token).single, clientId: 'v2-client');
      expect(
        adapter.to(_history).single.headers['Authorization'],
        'Bearer simkl_at_new',
      );
      expect(storage.values[_accessKey], 'simkl_at_new');
      expect(storage.values[_refreshKey], 'simkl_rt_new');
    });

    test('a 401 refreshes once and tries again', () async {
      adapter.reply = (options) {
        if (options.uri.path == _token) return _json(tokens());
        return options.headers['Authorization'] == 'Bearer simkl_at_live'
            ? _oauthError('invalid_token', status: 401)
            : _json(const {}, status: 201);
      };

      final service = serviceWith(_FakeTokenStorage(v2Session()));
      expect(await service.markWatched(film, null), isTrue);
      expect(adapter.requests.map((r) => r.uri.path), [
        _history,
        _token,
        _history,
      ]);
    });

    test(
      '401s at the same time share one refresh: Simkl keeps one live '
      'token per sign-in, so a second refresh would undo the first',
      () async {
        final refreshing = Completer<void>();
        adapter.reply = (options) async {
          if (options.uri.path == _token) {
            await refreshing.future;
            return _json(tokens());
          }
          return options.headers['Authorization'] == 'Bearer simkl_at_live'
              ? _oauthError('invalid_token', status: 401)
              : _json(const {}, status: 201);
        };
        final service = serviceWith(_FakeTokenStorage(v2Session()));

        final both = Future.wait([
          service.markWatched(film, null),
          service.addToPlanToWatch(film),
        ]);
        await pumpEventQueue();
        // Both were refused before the refresh answered: they overlap it.
        expect(
          adapter.requests.where(
            (r) => r.headers['Authorization'] == 'Bearer simkl_at_live',
          ),
          hasLength(2),
        );
        refreshing.complete();

        expect(await both, [isTrue, isTrue]);
        expect(adapter.to(_token), hasLength(1));
      },
    );

    test('a 401 for a call sent before a refresh finished uses the new token '
        'rather than refreshing again', () async {
      final late401 = Completer<void>();
      var rejected = 0;
      adapter.reply = (options) async {
        if (options.uri.path == _token) return _json(tokens());
        if (options.headers['Authorization'] != 'Bearer simkl_at_live') {
          return _json(const {}, status: 201);
        }
        // The plan-to-watch call's 401 arrives only after the history call
        // refreshed.
        if (options.uri.path != _history) await late401.future;
        rejected++;
        return _oauthError('invalid_token', status: 401);
      };
      final service = serviceWith(_FakeTokenStorage(v2Session()));

      final planned = service.addToPlanToWatch(film);
      await pumpEventQueue();
      expect(await service.markWatched(film, null), isTrue);
      late401.complete();

      expect(await planned, isTrue);
      expect(rejected, 2);
      expect(adapter.to(_token), hasLength(1));
    });

    test('a refresh Simkl refuses (400, 401) signs the person out', () async {
      for (final (error, status) in [
        ('invalid_grant', 400),
        ('invalid_client', 401),
      ]) {
        adapter.requests.clear();
        adapter.reply = (options) => options.uri.path == _token
            ? _oauthError(error, status: status)
            : _json(const {}, status: 201);
        final storage = _FakeTokenStorage(
          v2Session(left: const Duration(hours: 1)),
        );
        final service = serviceWith(storage);

        expect(await service.markWatched(film, null), isFalse);
        expect(await service.isLoggedIn, isFalse, reason: error);
        expect(storage.values, isEmpty, reason: error);
        expect(adapter.to(_history), isEmpty);
      }
    });

    test(
      'a refresh that gets no answer, or is only held off (429, 503), '
      'keeps the session, and a token not yet expired still goes out',
      () async {
        for (final failure in <_Reply>[
          _offline,
          (_) => _oauthError('rate_limited', status: 429),
          (_) => _json(const {}, status: 503),
        ]) {
          adapter.requests.clear();
          adapter.reply = (options) => options.uri.path == _token
              ? failure(options)
              : _json(const {}, status: 201);
          final storage = _FakeTokenStorage(
            v2Session(left: const Duration(hours: 1)),
          );
          final service = serviceWith(storage);

          expect(await service.markWatched(film, null), isTrue);
          expect(
            adapter.to(_history).single.headers['Authorization'],
            'Bearer simkl_at_live',
          );
          expect(await service.isLoggedIn, isTrue);
          expect(storage.values[_refreshKey], 'simkl_rt_live');
        }
      },
    );

    test('an expired token whose refresh gets no answer sends nothing, and '
        'keeps the session for the next try', () async {
      adapter.reply = (options) => options.uri.path == _token
          ? _offline(options)
          : _json(const {}, status: 201);
      final storage = _FakeTokenStorage(
        v2Session(left: const Duration(hours: -1)),
      );
      final service = serviceWith(storage);

      expect(await service.markWatched(film, null), isFalse);
      expect(adapter.to(_history), isEmpty);
      expect(await service.isLoggedIn, isTrue);
      expect(storage.values[_refreshKey], 'simkl_rt_live');
    });

    test(
      'a refresh answered with a page instead of tokens - a bot check the '
      'app could not clear, passed on as an answer - keeps the session',
      () async {
        // The app's Dio hands a check it can't clear back as an ordinary answer
        // (ClearanceInterceptor), whatever its status: no exception, and no
        // tokens in it. That spends nothing, as a thrown 403 doesn't.
        dio.interceptors.add(
          InterceptorsWrapper(
            onError: (error, handler) {
              final response = error.response;
              if (response?.statusCode == 403) {
                handler.resolve(response!);
                return;
              }
              handler.next(error);
            },
          ),
        );
        for (final (status, body) in [
          (403, '<html>Just a moment...</html>'),
          (200, '<html>Sign in to this Wi-Fi</html>'),
        ]) {
          adapter.requests.clear();
          adapter.reply = (options) => options.uri.path == _token
              ? ResponseBody.fromString(
                  body,
                  status,
                  headers: {
                    Headers.contentTypeHeader: ['text/html'],
                  },
                )
              : _json(const {}, status: 201);
          final storage = _FakeTokenStorage(
            v2Session(left: const Duration(hours: 1)),
          );
          final service = serviceWith(storage);

          expect(
            await service.markWatched(film, null),
            isTrue,
            reason: '$status',
          );
          expect(await service.isLoggedIn, isTrue, reason: '$status');
          expect(
            storage.values[_refreshKey],
            'simkl_rt_live',
            reason: '$status',
          );
        }
      },
    );

    test(
      'the new refresh token is written before the new access token',
      () async {
        adapter.reply = (options) => options.uri.path == _token
            ? _json(tokens())
            : _json(const {}, status: 201);
        final storage = _FakeTokenStorage(
          v2Session(left: const Duration(hours: 1)),
        )..writesLeft = 1;

        await serviceWith(storage).markWatched(film, null);

        // Killed after one write: the refresh token Simkl just issued survives,
        // so the next start can still refresh.
        expect(storage.values[_refreshKey], 'simkl_rt_new');
      },
    );

    test('a 401 whose refresh Simkl refuses signs the person out, and the '
        'call is dropped', () async {
      adapter.reply = (options) => options.uri.path == _token
          ? _oauthError('invalid_grant')
          : _oauthError('invalid_token', status: 401);
      final storage = _FakeTokenStorage(v2Session());
      final service = serviceWith(storage);

      expect(await service.markWatched(film, null), isFalse);
      expect(await service.isLoggedIn, isFalse);
      expect(storage.values, isEmpty);
      expect(adapter.to(_history), hasLength(1));
    });

    test('a 401 whose refresh gets no answer keeps the session; the call is '
        'dropped', () async {
      adapter.reply = (options) => options.uri.path == _token
          ? _offline(options)
          : _oauthError('invalid_token', status: 401);
      final storage = _FakeTokenStorage(v2Session());
      final service = serviceWith(storage);

      expect(await service.markWatched(film, null), isFalse);
      expect(await service.isLoggedIn, isTrue);
      expect(storage.values[_refreshKey], 'simkl_rt_live');
    });

    test('a V2 token with no refresh token on file is signed out at its '
        'first 401: nothing could renew it', () async {
      adapter.reply = (_) => _oauthError('invalid_token', status: 401);
      final storage = _FakeTokenStorage({_accessKey: 'simkl_at_alone'});
      final service = serviceWith(storage);

      expect(await service.markWatched(film, null), isFalse);
      expect(adapter.to(_token), isEmpty);
      expect(await service.isLoggedIn, isFalse);
    });

    test('a V2 session in a build without the V2 app ends at its first '
        'refresh: Simkl knows no client to renew it for', () async {
      adapter.reply = (options) => options.uri.path == _token
          ? _oauthError('invalid_client', status: 401)
          : _json(const {}, status: 201);
      final storage = _FakeTokenStorage(
        v2Session(left: const Duration(hours: -1)),
      );
      final service = serviceWith(storage, v2ClientId: '');

      expect(await service.markWatched(film, null), isFalse);
      expect(_form(adapter.to(_token).single)['client_id'], '');
      expect(await service.isLoggedIn, isFalse);
    });

    test('signing out forgets the whole pair', () async {
      final storage = _FakeTokenStorage(v2Session());
      final service = serviceWith(storage);

      await service.logout();

      expect(storage.values, isEmpty);
      expect(await service.isLoggedIn, isFalse);
    });
  });

  group('a V1 session, signed in before V2', () {
    test('its calls still carry the V1 app', () async {
      adapter.reply = (_) => _json(const {}, status: 201);
      final service = serviceWith(_FakeTokenStorage(v1Session()));

      expect(await service.markWatched(film, null), isTrue);

      final call = adapter.to(_history).single;
      expect(call.headers['Authorization'], 'Bearer ${'ab' * 32}');
      expect(call.headers['simkl-api-key'], 'v1-client');
      expectNamesTheApp(call, clientId: 'v1-client');
    });

    test('a 401 (V1 ended, or the app was revoked) signs the person out, '
        'with no refresh to try', () async {
      adapter.reply = (_) => _oauthError('invalid_token', status: 401);
      final storage = _FakeTokenStorage(v1Session());
      final service = serviceWith(storage);

      expect(await service.markWatched(film, null), isFalse);
      expect(adapter.to(_token), isEmpty);
      expect(await service.isLoggedIn, isFalse);
      expect(storage.values, isEmpty);
    });
  });

  group('lookups (an id search, then the title\'s details)', () {
    ResponseBody list(List<Object> body) => ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

    /// Simkl's catalogue, answering whoever is let in.
    ResponseBody catalogue(RequestOptions options) =>
        options.uri.path == '/search/id'
        ? list([
            {
              'type': 'movie',
              'ids': {'simkl': 53536},
            },
          ])
        : _json(const {
            'ids': {'simkl': 53536, 'imdb': 'tt0133093', 'tmdb': 603},
          });

    bool isLookup(RequestOptions r) =>
        r.uri.path == '/search/id' || r.uri.path == '/movies/53536';

    test('go out on the V1 app with no token: Simkl refuses the V2 app any '
        "call without a person's token (measured 2026-10-12)", () async {
      adapter.reply = catalogue;

      final ids = await serviceWith(_FakeTokenStorage()).syncIds(film);

      expect(ids['imdb'], 'tt0133093');
      final lookups = adapter.requests.where(isLookup).toList();
      expect(lookups, hasLength(2));
      for (final lookup in lookups) {
        expectNamesTheApp(lookup, clientId: 'v1-client');
        expect(lookup.headers['Authorization'], isNull);
      }
    });

    test("a V1 session's lookups go out the same way", () async {
      adapter.reply = catalogue;

      await serviceWith(_FakeTokenStorage(v1Session())).syncIds(film);

      final lookups = adapter.requests.where(isLookup).toList();
      expect(lookups, hasLength(2));
      for (final lookup in lookups) {
        expectNamesTheApp(lookup, clientId: 'v1-client');
        expect(lookup.headers['Authorization'], isNull);
      }
    });

    /// V1 refused, as once Simkl ends it; the V2 app answers a person's token.
    ResponseBody v1Ended(RequestOptions options) =>
        options.uri.queryParameters['client_id'] == 'v1-client'
        ? _oauthError('invalid_client', status: 401)
        : options.headers['Authorization'] == 'Bearer simkl_at_live'
        ? catalogue(options)
        : _oauthError('user_token_required', status: 401);

    test('once V1 is refused, a V2 session looks up in the person\'s name, '
        'on the V2 app', () async {
      adapter.reply = v1Ended;

      final ids = await serviceWith(_FakeTokenStorage(v2Session()))
          .syncIds(film);

      expect(ids['imdb'], 'tt0133093');
      final signed = adapter.requests
          .where((r) => r.headers['Authorization'] != null)
          .toList();
      expect(signed, hasLength(2));
      for (final lookup in signed) {
        expect(lookup.headers['simkl-api-key'], 'v2-client');
        expectNamesTheApp(lookup, clientId: 'v2-client');
      }
    });

    test('after one refusal, V1 is not asked again', () async {
      adapter.reply = v1Ended;
      final service = serviceWith(_FakeTokenStorage(v2Session()));

      await service.syncIds(film);
      adapter.requests.clear();
      await service.syncIds(film);

      expect(
        adapter.requests.where(
          (r) => r.uri.queryParameters['client_id'] == 'v1-client',
        ),
        isEmpty,
      );
      expect(adapter.requests.where(isLookup), hasLength(2));
    });

    test(
      'a build without the V1 app looks up in a V2 session\'s name',
      () async {
        adapter.reply = v1Ended;

        final ids = await serviceWith(
          _FakeTokenStorage(v2Session()),
          v1ClientId: '',
        ).syncIds(film);

        expect(ids['imdb'], 'tt0133093');
        expect(
          adapter.requests.every((r) => r.headers['Authorization'] != null),
          isTrue,
        );
      },
    );

    test(
      'with V1 refused and no V2 session, there is nothing to ask with',
      () async {
        adapter.reply = v1Ended;

        final ids = await serviceWith(_FakeTokenStorage()).syncIds(film);

        expect(ids, isEmpty);
        expect(adapter.requests, hasLength(1));
      },
    );
  });
}
