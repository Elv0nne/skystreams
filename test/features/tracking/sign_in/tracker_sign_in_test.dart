import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/storage/secure_token_storage.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/tracking/data/anilist_service.dart';
import 'package:skystream/features/tracking/data/mal_service.dart';
import 'package:skystream/features/tracking/sign_in/embedded_sign_in.dart';
import 'package:skystream/features/tracking/sign_in/sign_in_method.dart';
import 'package:skystream/features/tracking/sign_in/tracker_sign_in.dart';

/// Tokens kept in memory: the real store reaches a Hive box tests never open.
class _Tokens extends SecureTokenStorage {
  _Tokens() : super(StorageService());

  final Map<String, String> saved = {};

  @override
  Future<String?> read(String key) async => saved[key];

  @override
  Future<void> write(String key, String value) async => saved[key] = value;

  @override
  Future<void> delete(String key) async => saved.remove(key);
}

/// MyAnimeList's token endpoint: grants a token, and keeps what it was sent.
class _TokenEndpoint implements HttpClientAdapter {
  final List<Map<String, String>> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = await utf8.decodeStream(requestStream!);
    requests.add(Uri.splitQueryString(body));
    return ResponseBody.fromString(
      jsonEncode({'access_token': 'mal-token', 'refresh_token': 'refresh'}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A sign-in page that answers with [answer], given what the request
/// carried; and what it was asked for.
class _Page {
  _Page(this.answer);

  final Uri? Function(Uri authorize, Uri redirect) answer;
  Uri? authorize;
  Uri? redirect;

  Future<Uri?> call(Uri authorize, Uri redirect) async {
    this.authorize = authorize;
    this.redirect = redirect;
    return answer(authorize, redirect);
  }
}

void main() {
  late _Tokens tokens;
  late _TokenEndpoint endpoint;
  late MalService mal;
  late AniListService aniList;

  setUp(() {
    tokens = _Tokens();
    endpoint = _TokenEndpoint();
    mal = MalService(Dio()..httpClientAdapter = endpoint, tokens);
    aniList = AniListService(Dio(), tokens);
  });

  group('redirect matching', () {
    test('compares parts, not text', () {
      final redirect = Uri.parse('http://localhost');
      expect(
        isRedirectAnswer(Uri.parse('http://localhost/?code=1'), redirect),
        isTrue,
      );
      expect(
        isRedirectAnswer(
          Uri.parse('http://localhost.example.com/?code=1'),
          redirect,
        ),
        isFalse,
      );
      expect(
        isRedirectAnswer(Uri.parse('https://localhost/?code=1'), redirect),
        isFalse,
      );
      expect(
        isRedirectAnswer(Uri.parse('http://localhost:8080/?code=1'), redirect),
        isFalse,
      );
      expect(
        isRedirectAnswer(Uri.parse('http://localhost/other?code=1'), redirect),
        isFalse,
      );
    });

    test('the sheet\'s stop ends after the host', () {
      expect(stopPrefix(Uri.parse('http://localhost')), 'http://localhost/');
      expect(
        stopPrefix(Uri.parse('http://localhost:43217/mal')),
        'http://localhost:43217/mal',
      );
    });
  });

  group('MyAnimeList', () {
    Uri answerWithCode(Uri authorize, Uri redirect) => redirect.replace(
      path: '/',
      queryParameters: {
        'code': 'the-code',
        'state': authorize.queryParameters['state'],
      },
    );

    test('PKCE, a state, and the same redirect twice', () async {
      final page = _Page(answerWithCode);
      final result = await TrackerSignIn(
        run: page.call,
        malClientId: 'mal-id',
      ).myAnimeList(mal);

      expect(result, SignInResult.signedIn);
      final query = page.authorize!.queryParameters;
      expect(page.authorize!.host, 'myanimelist.net');
      expect(page.redirect, Uri.parse('http://localhost'));
      expect(query['client_id'], 'mal-id');
      expect(query['redirect_uri'], 'http://localhost');
      expect(query['code_challenge_method'], 'plain');
      expect(query['code_challenge']!.length, inInclusiveRange(43, 128));
      expect(query['state'], isNotEmpty);
      final sent = endpoint.requests.single;
      expect(sent['code'], 'the-code');
      expect(sent['code_verifier'], query['code_challenge']);
      expect(sent['redirect_uri'], 'http://localhost');
      expect(tokens.saved['mal_access_token'], 'mal-token');
    });

    test('each sign-in carries a state of its own', () async {
      final first = _Page(answerWithCode);
      final second = _Page(answerWithCode);
      await TrackerSignIn(run: first.call).myAnimeList(mal);
      await TrackerSignIn(run: second.call).myAnimeList(mal);
      expect(
        first.authorize!.queryParameters['state'],
        isNot(second.authorize!.queryParameters['state']),
      );
    });

    test('an answer with another state, or from another host, is refused unsent', () async {
      for (final answer in [
        (Uri authorize, Uri redirect) =>
            Uri.parse('http://localhost/?code=c&state=someone-elses'),
        (Uri authorize, Uri redirect) => Uri.parse(
          'http://localhost.example.com/?code=c&state=${authorize.queryParameters['state']}',
        ),
      ]) {
        final result = await TrackerSignIn(run: _Page(answer).call)
            .myAnimeList(mal);
        expect(result, SignInResult.failed);
      }
      expect(endpoint.requests, isEmpty);
      expect(tokens.saved, isEmpty);
    });

    test('closing the page is a cancel, not a failure', () async {
      final result = await TrackerSignIn(run: _Page((_, _) => null).call)
          .myAnimeList(mal);
      expect(result, SignInResult.cancelled);
      expect(endpoint.requests, isEmpty);
    });
  });

  group('AniList', () {
    test('the implicit grant\'s token comes in the fragment', () async {
      final page = _Page(
        (authorize, redirect) => redirect.replace(
          path: '/',
          fragment:
              'access_token=al-token&token_type=Bearer&expires_in=31536000',
        ),
      );
      final result = await TrackerSignIn(
        run: page.call,
        anilistClientId: 'al-id',
      ).aniList(aniList);
      expect(result, SignInResult.signedIn);
      expect(page.authorize!.queryParameters, {
        'client_id': 'al-id',
        'response_type': 'token',
      });
      expect(page.redirect, Uri.parse('http://localhost'));
      expect(tokens.saved['anilist_access_token'], 'al-token');
    });

    test('an answer from another host is refused', () async {
      final result = await TrackerSignIn(
        run: _Page(
          (_, _) => Uri.parse('http://localhost.example.com/#access_token=x'),
        ).call,
      ).aniList(aniList);
      expect(result, SignInResult.failed);
      expect(tokens.saved, isEmpty);
    });

    test('closing the page is a cancel', () async {
      final result = await TrackerSignIn(run: _Page((_, _) => null).call)
          .aniList(aniList);
      expect(result, SignInResult.cancelled);
    });
  });
}
