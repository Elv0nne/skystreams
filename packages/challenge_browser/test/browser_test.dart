import 'dart:async';
import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:challenge_browser/src/messages.g.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeHost host;

  setUp(() {
    host = FakeHost();
    ChallengeBrowser.debugResetCapabilities();
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test("load sends the caller's headers and no language of its own", () async {
    // A language sent with the first request only (Android's and Apple's engines take one per
    // request) made Cloudflare check again after every clearance: the page's own requests carry
    // the device's (2026-10-05, the phone emulator: 0 of 5 sites cleared with it, 4 of 5 without).
    final browser = await ChallengeBrowser.create();
    await browser.load('https://example.com/', headers: {'Referer': 'https://example.com/'});
    expect(host.callsOf('load').single, [
      browser.id,
      'https://example.com/',
      {'Referer': 'https://example.com/'},
    ]);
    await browser.dispose();
  });

  test("setUserAgent sends the page's new agent: an extension's own page only", () async {
    final browser = await ChallengeBrowser.create();
    await browser.setUserAgent('SkyStreamTest/1.0 (sign-in)');
    expect(host.callsOf('setUserAgent').single, [browser.id, 'SkyStreamTest/1.0 (sign-in)']);
    await browser.dispose();
  });

  test("serveFolder sends the page, the folder's name and the folder, and answers the address's base", () async {
    // Phase 7c's §6: a game's page reads the files beside it through the address the app serves them under.
    final browser = await ChallengeBrowser.create();
    expect(await browser.serveFolder('a1b2c3', '/data/files/game'), 'cbfolder://a1b2c3/');
    expect(host.callsOf('serveFolder').single, [browser.id, 'a1b2c3', '/data/files/game']);
    await browser.dispose();
  });

  test('a held dialog arrives as a PageDialog; holdDialogs and answerDialog reach the host', () async {
    // Phase 7c's §7 and §8: an answering call's prompt, and the page's own dialogs, wait for the app's answer.
    final browser = await ChallengeBrowser.create();
    final seen = <BrowserEvent>[];
    browser.events.listen(seen.add);
    await browser.holdDialogs(true);
    await host.emit(
      browser.id,
      PageEvent(
        kind: PageEventKind.dialog,
        dialogId: 3,
        dialogKind: DialogKind.prompt,
        message: 'Your name?',
        defaultText: 'Player',
        url: 'https://site.test/game',
      ),
    );
    final dialog = seen.single as PageDialog;
    expect(
      (dialog.id, dialog.kind, dialog.message, dialog.defaultText, dialog.url),
      (3, DialogKind.prompt, 'Your name?', 'Player', Uri.parse('https://site.test/game')),
    );
    await browser.answerDialog(3, accept: true, text: 'Tester');
    expect(host.callsOf('holdDialogs').single, [browser.id, true]);
    expect(host.callsOf('answerDialog').single, [browser.id, 3, true, 'Tester']);
    await browser.dispose();
  });

  test("title answers the page's title as its engine has it, running nothing in the page", () async {
    // Phase 7c: a page that waits in a held prompt runs no script, so reading document.title would wait with it.
    final browser = await ChallengeBrowser.create();
    host.titleReply = 'SkyStream Test sign-in';
    expect(await browser.title(), 'SkyStream Test sign-in');
    expect(host.callsOf('title').single, [browser.id]);
    expect(host.callsOf('evaluate'), isEmpty);
    host.titleReply = null;
    expect(await browser.title(), isNull);
    await browser.dispose();
  });

  group('taps and isolated reads', () {
    test('tap sends the page and its CSS point', () async {
      final browser = await ChallengeBrowser.create();
      await browser.tap(81, 338.5);
      expect(host.callsOf('tap').single, [browser.id, 81.0, 338.5]);
      await browser.dispose();
    });

    test('evaluateIsolated answers the host\'s JSON', () async {
      final browser = await ChallengeBrowser.create();
      host.evaluateIsolatedReply = '[1,"a"]';
      expect(await browser.evaluateIsolated('[1, "a"]'), '[1,"a"]');
      expect(host.callsOf('evaluateIsolated').single, [browser.id, '[1, "a"]']);
      await browser.dispose();
    });

    test('evaluateIsolated is unsupported without isolated worlds, and asks nothing', () async {
      host.capabilities = PageCapabilities(canTap: true, isolatedWorlds: false);
      final browser = await ChallengeBrowser.create();
      await expectLater(browser.evaluateIsolated('1'), throwsUnsupportedError);
      expect(host.callsOf('evaluateIsolated'), isEmpty);
      expect(host.callsOf('devTools'), isEmpty);
      await browser.dispose();
    });

    test('on Windows, evaluateIsolated builds an isolated world over DevTools, kept until the next load', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      host.devToolsReplies = {
        'Page.getFrameTree': '{"frameTree":{"frame":{"id":"F1","url":"http://127.0.0.1/"}}}',
        'Page.createIsolatedWorld': '{"executionContextId":7}',
        'Runtime.evaluate': '{"result":{"type":"object","value":[1,"a"]}}',
      };
      final browser = await ChallengeBrowser.create();
      expect(await browser.evaluateIsolated('[1, "a"]'), '[1,"a"]');
      List<String> methods() => [for (final call in host.callsOf('devTools')) call[1] as String];
      expect(methods(), ['Page.getFrameTree', 'Page.createIsolatedWorld', 'Runtime.evaluate']);
      final world = jsonDecode(host.callsOf('devTools')[1][2] as String) as Map;
      expect(world, {'frameId': 'F1', 'worldName': 'skystream'});
      final evaluate = jsonDecode(host.callsOf('devTools')[2][2] as String) as Map;
      expect(evaluate, {'expression': '[1, "a"]', 'contextId': 7, 'returnByValue': true});

      // The world is kept for the document.
      expect(await browser.evaluateIsolated('[1, "a"]'), '[1,"a"]');
      expect(methods(), hasLength(4));
      expect(methods().last, 'Runtime.evaluate');

      // A new document needs a new world.
      await host.emit(browser.id, PageEvent(kind: PageEventKind.pageStarted, url: 'http://127.0.0.1/next'));
      await pumpEventQueue();
      await browser.evaluateIsolated('1');
      expect(methods().sublist(4), ['Page.getFrameTree', 'Page.createIsolatedWorld', 'Runtime.evaluate']);
      expect(host.callsOf('evaluateIsolated'), isEmpty);
      await browser.dispose();
    });

    test('on Windows, an undefined result is null', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      host.devToolsReplies = {
        'Page.getFrameTree': '{"frameTree":{"frame":{"id":"F1"}}}',
        'Page.createIsolatedWorld': '{"executionContextId":3}',
        'Runtime.evaluate': '{"result":{"type":"undefined"}}',
      };
      final browser = await ChallengeBrowser.create();
      expect(await browser.evaluateIsolated('undefined'), 'null');
      await browser.dispose();
    });

    test('capabilities are asked once', () async {
      host.capabilities = PageCapabilities(canTap: false, isolatedWorlds: true);
      final first = await ChallengeBrowser.capabilities();
      final second = await ChallengeBrowser.capabilities();
      expect(first.canTap, isFalse);
      expect(first.isolatedWorlds, isTrue);
      expect(identical(first, second), isTrue);
      expect(host.callsOf('capabilities'), hasLength(1));
    });

    test('engineVersion answers the host\'s', () async {
      host.engineVersion = '133.0.6943.137';
      expect(await ChallengeBrowser.engineVersion(), '133.0.6943.137');
    });
  });

  test('create names a fresh channel per page', () async {
    final a = await ChallengeBrowser.create();
    final b = await ChallengeBrowser.create();
    final channels = host.callsOf('create').map((args) => args.single as String).toList();
    expect(channels, hasLength(2));
    expect(channels.first, isNot(channels.last));
    expect(channels.first, matches(RegExp(r'^_[a-z]{12}$')));
    expect(a.id, isNot(b.id));
    await a.dispose();
    await b.dispose();
  });

  test('events from the platform reach their own page only', () async {
    final a = await ChallengeBrowser.create();
    final b = await ChallengeBrowser.create();
    final seen = <BrowserEvent>[];
    a.events.listen(seen.add);
    await host.emit(a.id, PageEvent(kind: PageEventKind.pageFinished, url: 'http://127.0.0.1/'));
    await host.emit(b.id, PageEvent(kind: PageEventKind.pageFinished, url: 'http://127.0.0.1/other'));
    await host.emit(a.id, PageEvent(kind: PageEventKind.focusExit, direction: FocusDirection.backward));
    await host.emit(a.id, PageEvent(kind: PageEventKind.rendererGone, crashed: true));
    await pumpEventQueue();
    expect(seen, hasLength(3));
    expect((seen[0] as PageFinished).url.path, '/');
    expect((seen[1] as FocusExit).direction, FocusDirection.backward);
    expect((seen[2] as RendererGone).crashed, isTrue);
    await a.dispose();
    await b.dispose();
  });

  test('fetchInPage answers with the reply the page posts', () async {
    final browser = await ChallengeBrowser.create();
    final response = browser.fetchInPage(
      const InPageRequest('/echo', method: 'POST', headers: {'Content-Type': 'text/plain'}, body: 'hi'),
    );
    await pumpEventQueue();
    final script = host.callsOf('evaluate').single[1] as String;
    expect(script, contains('fetch("/echo"'));
    expect(script, contains('"method":"POST"'));
    expect(script, contains('"credentials":"include"'));
    await host.message(
      browser.id,
      // In the order the page's script builds it: the marker comes last.
      jsonEncode({
        'status': 200,
        'url': 'http://127.0.0.1/echo',
        'headers': {'content-type': 'text/plain'},
        'body': 'POST hi',
        '__cbm': 'fetch',
        'id': 0,
      }),
    );
    final reply = await response;
    expect(reply.status, 200);
    expect(reply.body, 'POST hi');
    expect(reply.headers['content-type'], 'text/plain');
    await browser.dispose();
  });

  test('fetchInPage fails with the page\'s error, and times out', () async {
    final browser = await ChallengeBrowser.create();
    final failing = expectLater(
      browser.fetchInPage(const InPageRequest('https://other.example/')),
      throwsA(isA<InPageFetchException>()),
    );
    await pumpEventQueue();
    await host.message(browser.id, jsonEncode({'__cbm': 'fetch', 'id': 0, 'error': 'TypeError: Failed to fetch'}));
    await failing;

    await expectLater(
      browser.fetchInPage(const InPageRequest('/slow'), timeout: const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
    await browser.dispose();
  });

  test('the page\'s own messages pass through; the plugin\'s are consumed', () async {
    final browser = await ChallengeBrowser.create();
    final seen = <BrowserEvent>[];
    browser.events.listen(seen.add);
    await host.message(browser.id, 'interactiveBegin');
    await host.message(browser.id, jsonEncode({'__cbm': 'fetch', 'id': 99, 'status': 200}));
    await pumpEventQueue();
    expect(seen.single, isA<ScriptMessage>().having((m) => m.message, 'message', 'interactiveBegin'));
    await browser.dispose();
  });

  test('capture reports requests only while on', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final browser = await ChallengeBrowser.create();
    final seen = <BrowserEvent>[];
    browser.events.listen(seen.add);
    final request = PageEvent(kind: PageEventKind.captured, url: 'http://127.0.0.1/video/master.m3u8', method: 'GET');
    await host.emit(browser.id, request);
    await browser.setCapture(true);
    await host.emit(browser.id, request);
    await browser.setCapture(false);
    await host.emit(browser.id, request);
    await pumpEventQueue();
    expect(host.callsOf('setCapture').map((args) => args[1]), [true, false]);
    expect(seen.single, isA<CapturedRequest>().having((r) => r.method, 'method', 'GET'));
    await browser.dispose();
  });

  test('on Apple platforms capture watches from the page instead', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final browser = await ChallengeBrowser.create();
    final seen = <BrowserEvent>[];
    browser.events.listen(seen.add);
    await browser.setCapture(true);
    await browser.setCapture(true);
    expect(host.callsOf('setCapture'), isEmpty);
    expect(host.callsOf('addDocumentStartScript'), hasLength(1), reason: 'the observer goes in once');
    expect(host.callsOf('evaluate').single[1], contains('PerformanceObserver'));
    expect(browser.postScript, contains('webkit.messageHandlers.'));
    await host.message(browser.id, jsonEncode({'__cbm': 'capture', 'url': 'https://cdn.example/a.m3u8'}));
    await pumpEventQueue();
    expect(seen.single, isA<CapturedRequest>().having((r) => r.url.host, 'host', 'cdn.example'));
    await browser.dispose();
  });

  test('cookies keep their flags', () async {
    final browser = await ChallengeBrowser.create();
    final cookies = await browser.cookies('http://127.0.0.1/');
    expect(cookies.single.httpOnly, isTrue);
    expect(cookies.single.toString(), contains('HttpOnly'));
    expect(await browser.userAgent, 'Engine/1.0');
    await browser.dispose();
  });

  test('dispose ends pending work, closes events and releases the page once', () async {
    final browser = await ChallengeBrowser.create();
    final pending = expectLater(browser.fetchInPage(const InPageRequest('/echo')), throwsA(isA<StateError>()));
    await pumpEventQueue();
    var closed = false;
    browser.events.listen(null, onDone: () => closed = true);
    await browser.dispose();
    await browser.dispose();
    await pending;
    expect(closed, isTrue);
    expect(browser.isDisposed, isTrue);
    expect(host.callsOf('dispose'), hasLength(1));
    // A late event for the page goes nowhere.
    await host.emit(browser.id, PageEvent(kind: PageEventKind.pageStarted, url: 'http://127.0.0.1/'));
  });
}
