import 'dart:convert';
import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:challenge_browser_example/test_site.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The plugin on this platform's real engine, against a local site with two origins.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late TestSite site;
  late ChallengeBrowser browser;
  final events = <BrowserEvent>[];

  /// Pumps until [found] holds, so platform views and their engines get frames meanwhile.
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() found,
    String what,
  ) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (!found()) {
      if (DateTime.now().isAfter(end)) {
        fail('Timed out waiting for $what. Events: $events');
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> loaded(WidgetTester tester, String path) async {
    events.clear();
    await browser.load(site.url(path));
    await waitFor(
      tester,
      () => events.any((e) => e is PageFinished && e.url.path == path),
      'load $path',
    );
  }

  Future<Object?> run(String script) async =>
      jsonDecode(await browser.evaluate(script));

  /// Pumps until [expression] is no longer null in the page, and returns it.
  Future<Object?> waitValue(WidgetTester tester, String expression) async {
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      final value = await run(expression);
      if (value != null) return value;
      if (DateTime.now().isAfter(end)) {
        fail('Timed out waiting for $expression. Events: $events');
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Pumps until the page's focused element is [id].
  Future<void> waitForActive(WidgetTester tester, String id) async {
    const active = 'document.activeElement && document.activeElement.id';
    for (var i = 0; i < 50 && await run(active) != id; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(await run(active), id);
  }

  setUp(() async {
    site = await TestSite.start();
    browser = await ChallengeBrowser.create();
    events.clear();
    browser.events.listen(events.add);
  });

  tearDown(() async {
    await browser.dispose();
    await site.close();
  });

  testWidgets(
    'loads, evaluates, and keeps the site\'s cookies with their flags',
    (tester) async {
      await loaded(tester, '/');
      expect(await run('document.title'), 'Home');
      expect(events.whereType<PageStarted>(), isNotEmpty);
      expect(events.whereType<PageProgress>().last.value, 1.0);

      final cookies = {
        for (final c in await browser.cookies(site.url('/'))) c.name: c,
      };
      expect(cookies['plain']?.httpOnly, isFalse);
      expect(
        cookies['secret']?.httpOnly,
        isTrue,
        reason: 'HttpOnly cookies are read, flag included',
      );
      expect(cookies['secret']?.value, '2');

      await browser.deleteCookies(site.url('/'), name: 'secret');
      final left = (await browser.cookies(site.url('/'))).map((c) => c.name);
      expect(left, contains('plain'));
      expect(left, isNot(contains('secret')));

      await browser.deleteCookies(site.url('/'));
      expect(await browser.cookies(site.url('/')), isEmpty);
      expect(await browser.userAgent, isNotEmpty);
    },
  );

  group('taps', () {
    /// Loads the widget stand-in and waits for its frame.
    Future<void> widget(WidgetTester tester, String dir) async {
      await loaded(tester, '/turnstile');
      // loaded() waited for the path; load the variant now that the site answered.
      events.clear();
      await browser.load(site.url('/turnstile?dir=$dir'));
      await waitFor(
        tester,
        () => events.any((e) => e is PageFinished && e.url.query == 'dir=$dir'),
        'load /turnstile?dir=$dir',
      );
      for (
        var i = 0;
        i < 100 && await run('window.boxReady === true') != true;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        await run('window.boxReady === true'),
        isTrue,
        reason: "the widget's frame loaded",
      );
    }

    Future<void> waitForTitle(WidgetTester tester, String title) async {
      for (var i = 0; i < 50 && await run('document.title') != title; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await run('document.title'), title);
    }

    testWidgets("a tap at the widget ticks the frame's checkbox", (
      tester,
    ) async {
      final capabilities = await ChallengeBrowser.capabilities();
      await widget(tester, 'ltr');
      if (!capabilities.canTap) {
        await expectLater(browser.tap(81, 338), throwsA(anything));
        return;
      }
      await browser.tap(81, 338);
      await waitForTitle(tester, 'Ticked');
      expect(
        await run(
          'document.querySelector(\'input[name="cf-turnstile-response"]\').value',
        ),
        'tok',
      );
    });

    testWidgets('a tap mirrors for a right-to-left widget', (tester) async {
      if (!(await ChallengeBrowser.capabilities()).canTap) return;
      await widget(tester, 'rtl');
      await browser.tap(943, 338);
      await waitForTitle(tester, 'Ticked');
    });

    testWidgets(
      'a hidden page lays out at 1024 by 768 CSS pixels, whatever the display scale',
      (tester) async {
        // Cloudflare's widget sits at the same place on every device only if the page does.
        await loaded(tester, '/');
        expect(await run('[window.innerWidth, window.innerHeight]'), [
          1024,
          768,
        ]);
      },
    );

    testWidgets(
      "a hidden page's text is 100% whatever the system font size; a shown page's follows it",
      (tester) async {
        // The fixed tap row assumes it: a bigger font moves Cloudflare's widget down the page.
        await loaded(tester, '/');
        const size = 'parseFloat(getComputedStyle(document.body).fontSize)';
        expect(await run(size), 16, reason: 'hidden');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ChallengeBrowserView(browser: browser)),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        final scale = tester.platformDispatcher.textScaleFactor;
        expect(
          ((await run(size)) as num).toDouble(),
          closeTo(16 * scale, 0.6),
          reason: 'shown, the person reads it at their own size',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 500));
        expect(await run(size), 16, reason: 'hidden again');
      },
    );

    testWidgets(
      "on Windows and Linux a page reads English, whatever the system's language",
      (tester) async {
        // Their browsers take a language for every request. Android's and Apple's keep the
        // device's: a language on the first request alone upset Cloudflare's checks.
        if (defaultTargetPlatform
            case TargetPlatform.windows || TargetPlatform.linux) {
          await loaded(tester, '/language');
          expect(await run('document.title'), startsWith('en-US'));
          expect(await run('navigator.language'), startsWith('en'));
        }
      },
    );

    testWidgets("a script's click doesn't count", (tester) async {
      await widget(tester, 'ltr');
      await run(
        'document.querySelector("iframe").contentWindow.postMessage("synthetic", "*"), true',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(await run('document.title'), 'Widget');
    });

    testWidgets('capabilities and the engine version', (tester) async {
      final capabilities = await ChallengeBrowser.capabilities();
      final version = await ChallengeBrowser.engineVersion();
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          expect(
            (capabilities.canTap, capabilities.isolatedWorlds),
            (true, false),
          );
          expect(version, matches(RegExp(r'^\d+\.')));
        case TargetPlatform.iOS:
          expect(
            (capabilities.canTap, capabilities.isolatedWorlds),
            (false, true),
          );
          expect(version, isEmpty);
        default:
          expect(
            (capabilities.canTap, capabilities.isolatedWorlds),
            (true, true),
          );
          expect(version, isEmpty);
      }
    });

    testWidgets("evaluateIsolated shares the DOM but not the page's globals", (
      tester,
    ) async {
      if (!(await ChallengeBrowser.capabilities()).isolatedWorlds) return;
      await loaded(tester, '/');
      await run('window.secret = 1, true');
      expect(
        jsonDecode(
          await browser.evaluateIsolated(
            '[typeof window.secret, document.title]',
          ),
        ),
        ['undefined', 'Home'],
      );
      expect(
        await run('typeof window.secret'),
        'number',
        reason: "the page's own world keeps it",
      );
    });

    testWidgets('evaluateIsolated is unsupported without an isolated world', (
      tester,
    ) async {
      if ((await ChallengeBrowser.capabilities()).isolatedWorlds) return;
      await loaded(tester, '/');
      await expectLater(browser.evaluateIsolated('1'), throwsUnsupportedError);
    });
  });

  testWidgets('a page served with an error status loads like any other', (
    tester,
  ) async {
    // Cloudflare's check comes as a 403: it is a page to wait on, not a failed load.
    await loaded(tester, '/forbidden');
    expect(await run('document.title'), 'Just a moment...');
    expect(events.whereType<PageError>(), isEmpty);
  });

  testWidgets('fetchInPage sends from inside the page, with its cookies', (
    tester,
  ) async {
    await loaded(tester, '/');
    final reply = await browser.fetchInPage(
      InPageRequest(site.url('/echo'), method: 'POST', body: 'hi'),
    );
    expect(reply.status, 200);
    expect(reply.body, startsWith('POST hi'));
    expect(
      reply.body,
      contains('secret=2'),
      reason: 'the HttpOnly cookie goes with it',
    );

    await expectLater(
      browser.fetchInPage(InPageRequest('${site.otherOrigin}/box')),
      throwsA(isA<InPageFetchException>()),
      reason: 'another origin is refused, as in the page itself',
    );
  });

  testWidgets(
    'a navigation to a stop prefix is reported, not loaded: redirects, posts and schemes',
    (tester) async {
      final callback = '${site.otherOrigin}/callback';
      await browser.setNavigationStops([callback, 'dev.example.app://']);
      Future<Uri> stoppedAt(String path) async {
        events.clear();
        await browser.load(site.url(path));
        await waitFor(
          tester,
          () => events.any((e) => e is NavigationStopped),
          'the stop for $path',
        );
        return events.whereType<NavigationStopped>().single.url;
      }

      String to(String url) => Uri.encodeQueryComponent(url);

      // A provider's plain redirect, with a code in the query.
      expect(
        await stoppedAt('/redirect?to=${to('$callback?code=1')}'),
        Uri.parse('$callback?code=1'),
      );
      // A form post answered with a redirect, the token in the fragment (AniList's implicit grant).
      final withToken = '$callback#access_token=abc&token_type=Bearer';
      expect(
        await stoppedAt('/authorize?to=${to(withToken)}'),
        Uri.parse(withToken),
      );
      // An app's own scheme.
      expect(
        await stoppedAt(
          '/redirect?to=${to('dev.example.app://oauth/cb?code=2')}',
        ),
        Uri.parse('dev.example.app://oauth/cb?code=2'),
      );
      expect(
        site.callbackHits,
        0,
        reason: 'a stopped navigation requests nothing',
      );

      // Without the stop, the same redirect loads.
      await browser.setNavigationStops(const []);
      events.clear();
      await browser.load(site.url('/redirect?to=${to('$callback?code=3')}'));
      await waitFor(
        tester,
        () => site.callbackHits == 1,
        'the callback to load',
      );
      expect(events.whereType<NavigationStopped>(), isEmpty);
    },
  );

  testWidgets('script messages and document-start scripts', (tester) async {
    await browser.addDocumentStartScript(
      'window.__early = document.readyState;',
    );
    await loaded(tester, '/');
    expect(
      await run('window.__early'),
      'loading',
      reason: 'it ran before the page did',
    );

    await run('(${browser.postScript})("hello")');
    await waitFor(
      tester,
      () => events.any((e) => e is ScriptMessage && e.message == 'hello'),
      'the message',
    );
  });

  testWidgets('capture reports the requests the page makes', (tester) async {
    await browser.setCapture(true);
    await loaded(tester, '/media');
    await waitFor(
      tester,
      () => events.any(
        (e) => e is CapturedRequest && e.url.path == '/video/master.m3u8',
      ),
      'the playlist request',
    );
    await waitFor(
      tester,
      () => events.any(
        (e) => e is CapturedRequest && e.url.path == '/video/clip.mp4',
      ),
      'the video source',
    );
  });

  testWidgets(
    'a shown page takes focus from Flutter, and is still the same page',
    (tester) async {
      await loaded(tester, '/');
      await run('window.__kept = 42');
      final before = FocusNode(debugLabel: 'Before');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  focusNode: before,
                  onPressed: () {},
                  child: const Text('Before'),
                ),
                Expanded(child: ChallengeBrowserView(browser: browser)),
                ElevatedButton(onPressed: () {}, child: const Text('After')),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        await run('window.__kept'),
        42,
        reason: 'showing it did not reload it',
      );

      before.requestFocus();
      await tester.pump(const Duration(milliseconds: 300));
      before.nextFocus();
      await waitFor(tester, () => _hasFocus, 'Flutter focus to reach the page');
      // The native side follows: the page has focus, on its first control.
      await waitForActive(tester, 'first');
      // Desktop engines count a page focused only while its window is the active one, which a test
      // run can't count on (another app in front, a locked screen).
      if (_mobile) expect(await run('document.hasFocus()'), isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        await run('window.__kept'),
        42,
        reason: 'hidden again, still the same page',
      );
    },
  );

  testWidgets(
    'Tab moves into the page, through its controls and out, both ways',
    (tester) async {
      await loaded(tester, '/');
      final before = FocusNode(debugLabel: 'Before');
      final after = FocusNode(debugLabel: 'After');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  focusNode: before,
                  onPressed: () {},
                  child: const Text('Before'),
                ),
                Expanded(child: ChallengeBrowserView(browser: browser)),
                ElevatedButton(
                  focusNode: after,
                  onPressed: () {},
                  child: const Text('After'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await _keys.invokeMethod<bool>('focusFlutter');
      before.requestFocus();
      await tester.pump(const Duration(milliseconds: 300));

      Future<void> tab({bool shift = false}) async {
        await _keys.invokeMethod<void>('tab', shift);
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tab();
      await waitForActive(tester, 'first');
      await tab();
      await waitForActive(tester, 'field');
      await tab();
      await waitForActive(tester, 'last');
      await tab();
      await waitFor(
        tester,
        () => after.hasPrimaryFocus,
        'Tab past the page to reach After',
      );

      await tab(shift: true);
      await waitForActive(tester, 'last');
      await tab(shift: true);
      await waitForActive(tester, 'field');
      await tab(shift: true);
      await waitForActive(tester, 'first');
      await tab(shift: true);
      await waitFor(
        tester,
        () => before.hasPrimaryFocus,
        'Shift+Tab past the page to reach Before',
      );
    },
    skip: !_keysHook,
  );

  testWidgets(
    'a click in the page brings Flutter\'s focus along, and Tab carries on from there',
    (tester) async {
      await loaded(tester, '/');
      final before = FocusNode(debugLabel: 'Before');
      final after = FocusNode(debugLabel: 'After');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  focusNode: before,
                  onPressed: () {},
                  child: const Text('Before'),
                ),
                Expanded(child: ChallengeBrowserView(browser: browser)),
                ElevatedButton(
                  focusNode: after,
                  onPressed: () {},
                  child: const Text('After'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await _keys.invokeMethod<bool>('focusFlutter');
      before.requestFocus();
      await tester.pump(const Duration(milliseconds: 300));

      final page = tester.getRect(find.byType(ChallengeBrowserView));
      final field =
          (await run(
                '(function(){var r=document.getElementById("field").getBoundingClientRect();'
                'return [r.left + r.width / 2, r.top + r.height / 2];})()',
              ))!
              as List;
      await _keys.invokeMethod<void>('click', [
        page.left + (field[0] as num).toDouble(),
        page.top + (field[1] as num).toDouble(),
      ]);
      await waitFor(
        tester,
        () => _hasFocus,
        'Flutter focus to follow the click into the page',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await waitForActive(tester, 'field');

      await _keys.invokeMethod<void>('tab', false);
      await waitForActive(tester, 'last');
      await _keys.invokeMethod<void>('tab', false);
      await waitFor(
        tester,
        () => after.hasPrimaryFocus,
        'Tab past the page to reach After',
      );
    },
    skip: !_keysHook,
  );

  testWidgets(
    'a page that goes away with keyboard focus gives the keys back to Flutter',
    (tester) async {
      await loaded(tester, '/');
      final first = FocusNode(debugLabel: 'First');
      final second = FocusNode(debugLabel: 'Second');
      Widget app({required bool page}) => MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              ElevatedButton(
                focusNode: first,
                onPressed: () {},
                child: const Text('First'),
              ),
              if (page) Expanded(child: ChallengeBrowserView(browser: browser)),
              ElevatedButton(
                focusNode: second,
                onPressed: () {},
                child: const Text('Second'),
              ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(app(page: true));
      await tester.pump(const Duration(seconds: 1));
      await _keys.invokeMethod<bool>('focusFlutter');
      first.requestFocus();
      await tester.pump(const Duration(milliseconds: 300));
      await _keys.invokeMethod<void>('tab', false);
      await waitForActive(tester, 'first');

      // As when a check clears and its sheet closes by itself.
      await tester.pumpWidget(app(page: false));
      await tester.pump(const Duration(milliseconds: 500));
      first.requestFocus();
      await tester.pump(const Duration(milliseconds: 300));
      await _keys.invokeMethod<void>('tab', false);
      await waitFor(
        tester,
        () => second.hasPrimaryFocus,
        'Tab to reach Flutter again',
      );
    },
    skip: !_keysHook,
  );

  testWidgets('a click on Flutter content takes the keys back from the page', (
    tester,
  ) async {
    await loaded(tester, '/');
    final before = FocusNode(debugLabel: 'Before');
    final after = FocusNode(debugLabel: 'After');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Title')),
          body: Column(
            children: [
              ElevatedButton(
                focusNode: before,
                onPressed: () {},
                child: const Text('Before'),
              ),
              Expanded(child: ChallengeBrowserView(browser: browser)),
              ElevatedButton(
                focusNode: after,
                onPressed: () {},
                child: const Text('After'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await _keys.invokeMethod<bool>('focusFlutter');
    before.requestFocus();
    await tester.pump(const Duration(milliseconds: 300));
    await _keys.invokeMethod<void>('tab', false);
    await waitForActive(tester, 'first');

    // Not a control: Flutter's focus stays on the page, but the keys are Flutter's again.
    final title = tester.getCenter(find.text('Title'));
    await _keys.invokeMethod<void>('click', [title.dx, title.dy]);
    await tester.pump(const Duration(milliseconds: 500));
    await _keys.invokeMethod<void>('tab', false);
    await waitFor(
      tester,
      () => after.hasPrimaryFocus,
      'Tab to move on in Flutter',
    );
    expect(
      await run('document.activeElement && document.activeElement.id'),
      'first',
    );
  }, skip: !_keysHook);

  testWidgets('Escape in the page reaches Flutter, to close what shows it', (
    tester,
  ) async {
    await loaded(tester, '/');
    final before = FocusNode(debugLabel: 'Before');
    var escaped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () => escaped++,
          },
          child: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  focusNode: before,
                  onPressed: () {},
                  child: const Text('Before'),
                ),
                Expanded(child: ChallengeBrowserView(browser: browser)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await _keys.invokeMethod<bool>('focusFlutter');
    before.requestFocus();
    await tester.pump(const Duration(milliseconds: 300));
    await _keys.invokeMethod<void>('tab', false);
    await waitForActive(tester, 'first');

    await _keys.invokeMethod<void>('escape');
    await waitFor(tester, () => escaped == 1, 'Escape to reach Flutter');
  }, skip: !_keysHook);

  testWidgets(
    'the check sheet: the keyboard starts in the page, ticks the check, and it closes verified',
    (tester) async {
      await loaded(tester, '/check');
      late Future<ChallengeSheetResult> result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => result = showChallengeSheet(
                    context,
                    browser: browser,
                    strings: _strings,
                    // The check's page goes home once ticked.
                    cleared: browser.events.firstWhere(
                      (e) => e is PageFinished && e.url.path == '/',
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await _keys.invokeMethod<bool>('focusFlutter');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await waitFor(
        tester,
        () => _hasFocus,
        'the keyboard to start in the page',
      );

      // The box is in a frame from another site. Engines differ in where entering the page puts focus:
      // on the box, on the frame itself a Tab short of it (WebKit on macOS), or before the frame.
      const active = 'document.activeElement && document.activeElement.tagName';
      bool verified() => find.text(_strings.verified).evaluate().isNotEmpty;
      for (var tabs = 0; tabs < 4 && !verified(); tabs++) {
        if (tabs > 0) await _keys.invokeMethod<void>('tab', false);
        await tester.pump(const Duration(milliseconds: 300));
        if (await run(active) != 'IFRAME') continue;
        await _keys.invokeMethod<void>('space');
        for (var i = 0; i < 20 && !verified(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }
      expect(verified(), isTrue, reason: 'the sheet says Verified');
      await tester.pumpAndSettle(const Duration(seconds: 1));
      expect(await result, ChallengeSheetResult.verified);
      expect(
        (await browser.cookies(site.url('/'))).map((c) => c.name),
        contains('clearance'),
      );
    },
    skip: !_keysHook,
  );

  group('served folders', () {
    late Directory folder;
    late File outside;

    setUp(() async {
      // A space and a non-ASCII letter in its path, as macOS's "Application
      // Support" and a person's name put in one.
      folder = await Directory.systemTemp.createTemp('cb served ü ');
      await File('${folder.path}/index.html').writeAsString(
        '<!doctype html><meta charset="utf-8"><title>Served</title>'
        '<script src="sub/page.js"></script>',
      );
      await File('${folder.path}/data.bin')
          .writeAsBytes(List.generate(1 << 20, (i) => i % 251));
      await Directory('${folder.path}/sub').create();
      await File('${folder.path}/sub/page.js').writeAsString('window.sub = 1;');
      // Beside the folder, never served.
      outside = File('${folder.path}-outside.bin');
      await outside.writeAsString('outside');
    });

    tearDown(() async {
      await folder.delete(recursive: true);
      await outside.delete();
    });

    /// Reads [path] by XHR from the page: "status bytes byte[1000]", or
    /// "error".
    Future<String> read(WidgetTester tester, String path) async {
      await run('''
(function () {
  window.read = null;
  var x = new XMLHttpRequest();
  x.open('GET', ${jsonEncode(path)});
  x.responseType = 'arraybuffer';
  x.onload = function () {
    window.read = x.status + ' ' + x.response.byteLength + ' ' +
      new Uint8Array(x.response)[1000];
  };
  x.onerror = function () { window.read = 'error'; };
  x.send();
  return true;
})()''');
      return await waitValue(tester, 'window.read') as String;
    }

    Future<void> served(WidgetTester tester, String base) async {
      events.clear();
      await browser.load('${base}index.html?game=test');
      await waitFor(
        tester,
        () => events.any((e) => e is PageFinished),
        'the served page',
      );
    }

    testWidgets(
      "a folder is served under an address of its own: its page, a 1 MB file "
      "beside it and what's below it, and nothing outside it",
      (tester) async {
        final base = await browser.serveFolder('cbtest-a1', folder.path);
        expect(base, endsWith('/'));
        await served(tester, base);
        expect(await run('document.title'), 'Served');
        expect(await run('location.href'), '${base}index.html?game=test');
        expect(await run('window.sub'), 1, reason: 'a file below the folder');
        expect(await read(tester, 'data.bin'), '200 1048576 ${1000 % 251}');
        final beside = Uri.encodeComponent(outside.uri.pathSegments.last);
        expect(
          await read(tester, '..%2F$beside'),
          isNot(startsWith('200')),
          reason: 'outside the folder',
        );
        expect(await read(tester, 'missing.bin'), isNot(startsWith('200')));
      },
    );

    testWidgets(
      'each name is an origin of its own, with its own storage, and a page '
      'reaches only the names it was given',
      (tester) async {
        final base = await browser.serveFolder('cbtest-b1', folder.path);
        await served(tester, base);
        await run("localStorage.setItem('kept', 'b1'); true");
        expect(await run("localStorage.getItem('kept')"), 'b1');
        final origin = await run('location.origin');
        final other = await ChallengeBrowser.create();
        final seen = <BrowserEvent>[];
        other.events.listen(seen.add);
        try {
          // The same folder under another name: another origin and storage.
          final second = await other.serveFolder('cbtest-b2', folder.path);
          await other.load('${second}index.html');
          await waitFor(
            tester,
            () => seen.any((e) => e is PageFinished),
            'the other page',
          );
          expect(
            jsonDecode(await other.evaluate('location.origin')),
            isNot(origin),
          );
          expect(
            jsonDecode(await other.evaluate("localStorage.getItem('kept')")),
            isNull,
          );
          // The first page's name isn't the other page's to reach.
          seen.clear();
          await other.load('${base}index.html');
          await waitFor(
            tester,
            () => seen.any((e) => e is PageError),
            "the first page's address failing in the other",
          );
          expect(
            seen.whereType<PageFinished>().where(
              (e) => e.url.toString().startsWith(base),
            ),
            isEmpty,
          );
        } finally {
          await other.dispose();
        }
      },
    );
  }, skip: !_servesAndHolds);

  group('held dialogs', () {
    /// The next held dialog, taken from the events.
    Future<PageDialog> next(WidgetTester tester) async {
      await waitFor(
        tester,
        () => events.any((e) => e is PageDialog),
        'a held dialog',
      );
      final dialog = events.whereType<PageDialog>().first;
      events.remove(dialog);
      return dialog;
    }

    testWidgets(
      'a prompt, a confirm and an alert wait for their answers, while the app '
      'keeps running; a 1 MB answer passes',
      (tester) async {
        // Before the load: WebView2 takes it as a document loads.
        await browser.holdDialogs(true);
        await loaded(tester, '/');
        // From a timer: the evaluate returns, then the page waits in its
        // prompt.
        await run(
          "setTimeout(function () { window.got = prompt('Your name?', "
          "'Player'); }, 0); true",
        );
        final prompt = await next(tester);
        expect(prompt.kind, DialogKind.prompt);
        expect(prompt.message, 'Your name?');
        expect(prompt.defaultText, 'Player');
        expect(prompt.url?.path, '/');
        // Held while the app runs on.
        await tester.pump(const Duration(milliseconds: 300));
        await browser.answerDialog(
          prompt.id,
          accept: true,
          text: 'y' * (1 << 20),
        );
        expect(
          await waitValue(tester, 'window.got && window.got.length'),
          1 << 20,
        );
        // Cancelled: null.
        await run(
          "setTimeout(function () { window.none = String(prompt('Again?')); "
          '}, 0); true',
        );
        await browser.answerDialog((await next(tester)).id, accept: false);
        expect(await waitValue(tester, 'window.none'), 'null');
        // A confirm, then an alert.
        await run(
          "setTimeout(function () { window.sure = confirm('Sure?'); "
          "alert('Done'); window.alerted = true; }, 0); true",
        );
        final confirm = await next(tester);
        expect(confirm.kind, DialogKind.confirm);
        await browser.answerDialog(confirm.id, accept: true);
        final alert = await next(tester);
        expect((alert.kind, alert.message), (DialogKind.alert, 'Done'));
        await browser.answerDialog(alert.id, accept: true);
        expect(
          await waitValue(tester, 'window.alerted && window.sure'),
          isTrue,
        );
      },
    );

    testWidgets("the page's title answers while a dialog holds the page", (
      tester,
    ) async {
      // Phase 7c: the app reads a finished page's title while the page may
      // wait in a held prompt, which no script in the page can get past.
      await browser.holdDialogs(true);
      await loaded(tester, '/');
      await run(
        "setTimeout(function () { window.got = prompt('Held?'); }, 0); true",
      );
      final prompt = await next(tester);
      expect(await browser.title().timeout(const Duration(seconds: 2)), 'Home');
      await browser.answerDialog(prompt.id, accept: true, text: 'ok');
      expect(await waitValue(tester, 'window.got'), 'ok');
    });

    testWidgets('a page disposed while its dialog is held goes quietly', (
      tester,
    ) async {
      await browser.holdDialogs(true);
      await loaded(tester, '/');
      await run("setTimeout(function () { alert('held'); }, 0); true");
      expect((await next(tester)).message, 'held');
      // tearDown disposes it with the alert still held: each engine must
      // let it go (WebKit raises over a handler never called).
    });
  }, skip: !_servesAndHolds);
}

const _strings = ChallengeSheetStrings(
  note: 'Tick the box to continue.',
  retry: 'Retry',
  fullScreen: 'Full screen',
  exitFullScreen: 'Exit full screen',
  close: 'Close',
  done: 'Done',
  verified: 'Verified',
);

/// The example app's test hook for keys and clicks sent through the native window.
const _keys = MethodChannel('challenge_browser_example/keys');

/// The example app's runner has the hook here.
bool get _keysHook => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};

bool get _mobile =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Phase 7c's served folders and held dialogs: everywhere but Android, whose
/// WebView reads an extension's files and shows its dialogs itself.
bool get _servesAndHolds => defaultTargetPlatform != TargetPlatform.android;

/// True while Flutter's focus is inside a shown page, rather than on a button.
bool get _hasFocus {
  final label = FocusManager.instance.primaryFocus?.debugLabel ?? '';
  return label.contains('AndroidView') ||
      label.contains('UiKitView') ||
      label.contains('PlatformView') ||
      label.contains('ChallengeBrowserView');
}
