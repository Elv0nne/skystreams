/// Tracker sign-in in SkyStream's own browser on this platform's real engine,
/// against a local stand-in for the provider: the sign-in page, its form post
/// and the redirect with the answer, in the query (MyAnimeList's code) or the
/// fragment (AniList's token). Then the real MyAnimeList and AniList sign-in
/// pages, with this build's client IDs, up to their login form (nobody's
/// credentials are typed).
///
/// ```
/// flutter test integration_test/sign_in/sign_in_test.dart -d DEVICE \
///   --dart-define=SIGN_IN_E2E=true [--dart-define-from-file=defines.json]
/// ```
///
/// Prints `SIGN-IN` lines as it goes.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/config/sync_config.dart';
import 'package:skystream/features/tracking/sign_in/sign_in_runner.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const _live = bool.fromEnvironment('SIGN_IN_E2E');

/// A stand-in for a provider's sign-in, on this device.
class _Provider {
  _Provider._(this._server);

  static Future<_Provider> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final provider = _Provider._(server);
    server.listen(provider._serve);
    return provider;
  }

  final HttpServer _server;

  /// The sign-in page: answers [redirect] with a code, or with a token in the
  /// fragment; through a posted form first when [post].
  Uri authorize(Uri redirect, {required bool token, bool post = false}) =>
      Uri.parse('http://127.0.0.1:${_server.port}/authorize').replace(
        queryParameters: {
          'redirect_uri': '$redirect',
          'token': '$token',
          'post': '$post',
          'state': 'st4te',
        },
      );

  Future<void> close() => _server.close(force: true);

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    final query = request.uri.queryParameters;
    switch (request.uri.path) {
      case '/authorize' when query['post'] == 'true':
        response.headers.contentType = ContentType.html;
        response.write(
          '<!doctype html><title>Sign in</title>'
          '<form id="f" method="post" action="/login?${request.uri.query}">'
          '<input name="user" value="person"></form>'
          '<script>document.getElementById("f").submit();</script>',
        );
      case '/authorize' || '/login':
        await request.drain<void>();
        final redirect = Uri.parse(query['redirect_uri']!);
        final path = redirect.path.isEmpty ? '/' : redirect.path;
        final answer = query['token'] == 'true'
            ? redirect.replace(
                path: path,
                fragment: 'access_token=t0ken&token_type=Bearer',
              )
            : redirect.replace(
                path: path,
                queryParameters: {'code': 'c0de', 'state': query['state']},
              );
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, '$answer');
      default:
        response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }
}

Future<bool> _isTv() async {
  if (!Platform.isAndroid) return false;
  final features = (await DeviceInfoPlugin().androidInfo).systemFeatures;
  return features.contains('android.software.leanback') ||
      features.contains('android.hardware.type.television');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late _Provider provider;
  late bool tv;

  setUp(() async {
    provider = await _Provider.start();
    tv = await _isTv();
  });
  tearDown(() => provider.close());

  /// A screen to sign in from; returns its context.
  Future<BuildContext> app(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: Text('SkyStream'))),
      ),
    );
    return tester.element(find.text('SkyStream'));
  }

  /// Runs [method] to [authorize], pumping frames for its sheet or dialog,
  /// until it answers. [during] runs once, a second in, for what a person
  /// would do meanwhile.
  Future<Uri?> signIn(
    WidgetTester tester,
    Uri authorize,
    Uri redirect, {
    Future<void> Function()? during,
  }) async {
    final context = await app(tester);
    final started = DateTime.now();
    Uri? answer;
    var done = false;
    Object? failure;
    unawaited(
      SignInRunner(context, provider: 'Test', tv: tv)
          .call(authorize, redirect)
          .then<void>(
            (url) => answer = url,
            onError: (Object e) {
              failure = e;
            },
          )
          .whenComplete(() => done = true),
    );
    var acted = during == null;
    while (!done) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!acted && DateTime.now().difference(started).inSeconds >= 1) {
        acted = true;
        await during!();
      }
      if (DateTime.now().difference(started) > const Duration(minutes: 2)) {
        fail('the sign-in gave no answer in 2 minutes');
      }
    }
    if (failure != null) fail('the sign-in failed: $failure');
    final seconds = DateTime.now().difference(started).inMilliseconds / 1000;
    print(
      'SIGN-IN embedded ${Platform.operatingSystem} tv=$tv ${seconds}s -> $answer',
    );
    return answer;
  }

  testWidgets('the embedded sign-in stops the redirect: a code, and a token', (
    tester,
  ) async {
    final redirect = Uri.parse(SyncConfig.signInRedirect);
    final code = await signIn(
      tester,
      provider.authorize(redirect, token: false, post: true),
      redirect,
    );
    expect(code!.queryParameters, {'code': 'c0de', 'state': 'st4te'});
    final token = await signIn(
      tester,
      provider.authorize(redirect, token: true),
      redirect,
    );
    expect(token!.fragment, 'access_token=t0ken&token_type=Bearer');
  }, skip: !_live);

  testWidgets('the real sign-in pages load for this build\'s clients', (
    tester,
  ) async {
    final pages = {
      if (SyncConfig.malClientId.isNotEmpty)
        'MyAnimeList': Uri.https('myanimelist.net', '/v1/oauth2/authorize', {
          'response_type': 'code',
          'client_id': SyncConfig.malClientId,
          'code_challenge': 'a' * 64,
          'code_challenge_method': 'plain',
          'redirect_uri': SyncConfig.signInRedirect,
          'state': 'st4te',
        }),
      if (SyncConfig.anilistClientId.isNotEmpty)
        'AniList': Uri.https('anilist.co', '/api/v2/oauth/authorize', {
          'client_id': SyncConfig.anilistClientId,
          'response_type': 'token',
        }),
    };
    if (pages.isEmpty) {
      print('SIGN-IN real pages: no client IDs in this build');
      return;
    }
    for (final MapEntry(key: name, value: authorize) in pages.entries) {
      // The embedded sign-in, as a TV runs it, closed by the person once the
      // page is up; the page's own title and text tell a login form from an
      // error.
      final browser = await ChallengeBrowser.create();
      final finished = Completer<void>();
      final events = browser.events.listen((e) {
        if (e is PageFinished && !finished.isCompleted) finished.complete();
      });
      await browser.load('$authorize');
      final end = DateTime.now().add(const Duration(seconds: 45));
      while (!finished.isCompleted && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      // Let its scripts draw the form.
      await tester.pump(const Duration(seconds: 3));
      final title = await browser.evaluate('document.title');
      final text = await browser.evaluate(
        '(document.body ? document.body.innerText : "").slice(0, 300)',
      );
      final fields = await browser.evaluate(
        'document.querySelectorAll("input[type=password], input[name=password]").length',
      );
      print(
        'SIGN-IN real $name title=$title passwordFields=$fields text=$text',
      );
      await events.cancel();
      await browser.dispose();
      // A login form, or the provider's own sign-in buttons; not an error
      // about the client or its redirect.
      final page = text.toLowerCase();
      expect(
        int.parse(fields) > 0 ||
            page.contains('log in') ||
            page.contains('login'),
        isTrue,
        reason: '$name showed no sign-in: $title $text',
      );
      for (final error in ['invalid', 'redirect_uri', 'unauthorized']) {
        expect(page, isNot(contains(error)), reason: '$name: $text');
      }
    }
  }, skip: !_live);
}
