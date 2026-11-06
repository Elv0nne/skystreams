import 'dart:async';
import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/page_resolver.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';

import 'fakes.dart';

final _keys = SiteKeys.parse(
  File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
);

ClearanceSolver _solver(PageFactory pages, {int parallel = 3}) =>
    ClearanceSolver(
      store: ClearanceStore(),
      siteKeys: _keys,
      openPage: pages.call,
      parallel: parallel,
      callLimit: const Duration(milliseconds: 200),
    );

CapturedRequest _request(String url) =>
    CapturedRequest(Uri.parse(url), method: 'GET');

void main() {
  test('loads the page with its headers, and hands its requests over in order until one is the answer', () async {
    final page = FakePage(const [Step('Player')]);
    final pages = PageFactory([page]);
    final seen = <String>[];
    final resolving = resolvePage(
      _solver(pages),
      url: Uri.parse('https://host.example/embed/1'),
      headers: const {
        'Referer': 'https://site.example/',
        'User-Agent': 'Engine/9',
        'Cookie': 'a=1',
      },
      timeout: const Duration(seconds: 5),
      onRequest: (request) async {
        seen.add(request.url.path);
        return request.url.path.endsWith('.m3u8');
      },
    );
    await pumpEventQueue();
    expect(page.capturing, isTrue);
    expect(page.loaded, 'https://host.example/embed/1');
    // The browser sends its own agent and cookies.
    expect(page.loadedHeaders, {'Referer': 'https://site.example/'});
    page.emit(_request('https://host.example/player.js'));
    page.emit(_request('https://cdn.example/master.m3u8'));
    page.emit(_request('https://cdn.example/seg-1.ts'));
    await resolving;
    expect(seen, ['/player.js', '/master.m3u8']);
    expect(page.disposed, isTrue);
    expect(pages.open, 0);
  });

  test(
    'a page that never makes the request it waits for closes at the deadline',
    () async {
      final page = FakePage(const [Step('Player')]);
      final pages = PageFactory([page]);
      final watch = Stopwatch()..start();
      await resolvePage(
        _solver(pages),
        url: Uri.parse('https://host.example/'),
        timeout: const Duration(milliseconds: 150),
        onRequest: (_) async => false,
      );
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(140));
      expect(page.disposed, isTrue);
      expect(pages.open, 0);
    },
  );

  test('the script runs after a request, one run at a time, and its results are handed over', () async {
    final run = Completer<String>();
    final page = FakePage(const [
      Step('Player'),
    ], onEvaluate: (_) => run.future);
    final results = <String>[];
    final resolving = resolvePage(
      _solver(PageFactory([page])),
      url: Uri.parse('https://host.example/'),
      script: 'document.title',
      timeout: const Duration(seconds: 5),
      onRequest: (request) async => request.url.path == '/done',
      onScript: (result) async => results.add(result),
    );
    await pumpEventQueue();
    page.emit(_request('https://host.example/a.js'));
    page.emit(_request('https://host.example/b.js'));
    await pumpEventQueue();
    expect(page.evaluated, ['document.title']);
    run.complete('"Player"');
    await pumpEventQueue();
    expect(results, ['"Player"']);
    page.emit(_request('https://host.example/done'));
    await resolving;
    expect(page.evaluated, hasLength(2));
  });

  test('a renderer that ends ends it', () async {
    final page = FakePage(const [Step('Player')]);
    final resolving = resolvePage(
      _solver(PageFactory([page])),
      url: Uri.parse('https://host.example/'),
      timeout: const Duration(seconds: 5),
      onRequest: (_) async => false,
    );
    await pumpEventQueue();
    page.emit(const RendererGone(crashed: true));
    await resolving;
    expect(page.disposed, isTrue);
  });

  test('whoever asked going away ends it', () async {
    final page = FakePage(const [Step('Player')]);
    final resolving = resolvePage(
      _solver(PageFactory([page])),
      url: Uri.parse('https://host.example/'),
      timeout: const Duration(seconds: 5),
      onRequest: (_) async => throw StateError('the engine stopped'),
    );
    await pumpEventQueue();
    page.emit(_request('https://host.example/a.js'));
    await resolving;
    expect(page.disposed, isTrue);
  });

  test('it waits for room in the page budget, and past its deadline gives the page straight back', () async {
    final pages = PageFactory([
      FakePage(const [Step('A')]),
      FakePage(const [Step('B')]),
    ]);
    final solver = _solver(pages, parallel: 1);
    final held = await solver.borrowPage();
    final resolving = resolvePage(
      solver,
      url: Uri.parse('https://host.example/'),
      timeout: const Duration(milliseconds: 100),
      onRequest: (_) async => false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await held.dispose();
    await resolving;
    expect(pages.opened, 2);
    expect(pages.pages[1].loaded, isNull);
    expect(pages.open, 0);
    expect(solver.openPages, 0);
  });
}
