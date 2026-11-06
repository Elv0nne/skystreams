/// What the TMDB key dialog says when a key does not go through.
///
/// It used to have one answer for every failure - "Could not verify this key.
/// Check the key and your connection" - so a network that cannot reach TMDB,
/// a key that picked up invisible characters on its way through a chat app,
/// and the v4 read access token pasted in place of the v3 key all looked like
/// a bad key. The key a user pastes is often perfectly good.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/dio_client_provider.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/features/settings/presentation/widgets/settings_dialogs.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Made up. Real keys stay out of the repository.
const String _key = '0123456789abcdef0123456789abcdef';

/// Stands in for api.themoviedb.org behind the app's own [Dio].
class _FakeTmdb implements HttpClientAdapter {
  _FakeTmdb(this.answer);

  final ResponseBody Function(RequestOptions options) answer;
  final List<String> keysAsked = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    keysAsked.add(options.queryParameters['api_key'] as String);
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(String body, int status) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

/// Answers the way TMDB does: success for [_key], 401 for anything else.
ResponseBody _tmdb(RequestOptions options) =>
    options.queryParameters['api_key'] == _key
    ? _json('{"success":true}', 200)
    : _json(
        '{"status_code":7,"status_message":"Invalid API key",'
        '"success":false}',
        401,
      );

/// Records what the dialog saves instead of writing it to storage.
class _Settings extends GeneralSettingsNotifier {
  _Settings(this._saves);

  final List<String> _saves;

  @override
  GeneralSettings build() => const GeneralSettings();

  @override
  Future<void> setTmdbApiKey(String value) async {
    _saves.add(value);
    state = state.copyWith(tmdbApiKey: value);
  }
}

Future<void> _openAndSave(
  WidgetTester tester, {
  required _FakeTmdb tmdb,
  required _Settings settings,
  required String input,
}) async {
  final dio = Dio()..httpClientAdapter = tmdb;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dioClientProvider.overrideWithValue(dio),
        generalSettingsProvider.overrideWith(() => settings),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showTmdbApiKeyDialog(context, ref),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), input);
  await tester.tap(find.text('Save'));
  await tester.pumpAndSettle();
}

/// The error line the field shows, or null when it shows none.
String? _error(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).decoration?.errorText;

void main() {
  testWidgets('a key pasted with invisible characters is cleaned first', (
    tester,
  ) async {
    final tmdb = _FakeTmdb(_tmdb);
    final saves = <String>[];
    final settings = _Settings(saves);
    // A zero-width space in front, which trim() keeps, and a line break in
    // the middle, as a key wrapped across two lines arrives.
    await _openAndSave(
      tester,
      tmdb: tmdb,
      settings: settings,
      input: '​${_key.substring(0, 16)}\n${_key.substring(16)} ',
    );

    expect(tmdb.keysAsked, [_key]);
    expect(saves, [_key]);
    expect(find.byType(TextField), findsNothing, reason: 'dialog closed');
  });

  testWidgets('the v4 read access token is named, and TMDB is not asked', (
    tester,
  ) async {
    final tmdb = _FakeTmdb(_tmdb);
    final saves = <String>[];
    final settings = _Settings(saves);
    await _openAndSave(
      tester,
      tmdb: tmdb,
      settings: settings,
      input: 'eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiIwMTIzIn0.c2lnbmF0dXJl',
    );

    expect(tmdb.keysAsked, isEmpty);
    expect(saves, isEmpty);
    expect(_error(tester), contains('Read Access Token'));
  });

  testWidgets('a key TMDB rejects is reported as rejected', (tester) async {
    final tmdb = _FakeTmdb(_tmdb);
    final saves = <String>[];
    final settings = _Settings(saves);
    await _openAndSave(
      tester,
      tmdb: tmdb,
      settings: settings,
      input: 'ffffffffffffffffffffffffffffffff',
    );

    expect(saves, isEmpty);
    expect(_error(tester), contains('TMDB rejected this key'));
  });

  testWidgets('TMDB out of reach is not blamed on the key', (tester) async {
    final tmdb = _FakeTmdb(
      (options) => throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: const SocketException('Failed host lookup'),
      ),
    );
    final saves = <String>[];
    final settings = _Settings(saves);
    await _openAndSave(tester, tmdb: tmdb, settings: settings, input: _key);

    expect(saves, isEmpty);
    expect(_error(tester), contains("Couldn't reach TMDB"));
    expect(_error(tester), contains('DNS over HTTPS'));
    expect(_error(tester), isNot(contains('rejected')));
  });

  testWidgets('a page that is not TMDB answering 200 is not taken for yes', (
    tester,
  ) async {
    // What a network that intercepts TMDB can hand back: a block page, with
    // a success status.
    final tmdb = _FakeTmdb(
      (_) => ResponseBody.fromString(
        '<html>blocked</html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html'],
        },
      ),
    );
    final saves = <String>[];
    final settings = _Settings(saves);
    await _openAndSave(tester, tmdb: tmdb, settings: settings, input: _key);

    expect(saves, isEmpty);
    expect(_error(tester), contains("Couldn't reach TMDB"));
  });
}
