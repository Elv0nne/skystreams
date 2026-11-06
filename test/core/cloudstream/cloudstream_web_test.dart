import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_web.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';

import '../network/clearance/fakes.dart';
import 'extension_ui/fake_page_browser.dart';

final _keys = SiteKeys.parse(
  File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
);

class _Replies implements WebReplies {
  final solves = <({int rid, Map<String, String>? cookies, String? agent, bool? earned})>[];
  final pages = <({int rid, String type, Map<String, Object?> fields})>[];
  final answers = <({int rid, Map<String, Object?> answer})>[];
  final reported = <String>[];
  final scripts = <String>[];
  bool Function(String url) doneAt = (_) => false;

  @override
  Future<void> solved(
    int rid, {
    Map<String, String>? cookies,
    String? userAgent,
    bool? earned,
  }) async => solves.add((rid: rid, cookies: cookies, agent: userAgent, earned: earned));

  @override
  Future<void> answer(
    int rid, [
    Map<String, Object?> answer = const {},
  ]) async => answers.add((rid: rid, answer: answer));

  @override
  Future<bool> captured(int rid, String url, {String? method}) async {
    reported.add(url);
    return doneAt(url);
  }

  @override
  Future<Map<String, dynamic>> page(int rid, String type, [Map<String, Object?> fields = const {}]) async {
    pages.add((rid: rid, type: type, fields: fields));
    return const {};
  }

  @override
  Future<void> script(int rid, String result) async => scripts.add(result);
}

/// An engine that has stopped: every answer fails.
class _Gone implements WebReplies {
  @override
  Future<void> solved(
    int rid, {
    Map<String, String>? cookies,
    String? userAgent,
    bool? earned,
  }) => throw StateError('the engine stopped');

  @override
  Future<void> answer(int rid, [Map<String, Object?> answer = const {}]) =>
      throw StateError('the engine stopped');

  @override
  Future<bool> captured(int rid, String url, {String? method}) =>
      throw StateError('the engine stopped');

  @override
  Future<void> script(int rid, String result) =>
      throw StateError('the engine stopped');

  @override
  Future<Map<String, dynamic>> page(int rid, String type, [Map<String, Object?> fields = const {}]) =>
      throw StateError('the engine stopped');
}

void main() {
  late ClearanceStore store;
  late PageFactory pages;
  late _Replies replies;

  CloudStreamWeb web({List<FakePage>? pageList, ExtensionPages? extensionPages}) {
    pages = PageFactory(
      pageList ??
          [
            FakePage(const [Step('Example')]),
          ],
    );
    final solver = ClearanceSolver(
      store: store,
      siteKeys: _keys,
      openPage: pages.call,
      pollEvery: const Duration(milliseconds: 2),
      callLimit: const Duration(milliseconds: 200),
    );
    Clearance.instance.debugUse(store: store, siteKeys: _keys, solver: solver);
    return CloudStreamWeb(
      Clearance.instance,
      personWaiting: () => false,
      source: (_) => 'cs3:k/A',
      pages: extensionPages,
    );
  }

  void cleared(String site) => store.recordSolve(
    site,
    cookies: [
      StoredCookie(name: 'cf_clearance', value: 'ok', domain: '.$site'),
    ],
    agent: 'Browser/1.0',
    url: 'https://$site/',
  );

  setUp(() {
    store = ClearanceStore();
    replies = _Replies();
  });

  tearDown(() => Clearance.instance.solver.dispose());

  test('a solve (the op by default) answers with a fresh clearance, opening no page', () async {
    var now = DateTime(2026, 10, 10, 12);
    store = ClearanceStore(clock: () => now);
    final bridge = web();
    cleared('example.com');
    now = now.add(const Duration(minutes: 2));
    await bridge.answer(replies, {
      'rid': 1,
      'url': 'https://www.example.com/a',
    });
    expect(replies.solves.single.rid, 1);
    expect(replies.solves.single.cookies, {'cf_clearance': 'ok'});
    expect(replies.solves.single.agent, 'Browser/1.0');
    // Held, not earned now: if the check comes back with it, that proves nothing.
    expect(replies.solves.single.earned, isFalse);
    expect(pages.opened, 0);
  });

  test('a solve naming the clearance a check refused solves again, and says the browser earned it', () async {
    var now = DateTime(2026, 10, 10, 12);
    store = ClearanceStore(clock: () => now);
    final bridge = web(
      pageList: [
        FakePage(const [Step.check(), Step('Example', clearance: 'fresh')]),
      ],
    );
    cleared('example.com');
    now = now.add(const Duration(minutes: 16));
    await bridge.answer(replies, {
      'rid': 1,
      'url': 'https://www.example.com/a',
      'failed': {'cf_clearance': 'ok'},
    });
    expect(pages.opened, 1);
    expect(replies.solves.single.cookies, {'cf_clearance': 'fresh'});
    expect(replies.solves.single.earned, isTrue);
  });

  test(
    'a fetch answers with what its page got, and leaves it to the engine to '
    'say the site lets only the browser through',
    () async {
      final page = FakePage(
        const [Step('Example')],
        onFetch: (request) async => InPageResponse(
          status: 200,
          url: Uri.parse('${request.url}?p=1'),
          headers: const {'content-type': 'text/html'},
          body: 'from the page',
        ),
      );
      final bridge = web(pageList: [page]);
      cleared('example.com');
      await bridge.answer(replies, {
        'rid': 2,
        'op': 'fetch',
        'url': 'https://example.com/list',
        'method': 'POST',
        'headers': {
          'Content-Type': 'application/x-www-form-urlencoded',
          'Cookie': 'a=1',
        },
        'body': 'q=naruto',
      });
      expect(replies.answers.single.rid, 2);
      expect(replies.answers.single.answer, {
        'status': 200,
        'url': 'https://example.com/list?p=1',
        'headers': {'content-type': 'text/html'},
        'body': 'from the page',
      });
      // The engine asks a page whether the browser gets past a refusal, and
      // says so when it does (siteBrowserOnly): a site's own refusal, which
      // its page meets too, leaves the site as it was.
      expect(store['example.com']!.browserOnly, isFalse);
      expect(page.fetched.single.method, 'POST');
      expect(page.fetched.single.body, 'q=naruto');
      expect(page.fetched.single.headers, {
        'Content-Type': 'application/x-www-form-urlencoded',
      });
    },
  );

  test('a fetch the page can\'t send is answered with nothing', () async {
    final bridge = web(
      pageList: [
        FakePage(
          const [Step('Example')],
          onFetch: (_) async =>
              throw const InPageFetchException('TypeError: Failed to fetch'),
        ),
      ],
    );
    cleared('example.com');
    await bridge.answer(replies, {
      'rid': 3,
      'op': 'fetch',
      'url': 'https://example.com/a',
    });
    expect(replies.answers.single.answer, isEmpty);
  });

  test('a resolve hands its page\'s requests to the engine until it is done, then ends', () async {
    final page = FakePage(const [Step('Player')]);
    final bridge = web(pageList: [page]);
    replies.doneAt = (url) => url.endsWith('.m3u8');
    final answering = bridge.answer(replies, {
      'rid': 4,
      'op': 'resolve',
      'url': 'https://host.example/embed/1',
      'headers': {'Referer': 'https://site.example/'},
      'script': null,
      'timeoutMs': 5000,
    });
    await pumpEventQueue();
    page.emit(
      CapturedRequest(Uri.parse('https://host.example/app.js'), method: 'GET'),
    );
    page.emit(
      CapturedRequest(
        Uri.parse('https://cdn.example/master.m3u8'),
        method: 'GET',
      ),
    );
    await answering;
    expect(replies.reported, [
      'https://host.example/app.js',
      'https://cdn.example/master.m3u8',
    ]);
    expect(replies.answers.single.rid, 4);
    expect(replies.answers.single.answer, isEmpty);
    expect(page.loadedHeaders, {'Referer': 'https://site.example/'});
    expect(page.disposed, isTrue);
  });

  test(
    'an engine that stopped meanwhile goes unanswered, and nothing throws',
    () async {
      final bridge = web();
      await bridge.answer(_Gone(), {
        'rid': 5,
        'op': 'fetch',
        'url': 'https://example.com/a',
      });
      await bridge.answer(_Gone(), {'rid': 6, 'url': 'https://example.com/a'});
      await bridge.answer(_Gone(), {
        'rid': 7,
        'op': 'resolve',
        'url': 'https://example.com/a',
        'timeoutMs': 100,
      });
    },
  );

  test('a solve on where a site moved says where it moved from', () async {
    final bridge = web();
    store.recordMove('www.old.com', Uri.parse('https://www.example.com'));
    await bridge.answer(replies, {'rid': 9, 'url': 'https://www.example.com/a'});
    expect(Clearance.instance.checks['example.com']!.movedFrom, 'old.com');
  });

  test('a solve the engine asks for is met under the extension the host names', () async {
    final bridge = web();
    await bridge.answer(replies, {'rid': 8, 'url': 'https://www.example.com/a'});
    expect(Clearance.instance.checks['example.com']!.sources, {'cs3:k/A'});
  });

  test("an extension screen's page ops reach its pages, and an eval is answered with the page's result", () async {
    final browser = FakePageBrowser();
    final extensionPages = ExtensionPages(create: () async => browser);
    final cs3 = web(extensionPages: extensionPages);
    await cs3.answer(replies, {
      'event': 'webRequest',
      'op': 'page',
      'rid': 3,
      'session': 1,
      'node': 6,
      'url': 'https://site.test/',
      'headers': const <String, String>{},
      'userAgent': null,
      'interfaces': const <String, List<String>>{},
    });
    expect(extensionPages.at(1, 6)?.rid, 3);
    browser.controller.add(PageFinished(Uri.parse('https://site.test/')));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(replies.pages.single.type, 'finished');
    await cs3.answer(replies, {
      'event': 'webRequest',
      'op': 'navigate',
      'rid': 3,
      'url': 'https://site.test/2',
      'headers': const <String, String>{},
    });
    expect(browser.loads.last.url, 'https://site.test/2');
    await cs3.answer(replies, {'event': 'webRequest', 'op': 'eval', 'rid': 8, 'page': 3, 'script': 'document.title'});
    expect(replies.answers.single.rid, 8);
    expect(replies.answers.single.answer, {'result': '"Sign in"'});
    await cs3.answer(replies, {'event': 'webRequest', 'op': 'closePage', 'rid': 3});
    expect(browser.disposed, isTrue);
    expect(replies.solves, isEmpty, reason: 'no page op is taken for a bot check');
  });

  test("a navigate op's served folder reaches its page", () async {
    final browser = FakePageBrowser();
    final extensionPages = ExtensionPages(create: () async => browser);
    final cs3 = web(extensionPages: extensionPages);
    await cs3.answer(replies, {
      'event': 'webRequest',
      'op': 'page',
      'rid': 3,
      'session': 1,
      'node': 6,
      'url': 'https://site.test/',
    });
    await cs3.answer(replies, {
      'event': 'webRequest',
      'op': 'navigate',
      'rid': 3,
      'url': 'file:///data/files/game/index.html',
      'headers': const <String, String>{},
      'serve': {'name': 'a1', 'folder': '/data/files/game', 'path': 'index.html', 'file': 'file:///data/files/game/'},
    });
    expect(browser.loads.last.url, 'cbfolder://a1/index.html');
  });
}
