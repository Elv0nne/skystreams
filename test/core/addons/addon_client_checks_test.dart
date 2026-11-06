import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/network/clearance/clearance_interceptor.dart';

/// Answers every request with the next of [answers], noting each request.
class _Server implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  ResponseBody Function(RequestOptions options) answer = (_) =>
      ResponseBody.fromString('{}', 200, headers: _json);

  static final _json = {
    Headers.contentTypeHeader: ['application/json'],
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return answer(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _cloudflare(int status, String body, {bool challenge = false}) =>
    ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
        'server': ['cloudflare'],
        if (challenge) 'cf-mitigated': ['challenge'],
      },
    );

final _addon = ManagedAddon(
  manifestUrl: 'https://addon.test/manifest.json',
  addedAt: DateTime(2026),
  manifest: AddonManifest.fromJson({
    'id': 'test.addon',
    'name': 'Test',
    'version': '1.0.0',
    'resources': ['catalog', 'meta', 'stream'],
    'types': ['movie'],
    'catalogs': [
      {'type': 'movie', 'id': 'top'},
    ],
  }),
);

/// Stremio add-ons' requests and bot checks: who waits on them, what a block
/// or an uncleared check says.
void main() {
  late _Server server;
  late AddonClient client;

  setUp(() {
    server = _Server();
    client = AddonClient(Dio()..httpClientAdapter = server);
  });

  test('a title\'s streams and details are filed under their add-on, a person waiting', () async {
    server.answer = (_) => ResponseBody.fromString(
      jsonEncode({'streams': <Object>[]}),
      200,
      headers: _Server._json,
    );
    await client.streams(_addon, type: 'movie', id: 'tt1', personWaiting: true);
    await client.meta(_addon, type: 'movie', id: 'tt1', personWaiting: true);
    for (final request in server.requests) {
      expect(request.extra[ClearanceExtra.source], 'addon:test.addon');
      expect(request.extra[ClearanceExtra.personWaiting], isTrue);
    }
  });

  test('catalogs are filed under their add-on, nobody waiting', () async {
    server.answer = (_) => ResponseBody.fromString(
      jsonEncode({'metas': <Object>[]}),
      200,
      headers: _Server._json,
    );
    await client.catalog(_addon, type: 'movie', id: 'top');
    expect(
      server.requests.single.extra[ClearanceExtra.source],
      'addon:test.addon',
    );
    expect(
      server.requests.single.extra[ClearanceExtra.personWaiting],
      isNot(true),
    );
  });

  test('a 404 is still "nothing here"', () async {
    server.answer = (_) => ResponseBody.fromString('', 404);
    expect(await client.meta(_addon, type: 'movie', id: 'tt1'), isNull);
  });

  test('a Cloudflare block page says the connection is blocked', () async {
    server.answer = (_) => _cloudflare(
      403,
      '<title>Attention Required! | Cloudflare</title> Sorry, you have been blocked',
    );
    expect(
      () => client.streams(_addon, type: 'movie', id: 'tt1'),
      throwsA(
        isA<AddonBlockedException>().having(
          (e) => e.message,
          'message',
          contains('addon.test blocked this connection'),
        ),
      ),
    );
  });

  test('a check the app couldn\'t clear is a check, not a failure', () async {
    server.answer = (_) =>
        _cloudflare(403, '<title>Just a moment...</title>', challenge: true);
    expect(
      () => client.streams(_addon, type: 'movie', id: 'tt1'),
      throwsA(
        isA<AddonCheckException>().having((e) => e.host, 'host', 'addon.test'),
      ),
    );
    server.answer = (_) => _cloudflare(
      503,
      '<title>Just a moment...</title><script src="/cdn-cgi/challenge-platform/h/b/orchestrate"></script>',
    );
    expect(
      () => client.meta(_addon, type: 'movie', id: 'tt2'),
      throwsA(isA<AddonCheckException>()),
    );
  });

  test('a page that isn\'t JSON is the old error, not a check', () async {
    server.answer = (_) => ResponseBody.fromString(
      '<html>Welcome</html>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
    expect(
      () => client.streams(_addon, type: 'movie', id: 'tt1'),
      throwsA(
        isA<AddonException>()
            .having((e) => e, 'type', isNot(isA<AddonCheckException>()))
            .having((e) => e.message, 'message', contains('non-JSON')),
      ),
    );
  });
}
