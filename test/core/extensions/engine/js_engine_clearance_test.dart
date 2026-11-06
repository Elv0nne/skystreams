// What a plugin is doing decides how a bot check met by its HTTP is handled:
// any request may start a solve (the owner, 2026-10-03), and opening a title
// or its streams has the person waiting, who gets the check sheet.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart';
import 'package:skystream/core/extensions/providers/js_based_provider.dart';
import 'package:skystream/core/network/clearance/captcha_solver.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_interceptor.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/storage/extension_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';

import '../../network/clearance/fakes.dart';

class _FakeExtensionRepository extends ExtensionRepository {
  _FakeExtensionRepository() : super(StorageService());
}

/// Answers what the test sets, and records what it was asked.
class _FakeCaptchas implements Captchas {
  String answer = 'tok';
  Object? error;
  final calls =
      <({String siteKey, String url, bool personWaiting, String? source})>[];

  @override
  Future<String> solve({
    required String siteKey,
    required String url,
    required bool personWaiting,
    String? source,
  }) async {
    calls.add((
      siteKey: siteKey,
      url: url,
      personWaiting: personWaiting,
      source: source,
    ));
    if (error case final error?) throw error;
    return answer;
  }
}

/// Anubis in front of a site: its check page, with status 200, until a
/// request carries its cookie.
class _AnubisSite implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final cookie = options.headers['Cookie']?.toString() ?? '';
    if (cookie.contains('anubis-auth=jwt')) {
      return ResponseBody.fromString('results', 200);
    }
    return ResponseBody.fromString(
      '<!doctype html><html><head><title>Making sure you&#39;re not a bot!'
      '</title><link rel="stylesheet" href="/.within.website/x/xess/xess.min.css">',
      200,
      headers: {
        'content-type': ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers 200 at once and keeps each request's extras.
class _RecordingAdapter implements HttpClientAdapter {
  final List<Map<String, dynamic>> extras = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    extras.add(Map.of(options.extra));
    return ResponseBody.fromString('ok', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ReceivePort worker;
  late JsEngineService engine;
  late _RecordingAdapter adapter;
  final sent = <Object?>[];
  // Each engine numbers its invocations from 0.
  var invokes = 0;
  var bid = 0;

  setUp(() {
    invokes = 0;
    sent.clear();
    worker = ReceivePort()..listen(sent.add);
    adapter = _RecordingAdapter();
    engine = JsEngineService.withWorkerPort(
      _FakeExtensionRepository(),
      Dio()..httpClientAdapter = adapter,
      worker.sendPort,
    );
  });

  tearDown(() {
    engine.dispose();
    worker.close();
  });

  /// Runs [function] of plugin `com_a`, which makes one request, and returns
  /// the request's extras.
  Future<Map<String, dynamic>> extrasDuring(String function) async {
    final token = engine.mintBridgeToken(
      namespace: 'com_a__sub1',
      packageName: 'com.a',
    );
    final invoke = engine
        .invokeAsync('com_a__sub1.$function', const [])
        .catchError((Object _) => null);
    await pumpEventQueue();
    bid++;
    engine.handleWorkerMessage(<String, dynamic>{
      'bg': 1,
      'bid': bid,
      'ch': 'http_request',
      'aj': jsonEncode({
        'id': 'http_$bid',
        '__ssTok': token,
        'method': 'GET',
        'url': 'https://a.example/x',
      }),
    });
    await pumpEventQueue();
    // Let the invocation settle so no timeout timer is left behind.
    engine.handleWorkerMessage(<String, dynamic>{
      'ir': invokes++,
      'result': null,
      'err': null,
    });
    await invoke;
    return adapter.extras.last;
  }

  group('solveCaptcha', () {
    late _FakeCaptchas captchas;

    setUp(() {
      captchas = _FakeCaptchas();
      Clearance.instance.debugUseCaptchas(captchas);
    });
    tearDown(() => Clearance.instance.debugUseCaptchas(null));

    /// Sends `solveCaptcha(siteKey, url)` from plugin `com_a`, while
    /// [function] runs; its reply.
    Future<Map<dynamic, dynamic>> solve(String function) async {
      final token = engine.mintBridgeToken(
        namespace: 'com_a__sub1',
        packageName: 'com.a',
      );
      final invoke = engine
          .invokeAsync('com_a__sub1.$function', const [])
          .catchError((Object _) => null);
      await pumpEventQueue();
      bid++;
      final id = 'captcha_$bid';
      engine.handleWorkerMessage(<String, dynamic>{
        'bg': 1,
        'bid': bid,
        'ch': 'solve_captcha',
        'aj': jsonEncode({
          'id': id,
          '__ssTok': token,
          'siteKey': '0x4AAAAAAAkB2nGLjpB0hLFZ',
          'url': 'https://a.example/get',
        }),
      });
      await pumpEventQueue();
      engine.handleWorkerMessage(<String, dynamic>{
        'ir': invokes++,
        'result': null,
        'err': null,
      });
      await invoke;
      return sent.whereType<Map<dynamic, dynamic>>().lastWhere(
        (m) => m['jsId'] == id,
      );
    }

    test(
      'answers the token, with the person waiting when a title opens',
      () async {
        final reply = await solve('load');
        expect(reply['err'], isFalse);
        expect(reply.values, contains('tok'));
        expect(reply.values, isNot(contains('mock_captcha_token')));
        expect(captchas.calls.single.siteKey, '0x4AAAAAAAkB2nGLjpB0hLFZ');
        expect(captchas.calls.single.url, 'https://a.example/get');
        expect(captchas.calls.single.personWaiting, isTrue);
        expect(captchas.calls.single.source, 'js:com_a__sub1');
      },
    );

    test(
      'a search asks nobody, and a failure comes back as an error',
      () async {
        captchas.error = const CaptchaException('No token');
        final reply = await solve('search');
        expect(reply['err'], isTrue);
        expect(reply.values.whereType<String>().join(), contains('No token'));
        expect(captchas.calls.single.personWaiting, isFalse);
      },
    );
  });

  test('a check page that answers 200 (Anubis) is solved, and the request '
      'sent again with its clearance', () async {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    final pages = PageFactory([
      FakePage([
        for (var i = 0; i < 3; i++) const Step("Making sure you're not a bot!"),
        const Step(
          'Site',
          cookies: [
            StoredCookie(
              name: 'techaro.lol-anubis-auth',
              value: 'jwt',
              domain: 'a.example',
            ),
          ],
        ),
      ]),
    ]);
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      solver: ClearanceSolver(
        store: store,
        siteKeys: keys,
        openPage: pages.call,
        pollEvery: const Duration(milliseconds: 2),
      ),
    );
    final site = _AnubisSite();
    final dio = Dio()..httpClientAdapter = site;
    dio.interceptors.add(Clearance.instance.interceptorFor(dio)!);
    final anubis = JsEngineService.withWorkerPort(
      _FakeExtensionRepository(),
      dio,
      worker.sendPort,
    );
    addTearDown(anubis.dispose);

    bid++;
    final id = 'http_$bid';
    anubis.handleWorkerMessage(<String, dynamic>{
      'bg': 1,
      'bid': bid,
      'ch': 'http_request',
      'aj': jsonEncode({
        'id': id,
        'method': 'GET',
        'url': 'https://a.example/search?q=x',
      }),
    });
    Map<dynamic, dynamic>? reply;
    for (var i = 0; i < 300 && reply == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      reply = sent
          .whereType<Map<dynamic, dynamic>>()
          .where((m) => m['jsId'] == id)
          .firstOrNull;
    }
    final answer = reply!.values.whereType<Map<dynamic, dynamic>>().single;
    expect(answer['body'], 'results');
    expect(pages.opened, 1, reason: 'one solve');
    expect(site.requests, 2, reason: 'sent again once');
  });

  test('home rows may start a check, and ask nobody', () async {
    final extra = await extrasDuring('getHome');
    expect(extra.containsKey('clearance.mayStart'), isFalse);
    expect(extra[ClearanceExtra.personWaiting], isFalse);
  });

  test('a search may start one, and asks nobody', () async {
    final extra = await extrasDuring('search');
    expect(extra.containsKey('clearance.mayStart'), isFalse);
    expect(extra[ClearanceExtra.personWaiting], isFalse);
  });

  test('opening a title or its streams asks the person waiting', () async {
    for (final function in ['load', 'loadStreams']) {
      final extra = await extrasDuring(function);
      expect(
        extra.containsKey('clearance.mayStart'),
        isFalse,
        reason: function,
      );
      expect(extra[ClearanceExtra.personWaiting], isTrue, reason: function);
    }
  });

  test('a request carries its plugin, for the check it may meet', () async {
    final extra = await extrasDuring('search');
    expect(extra[ClearanceExtra.source], 'js:com_a__sub1');
  });

  test('a plugin is known by the same key', () {
    final provider = JsBasedProvider(
      engine,
      '/tmp/does-not-need-to-exist.js',
      packageName: 'com.a',
      namespace: 'com_a__sub1',
    );
    expect(provider.checkSource, 'js:com_a__sub1');
  });
}
