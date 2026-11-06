import 'dart:async';
import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';

import 'fake_page_browser.dart';

Map<String, dynamic> _open({
  int rid = 4,
  Map<String, Object?> interfaces = const {},
  Map<String, Object?> answering = const {},
}) => {
  'event': 'webRequest',
  'op': 'page',
  'rid': rid,
  'session': 2,
  'node': 9,
  'url': 'https://site.test/login',
  'headers': {'Referer': 'https://site.test/'},
  'userAgent': 'SkyStreamTest/1.0 (sign-in)',
  'interfaces': interfaces,
  'answering': answering,
};

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late FakePageBrowser browser;
  late ExtensionPages pages;
  late PageReports report;

  setUp(() {
    browser = FakePageBrowser();
    pages = ExtensionPages(create: () async => browser);
    report = PageReports();
  });

  test("a page opens with the extension's agent and its scripts, then loads its address with its headers", () async {
    var told = 0;
    pages.addListener(() => told++);
    await pages.open(
      _open(
        interfaces: {
          'Bridge': ['signedIn'],
        },
      ),
      report.call,
    );
    expect(browser.agent, 'SkyStreamTest/1.0 (sign-in)');
    expect(browser.scripts, [
      requestsScript('POST'),
      interfacesScript('POST', {
        'Bridge': ['signedIn'],
      }, marker: pages.at(2, 9)!.marker),
    ]);
    expect(browser.loads.single.url, 'https://site.test/login');
    expect(browser.loads.single.headers, {'Referer': 'https://site.test/'});
    expect(pages.at(2, 9)?.rid, 4);
    expect(pages.at(2, 8), isNull);
    expect(told, greaterThan(0), reason: 'the sheet hears of it');
  });

  test('with no interfaces, only the requests script; with no agent, the browser keeps its own', () async {
    await pages.open({..._open(), 'userAgent': null}, report.call);
    expect(browser.scripts, [requestsScript('POST')]);
    expect(browser.agent, isNull);
  });

  test("what the page does reaches the engine in order, with its cookies and title", () async {
    browser.jar = const [(name: 'session', value: 'ok', domain: '.site.test')];
    await pages.open(_open(), report.call);
    final url = Uri.parse('https://site.test/login');
    browser.controller
      ..add(PageStarted(url))
      ..add(
        const ScriptMessage(
          '{"cs3-req":1,"url":"https://site.test/api/me","method":"GET","headers":{"authorization":"Bearer t"}}',
        ),
      )
      ..add(const ScriptMessage('{"cs3-js":1,"name":"Bridge","method":"signedIn","args":["Test Person"]}'))
      ..add(const ScriptMessage('not ours'))
      ..add(PageFinished(url))
      ..add(
        PageError(url: Uri.parse('https://site.test/img.png'), code: -2, text: 'net::ERR_FAILED', mainFrame: false),
      );
    await _settle();
    expect(report.types, ['request', 'started', 'request', 'message', 'finished', 'failed']);
    final cookies = [
      {'name': 'session', 'value': 'ok', 'domain': '.site.test'},
    ];
    expect(report.reports[0].fields, {
      'url': 'https://site.test/login',
      'method': 'GET',
      'headers': const <String, String>{},
      'mainFrame': true,
    });
    expect(report.reports[1].fields, {'url': 'https://site.test/login', 'cookies': cookies});
    expect(report.reports[2].fields, {
      'url': 'https://site.test/api/me',
      'method': 'GET',
      'headers': {'authorization': 'Bearer t'},
      'mainFrame': false,
    });
    expect(report.reports[3].fields['message'], contains('"cs3-js":1'));
    expect(report.reports[4].fields, {'url': 'https://site.test/login', 'title': 'Sign in', 'cookies': cookies});
    expect(report.reports[5].fields, {
      'url': 'https://site.test/img.png',
      'code': -2,
      'text': 'net::ERR_FAILED',
      'mainFrame': false,
    });
    expect(report.reports.every((r) => r.rid == 4), isTrue);
  });

  test('a page that loads again, and an eval, go to the page; an eval of a page gone answers null', () async {
    await pages.open(_open(), report.call);
    await pages.navigate(4, 'https://site.test/next', const {'X': '1'});
    expect(browser.loads.last.url, 'https://site.test/next');
    expect(browser.loads.last.headers, {'X': '1'});
    expect(await pages.eval(4, 'document.cookie'), '"done"');
    expect(await pages.eval(99, 'document.cookie'), 'null');
  });

  test('ops that arrive while the page is still being made wait for it: a load goes after the first, a close ends it', () async {
    // A window shown and closed while a WebView2 controller is being made (hundreds of milliseconds): the engine's
    // page, navigate, eval and closePage arrive before the page exists.
    final made = Completer<ExtensionPageBrowser>();
    final slow = ExtensionPages(create: () => made.future);
    final opening = slow.open(_open(), report.call);
    final navigating = slow.navigate(4, 'https://site.test/next', const {});
    final evaluating = slow.eval(4, 'document.title');
    final closing = slow.close(4);
    made.complete(browser);
    await Future.wait([opening, navigating, evaluating, closing]);
    expect([for (final load in browser.loads) load.url], ['https://site.test/login', 'https://site.test/next']);
    expect(await evaluating, '"Sign in"');
    expect(browser.disposed, isTrue, reason: 'closed, not left loading');
    expect(slow.at(2, 9), isNull);
  });

  test("closeAll also ends a page still being made: the engine it was for stopped", () async {
    final made = Completer<ExtensionPageBrowser>();
    final slow = ExtensionPages(create: () => made.future);
    final opening = slow.open(_open(), report.call);
    final closingAll = slow.closeAll();
    made.complete(browser);
    await Future.wait([opening, closingAll]);
    expect(browser.disposed, isTrue);
    expect(slow.at(2, 9), isNull);
  });

  test('closePage disposes the page, and the sheet forgets it', () async {
    await pages.open(_open(), report.call);
    await pages.close(4);
    expect(browser.disposed, isTrue);
    expect(pages.at(2, 9), isNull);
    expect(report.types, isNot(contains('closed')), reason: 'the engine closed it: nothing to tell it');
  });

  test("a page that can't open, or whose renderer went, is told closed, and the sheet says it can't show", () async {
    final failing = ExtensionPages(create: () async => throw StateError('no WebView2'));
    await failing.open(_open(), report.call);
    expect(report.types, ['closed']);
    expect(failing.failedAt(2, 9), isTrue);

    await pages.open(_open(rid: 5), report.call);
    browser.controller.add(const RendererGone(crashed: true));
    await _settle();
    expect([report.reports.last.rid, report.reports.last.type, report.reports.last.fields], [5, 'closed', isEmpty]);
    expect(browser.disposed, isTrue);
    expect(pages.failedAt(2, 9), isTrue);
    expect(pages.at(2, 9), isNull);
  });

  test('closeAll disposes every page: the engine they were for stopped', () async {
    await pages.open(_open(), report.call);
    await pages.closeAll();
    expect(browser.disposed, isTrue);
    expect(pages.at(2, 9), isNull);
  });

  test("the scripts post through the page's channel, and name the extension's interfaces", () {
    expect(requestsScript('P'), contains('var post = P;'));
    expect(requestsScript('P'), contains("'cs3-req': 1"));
    final interfaces = interfacesScript('P', {
      'SkyStreamTest': ['signedIn'],
    });
    expect(interfaces, contains('{"SkyStreamTest":["signedIn"]}'));
    expect(interfaces, contains("'cs3-js': 1"));
  });

  test(
    "a page in a full-screen window gets its extension's toasts, and on a desktop its own ×, which backs its screen",
    () async {
      // Phase 7c's §2: nothing of the app's shows over a page that is a window of its own (Windows, Linux).
      final desktop = ExtensionPages(create: () async => browser, desktop: true);
      final backs = <int>[];
      final listening = desktop.backs.listen(backs.add);
      await desktop.open({..._open(), 'fullScreen': true}, report.call);
      expect(browser.scripts.last, fullScreenScript('POST', closeButton: true));
      browser.controller.add(const ScriptMessage('{"cs3-back":1}'));
      await _settle();
      expect(backs, [2]);
      browser.answer = 'true';
      expect(await desktop.toast('Press back again to save & exit'), isTrue);
      expect(browser.evaluated.last, contains('"Press back again to save & exit"'));
      await listening.cancel();
    },
  );

  test('on iOS a full-screen page gets its toasts and no ×; a page in any other window gets neither', () async {
    final ios = ExtensionPages(create: () async => browser, desktop: false);
    await ios.open({..._open(), 'fullScreen': true}, report.call);
    expect(browser.scripts.last, fullScreenScript('POST', closeButton: false));
    final other = FakePageBrowser();
    final plain = ExtensionPages(create: () async => other, desktop: true);
    await plain.open(_open(), report.call);
    expect(other.scripts.where((script) => script.contains('__cs3Toast')), isEmpty);
    expect(await plain.toast('Hi'), isFalse);
  });

  test("a page whose window asks for the whole screen after it opened gets that page's script then, once", () async {
    // Opened before its window turned full screen, a desktop page had no × of its own, and SkyStream draws none over a
    // page: no way out.
    final desktop = ExtensionPages(create: () async => browser, desktop: true);
    await desktop.open(_open(), report.call);
    final script = fullScreenScript('POST', closeButton: true);
    expect(browser.scripts, isNot(contains(script)));
    await desktop.fullScreen(2, 9);
    expect(browser.scripts.where((s) => s == script), hasLength(1), reason: "for the page's next documents");
    expect(browser.evaluated.where((s) => s == script), hasLength(1), reason: 'and the one it shows now');
    await desktop.fullScreen(2, 9);
    expect(browser.scripts.where((s) => s == script), hasLength(1), reason: 'once');
    browser.answer = 'true';
    expect(await desktop.toast('Saved'), isTrue, reason: "its extension's toasts go in it now");
  });

  group('served folders (Phase 7c §6)', () {
    const name = 'a1b2c3d4e5f6a7b8c9d0';
    Map<String, Object?> serve({
      String folder = '/data/files/game',
      String path = 'index.html?game=test',
      String n = name,
    }) => {'name': n, 'folder': folder, 'path': path, 'file': 'file://$folder/'};

    test(
      "a page of the extension's own files loads under its folder's served address, and reports file addresses",
      () async {
        await pages.open({
          ..._open(),
          'url': 'file:///data/files/game/index.html?game=test',
          'serve': serve(),
        }, report.call);
        expect(browser.served.single, (name: name, folder: '/data/files/game'));
        expect(browser.loads.single.url, 'cbfolder://$name/index.html?game=test');
        final page = Uri.parse('cbfolder://$name/index.html?game=test');
        browser.controller
          ..add(PageStarted(page))
          ..add(const ScriptMessage('{"cs3-req":1,"url":"cbfolder://$name/rom.gba","method":"GET","headers":{}}'))
          ..add(PageFinished(page))
          ..add(
            PageError(url: Uri.parse('cbfolder://$name/missing.png'), code: -1100, text: 'not found', mainFrame: false),
          );
        await _settle();
        expect(
          [for (final r in report.reports) r.fields['url']],
          [
            'file:///data/files/game/index.html?game=test', // its start's request
            'file:///data/files/game/index.html?game=test',
            'file:///data/files/game/rom.gba',
            'file:///data/files/game/index.html?game=test',
            'file:///data/files/game/missing.png',
          ],
        );
      },
    );

    test("a load into another folder serves that one; one the browser can't serve, and any other address, load as they are", () async {
      await pages.open({
        ..._open(),
        'url': 'file:///data/files/game/index.html',
        'serve': serve(path: 'index.html'),
      }, report.call);
      await pages.navigate(
        4,
        'file:///data/cache/nes/nes.html',
        const {},
        serve: serve(folder: '/data/cache/nes', path: 'nes.html', n: 'ffff'),
      );
      expect(browser.loads.last.url, 'cbfolder://ffff/nes.html');
      browser.servesFolders = false;
      await pages.navigate(
        4,
        'file:///data/cache/snes/snes.html',
        const {},
        serve: serve(folder: '/data/cache/snes', path: 'snes.html', n: 'eeee'),
      );
      expect(browser.loads.last.url, 'file:///data/cache/snes/snes.html');
      await pages.navigate(4, 'https://site.test/', const {});
      expect(browser.loads.last.url, 'https://site.test/');
      final page = pages.at(2, 9)!;
      expect(page.fileUrl('cbfolder://ffff/nes.html#x'), 'file:///data/cache/nes/nes.html#x');
      expect(page.fileUrl('https://site.test/'), 'https://site.test/');
    });
  });

  group("an untitled page's title (part 2's review, 4)", () {
    // Android's WebView gives a page with no title of its own its address for one, as Chromium formats it for display
    // (GetTitleForDisplay): a file page's name and what follows it, any other page's address without "https://",
    // "http://" or "www.". The browsers off Android give the address they loaded: WebView2 in the same Chromium form,
    // WebKitGTK null, WebKit "".
    Future<Object?> titleOf(String? pageTitle, String url) async {
      browser.pageTitle = pageTitle;
      browser.controller.add(PageFinished(Uri.parse(url)));
      await _settle();
      return report.reports.last.fields['title'];
    }

    Future<void> served(String base) async {
      browser.servedBase = (name) => base;
      await pages.open({
        ..._open(),
        'url': 'file:///data/files/game/index.html?game=test',
        'serve': {
          'name': 'a1',
          'folder': '/data/files/game',
          'path': 'index.html?game=test',
          'file': 'file:///data/files/game/',
        },
      }, report.call);
    }

    test("a served page's is its file's name and what follows, as Android's; never its served address", () async {
      await served('cbfolder://a1/');
      expect(await titleOf('', 'cbfolder://a1/index.html?game=test'), 'index.html?game=test');
      expect(await titleOf(null, 'cbfolder://a1/sub/level.html#top'), 'level.html#top');
      expect(await titleOf('cbfolder://a1/index.html', 'cbfolder://a1/index.html'), 'index.html');
      expect(await titleOf(null, 'cbfolder://a1/my%20game/start%20here.html'), 'start here.html');
      expect(await titleOf('Test Game', 'cbfolder://a1/index.html'), 'Test Game', reason: 'its own title stands');
    });

    test("on Windows, WebView2's own form of the served address never reaches the extension", () async {
      await served('https://a1.example/');
      expect(
        await titleOf('a1.example/index.html?game=test', 'https://a1.example/index.html?game=test'),
        'index.html?game=test',
      );
      expect(await titleOf('https://a1.example/index.html', 'https://a1.example/index.html'), 'index.html');
    });

    test("any other page's is its address as Chromium shows it", () async {
      await pages.open(_open(), report.call);
      expect(await titleOf(null, 'https://site.test/login?next=1'), 'site.test/login?next=1');
      expect(await titleOf('', 'https://www.site.test/'), 'site.test');
      expect(await titleOf('', 'http://user:secret@site.test/a%20b'), 'site.test/a b');
      expect(await titleOf('site.test/login', 'https://site.test/login'), 'site.test/login');
      expect(await titleOf(null, 'about:blank'), 'about:blank');
    });
  });

  group('answering calls (Phase 7c §7)', () {
    late ExtensionPages pages;

    setUp(() => pages = ExtensionPages(create: () async => browser, callLimit: const Duration(milliseconds: 200)));

    Future<ExtensionPage> opened(ExtensionPages pages) async {
      await pages.open(
        _open(
          interfaces: {
            'Game': ['saveState'],
          },
          answering: {
            'Game': ['loadState'],
          },
        ),
        report.call,
      );
      return pages.at(2, 9)!;
    }

    String call(String method, String id) =>
        jsonEncode({'cs3-js': 1, 'name': 'Game', 'method': method, 'args': const <Object?>[], 'id': id});

    PageDialog prompt(ExtensionPage page, String id, {int dialog = 1}) =>
        PageDialog(id: dialog, kind: DialogKind.prompt, message: '${page.marker}$id');

    test('the page holds its dialogs, and its answering methods prompt with its own marker', () async {
      final page = await opened(pages);
      expect(browser.holding, isTrue);
      expect(
        browser.scripts,
        contains(
          interfacesScript(
            'POST',
            {
              'Game': ['saveState'],
            },
            answering: {
              'Game': ['loadState'],
            },
            marker: page.marker,
          ),
        ),
      );
      expect(page.marker, matches(RegExp(r'^cs3-[a-z0-9]{16}:$')));
      final other = ExtensionPages(create: () async => FakePageBrowser());
      await other.open(_open(), report.call);
      expect(other.at(2, 9)!.marker, isNot(page.marker));
    });

    test(
      'a call posted with its id is asked of the engine, and its prompt is answered with the value, as JSON',
      () async {
        final page = await opened(pages);
        report.answers['call'] = {'value': '{"level":3}'};
        browser.controller
          ..add(ScriptMessage(call('loadState', 'd.1')))
          ..add(prompt(page, 'd.1', dialog: 7));
        await _settle();
        expect(report.types, ['call']);
        expect(report.reports.single.fields, {'message': call('loadState', 'd.1')});
        expect(browser.answered.single, (id: 7, accept: true, text: jsonEncode({'v': '{"level":3}'})));
      },
    );

    test(
      'a prompt that comes before its call waits for it; a throw, undefined and null answer as the page reads them',
      () async {
        final page = await opened(pages);
        report.answers['call'] = {'error': 'Java exception was raised during method invocation'};
        browser.controller.add(prompt(page, 'd.1'));
        await _settle();
        expect(browser.answered, isEmpty, reason: 'its call has not come');
        browser.controller.add(ScriptMessage(call('loadState', 'd.1')));
        await _settle();
        expect(browser.answered.last.text, jsonEncode({'e': 'Java exception was raised during method invocation'}));
        report.answers['call'] = {};
        browser.controller
          ..add(ScriptMessage(call('loadState', 'd.2')))
          ..add(prompt(page, 'd.2', dialog: 2));
        await _settle();
        expect(browser.answered.last, (id: 2, accept: true, text: '{}'));
        report.answers['call'] = {'value': null};
        browser.controller
          ..add(ScriptMessage(call('loadState', 'd.3')))
          ..add(prompt(page, 'd.3', dialog: 3));
        await _settle();
        expect(browser.answered.last.text, '{"v":null}');
      },
    );

    test('one-way calls reach the engine before an answering one, in the order the page made them', () async {
      final page = await opened(pages);
      browser.controller
        ..add(const ScriptMessage('{"cs3-js":1,"name":"Game","method":"saveState","args":["a"]}'))
        ..add(ScriptMessage(call('loadState', 'd.1')))
        ..add(prompt(page, 'd.1'));
      await _settle();
      expect(report.types, ['message', 'call']);
    });

    test("a page waiting in its call's prompt runs no script, and nothing ahead of the call waits on one", () async {
      // iOS, 2026-10-09: a finished page's title, read by a script in the page, waited behind the page's own call
      // (10 s, the read's limit), and the call's prompt waited on the read.
      final page = await opened(pages);
      report.answers['call'] = {'value': true};
      browser.scriptsWait = true;
      browser.controller
        ..add(PageFinished(Uri.parse('https://site.test/game')))
        ..add(ScriptMessage(call('isReady', 'd.1')))
        ..add(prompt(page, 'd.1'));
      await _settle();
      expect(report.types, ['finished', 'call']);
      expect(report.reports.first.fields['title'], 'Sign in', reason: "the browser's own title");
      expect(browser.answered.single, (id: 1, accept: true, text: '{"v":true}'));
    });

    test('a call with no answer in time answers undefined', () async {
      final page = await opened(pages);
      browser.controller.add(prompt(page, 'd.9'));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(browser.answered.single, (id: 1, accept: true, text: '{}'));
    });

    test('a page closed while its call waits stops waiting with it: undefined at once, its events stopped, nothing escapes', () async {
      // The engine closed the window mid-call: the prompt's wait ends with the page, not 30 s later. Whatever the
      // page does with undefined reaches the engine no more.
      final waiting = ExtensionPages(create: () async => browser, callLimit: const Duration(minutes: 1));
      final page = await opened(waiting);
      browser.controller.add(prompt(page, 'd.1'));
      await _settle();
      final closing = waiting.close(4);
      browser.controller.add(const ScriptMessage('{"cs3-js":1,"name":"Game","method":"saveState","args":[""]}'));
      await closing;
      await _settle();
      expect(browser.answered.single, (id: 1, accept: true, text: '{}'));
      expect(report.types, isEmpty);
      expect(browser.disposed, isTrue);
    });
  });

  group("the page's own dialogs (Phase 7c §8)", () {
    test("go to the extension's chrome client, whose answer is the page's, with its file address", () async {
      await pages.open({
        ..._open(),
        'url': 'file:///data/files/game/index.html',
        'serve': {'name': 'a1', 'folder': '/data/files/game', 'path': 'index.html', 'file': 'file:///data/files/game/'},
      }, report.call);
      report.answers['dialog'] = {'accept': true, 'text': 'Tester'};
      browser.controller.add(
        PageDialog(
          id: 4,
          kind: DialogKind.prompt,
          message: 'Your name?',
          defaultText: 'Player',
          url: Uri.parse('cbfolder://a1/index.html'),
        ),
      );
      await _settle();
      expect(report.reports.single.type, 'dialog');
      expect(report.reports.single.fields, {
        'kind': 'prompt',
        'message': 'Your name?',
        'defaultText': 'Player',
        'url': 'file:///data/files/game/index.html',
      });
      expect(browser.answered.single, (id: 4, accept: true, text: 'Tester'));
    });

    test("with no chrome client the page gets cancel; the page's own prompt isn't taken for a call", () async {
      await pages.open(
        _open(
          answering: {
            'Game': ['loadState'],
          },
        ),
        report.call,
      );
      report.answers['dialog'] = {'accept': false};
      browser.controller.add(const PageDialog(id: 2, kind: DialogKind.prompt, message: 'cs3-but-not-its-marker:d.1'));
      await _settle();
      expect(report.types, ['dialog']);
      expect(browser.answered.single, (id: 2, accept: false, text: null));
    });

    test('a client that leaves one to the app has SkyStream show it; pages that are windows of their own step aside meanwhile', () async {
      final shown = <PageDialog>[];
      final person = Completer<({bool accept, String? text})>();
      pages.dialogs = (dialog, gone) {
        shown.add(dialog);
        return person.future;
      };
      var told = 0;
      pages.addListener(() => told++);
      await pages.open(_open(), report.call);
      report.answers['dialog'] = {'show': true};
      browser.controller.add(const PageDialog(id: 5, kind: DialogKind.confirm, message: 'Keep playing?'));
      await _settle();
      expect(shown.single.message, 'Keep playing?');
      expect(pages.showsDialog, isTrue);
      final before = told;
      person.complete((accept: true, text: null));
      await _settle();
      expect(browser.answered.single, (id: 5, accept: true, text: null));
      expect(pages.showsDialog, isFalse);
      expect(told, greaterThan(before), reason: 'the pages come back');
    });

    test('two pages at once: each is answered on its own page, and pages stay aside until the last closes', () async {
      final second = FakePageBrowser();
      final made = [browser, second];
      final two = ExtensionPages(create: () async => made.removeAt(0));
      final people = <Completer<({bool accept, String? text})>>[];
      two.dialogs = (dialog, gone) {
        final person = Completer<({bool accept, String? text})>();
        people.add(person);
        return person.future;
      };
      report.answers['dialog'] = {'show': true};
      await two.open(_open(), report.call);
      await two.open({..._open(rid: 5), 'node': 10}, report.call);
      browser.controller.add(const PageDialog(id: 1, kind: DialogKind.alert, message: 'First'));
      second.controller.add(const PageDialog(id: 1, kind: DialogKind.alert, message: 'Second'));
      await _settle();
      expect(people, hasLength(2));
      people[1].complete((accept: true, text: null));
      await _settle();
      expect(second.answered.single.id, 1);
      expect(browser.answered, isEmpty);
      expect(two.showsDialog, isTrue, reason: 'the first still shows');
      people[0].complete((accept: true, text: null));
      await _settle();
      expect(browser.answered.single.id, 1);
      expect(two.showsDialog, isFalse);
    });

    test("SkyStream's dialog hears when its page goes", () async {
      Future<void>? gone;
      final person = Completer<({bool accept, String? text})>();
      pages.dialogs = (dialog, pageGone) {
        gone = pageGone;
        return person.future;
      };
      await pages.open(_open(), report.call);
      report.answers['dialog'] = {'show': true};
      browser.controller.add(const PageDialog(id: 3, kind: DialogKind.alert, message: 'Held'));
      await _settle();
      var heard = false;
      unawaited(gone!.then((_) => heard = true));
      await pages.close(4);
      await _settle();
      expect(heard, isTrue);
      person.complete((accept: false, text: null));
      await _settle();
      expect(browser.answered, isEmpty, reason: 'its page is gone');
    });

    test(
      "closing a page lets go of SkyStream's dialog at once, though an eval ahead of the close waits on it",
      () async {
        // Part 2's review (2a): an eval waits while the page is held in its dialog, and the close waited behind it, so
        // the dialog lingered after its window went (up to 10 s per eval: challenge_browser's limit; here, for ever).
        Future<void>? gone;
        pages.dialogs = (dialog, pageGone) {
          gone = pageGone;
          final person = Completer<({bool accept, String? text})>();
          // As SkyStream's dialog does: it closes itself, cancelled, when its page goes.
          unawaited(pageGone.then((_) => person.isCompleted ? null : person.complete((accept: false, text: null))));
          return person.future;
        };
        await pages.open(_open(), report.call);
        report.answers['dialog'] = {'show': true};
        browser.controller.add(const PageDialog(id: 3, kind: DialogKind.alert, message: 'Held'));
        await _settle();
        browser.held = Completer<void>();
        final evaluated = pages.eval(4, 'document.readyState');
        await _settle();
        var heard = false;
        unawaited(gone!.then((_) => heard = true));
        final closing = pages.close(4);
        // What the page does once it's let go reaches the engine no more: the engine is done with it (a save made with
        // what its dialog answered would otherwise overwrite the player's).
        browser.controller.add(const ScriptMessage('{"cs3-js":1,"name":"Game","method":"saveState","args":[""]}'));
        await _settle();
        expect(heard, isTrue, reason: 'the dialog closes when its window goes');
        await closing.timeout(const Duration(seconds: 1));
        expect(await evaluated, '"done"', reason: 'the eval ran once its page was let go, before the close');
        expect(browser.answered.single, (id: 3, accept: false, text: null));
        expect(browser.disposed, isTrue);
        expect(report.types, ['dialog']);
      },
    );

    test("a page let go goes on to its next dialog and call: each is answered at once, so the close isn't held", () async {
      // Part 2's follow-ups review: after the let-go the test game goes straight from its alert to its confirm; with no
      // one to answer that, an eval ahead of the close waited (10 s, the eval's limit) and the close behind it.
      pages.dialogs = (dialog, pageGone) {
        final person = Completer<({bool accept, String? text})>();
        unawaited(pageGone.then((_) => person.isCompleted ? null : person.complete((accept: false, text: null))));
        return person.future;
      };
      await pages.open(_open(), report.call);
      final marker = pages.at(2, 9)!.marker;
      report.answers['dialog'] = {'show': true};
      browser.controller.add(const PageDialog(id: 3, kind: DialogKind.alert, message: 'Game ready'));
      await _settle();
      browser.held = Completer<void>();
      // Its alert answered, it opens its confirm; that answered, a call's prompt.
      browser.afterAnswer = (id) {
        if (id == 3) {
          browser.held = Completer<void>();
          browser.controller.add(const PageDialog(id: 4, kind: DialogKind.confirm, message: 'Keep playing?'));
        } else if (id == 4) {
          browser.held = Completer<void>();
          browser.controller.add(PageDialog(id: 5, kind: DialogKind.prompt, message: '${marker}d.7'));
        }
      };
      final evaluated = pages.eval(4, 'document.readyState');
      await _settle();
      final closing = pages.close(4);
      await _settle();
      await closing.timeout(const Duration(seconds: 1));
      expect(await evaluated, '"done"');
      expect(browser.answered, [
        (id: 3, accept: false, text: null),
        (id: 4, accept: false, text: null),
        (id: 5, accept: true, text: '{}'),
      ]);
      expect(report.types, ['dialog'], reason: 'the engine hears nothing of a page it let go');
    });

    test("a page that holds nothing when it's closed closes in turn: a game's last save, posted meanwhile, is kept", () async {
      // Ayu's games save on Back with an eval (autoSave) and close their window a moment later: the save's message can
      // come after the close is asked for, while the eval still runs.
      await pages.open(_open(), report.call);
      final saving = Completer<void>();
      browser.held = saving;
      final evaluated = pages.eval(4, 'autoSave()');
      await _settle();
      final closing = pages.close(4);
      browser.controller.add(
        const ScriptMessage('{"cs3-js":1,"name":"AndroidApp","method":"saveGameState","args":["s"]}'),
      );
      await _settle();
      saving.complete();
      await closing.timeout(const Duration(seconds: 1));
      expect(await evaluated, '"done"');
      expect(report.types, ['message']);
      expect(browser.disposed, isTrue);
    });

    test("closeAll lets go of every page's dialog at once: none waits for another page's close", () async {
      final second = FakePageBrowser();
      final made = [browser, second];
      final two = ExtensionPages(create: () async => made.removeAt(0));
      Future<void>? gone;
      two.dialogs = (dialog, pageGone) {
        gone = pageGone;
        final person = Completer<({bool accept, String? text})>();
        unawaited(pageGone.then((_) => person.isCompleted ? null : person.complete((accept: false, text: null))));
        return person.future;
      };
      report.answers['dialog'] = {'show': true};
      await two.open(_open(), report.call);
      await two.open({..._open(rid: 5), 'node': 10}, report.call);
      // The first page's eval runs a while (it holds nothing); the second page shows SkyStream's dialog.
      final saving = Completer<void>();
      browser.held = saving;
      unawaited(two.eval(4, 'autoSave()'));
      second.controller.add(const PageDialog(id: 1, kind: DialogKind.alert, message: 'Second'));
      await _settle();
      var heard = false;
      unawaited(gone!.then((_) => heard = true));
      final closing = two.closeAll();
      await _settle();
      expect(heard, isTrue, reason: "the second page's dialog closes without waiting for the first page's eval");
      saving.complete();
      await closing.timeout(const Duration(seconds: 1));
      expect(browser.disposed && second.disposed, isTrue);
    });

    test(
      "a dialog waiting for its answer holds none of the page's later events: a navigation meanwhile reports at once",
      () async {
        // Part 2's review (2b): the dialog waited inside the page's event queue, so a document the extension loaded
        // meanwhile was reported only once the dialog was answered. On Android its events come as they happen.
        final chrome = Completer<void>();
        final person = Completer<({bool accept, String? text})>();
        pages.dialogs = (dialog, gone) => person.future;
        await pages.open(_open(), report.call);
        report.answers['dialog'] = {'show': true};
        // The extension's chrome client holds the result a while before it leaves the dialog to the app.
        report.waits['dialog'] = chrome.future;
        browser.controller
          ..add(const PageDialog(id: 3, kind: DialogKind.alert, message: 'Held'))
          ..add(PageStarted(Uri.parse('https://other.test/')));
        await _settle();
        expect(report.types, ['dialog', 'request', 'started'], reason: 'while the chrome client holds it');
        chrome.complete();
        browser.controller.add(PageFinished(Uri.parse('https://other.test/')));
        await _settle();
        expect(report.types.last, 'finished', reason: "while SkyStream's dialog waits for the person");
        expect(pages.showsDialog, isTrue);
        person.complete((accept: true, text: null));
        await _settle();
        expect(browser.answered.single, (id: 3, accept: true, text: null));
      },
    );

    test("a malformed answer from the engine still answers the page: it isn't left held", () async {
      await pages.open(_open(), report.call);
      report.answers['dialog'] = {'accept': true, 'text': 5};
      browser.controller.add(const PageDialog(id: 8, kind: DialogKind.prompt, message: 'Your name?'));
      await _settle();
      expect(browser.answered.single, (id: 8, accept: true, text: null));
    });

    test('with no way to show one, a dialog the client left gets cancel', () async {
      await pages.open(_open(), report.call);
      report.answers['dialog'] = {'show': true};
      browser.controller.add(const PageDialog(id: 6, kind: DialogKind.prompt, message: 'Your name?'));
      await _settle();
      expect(browser.answered.single, (id: 6, accept: false, text: null));
      expect(pages.showsDialog, isFalse);
    });
  });
}
