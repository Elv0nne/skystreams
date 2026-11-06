import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_broker.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/nuvio/data/nuvio_clearance.dart';
import 'package:skystream/core/nuvio/data/nuvio_runtime.dart';

import '../network/clearance/fakes.dart';

final _keys = SiteKeys.parse(
  File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
);

/// The main isolate answering Nuvio workers' calls through the app's broker.
void main() {
  late ClearanceStore store;

  ClearanceBroker broker(List<FakePage> pages) {
    final solver = ClearanceSolver(
      store: store,
      siteKeys: _keys,
      openPage: PageFactory(pages).call,
      needsPersonAfter: const Duration(milliseconds: 100),
      giveUpAfter: const Duration(milliseconds: 150),
      pollEvery: const Duration(milliseconds: 2),
      callLimit: const Duration(milliseconds: 200),
    );
    Clearance.instance.debugUse(store: store, siteKeys: _keys, solver: solver);
    return ClearanceBroker(Clearance.instance);
  }

  setUp(() => store = ClearanceStore());

  tearDown(() => Clearance.instance.solver.dispose());

  test('a challenged request is solved under its scraper and answered with the grant', () async {
    final b = broker([
      FakePage(const [Step.check(), Step('Example', clearance: 'fresh')]),
    ]);
    final answer = NuvioAnswer.fromMap(
      await NuvioRuntime.answerCheck(b, {
        'op': 'challenged',
        'source': 'nuvio:vixsrc',
        'personWaiting': false,
        'retried': false,
        'request': {
          'url': 'https://www.example.com/movie/1',
          'method': 'GET',
          'headers': {'User-Agent': 'Scraper/1.0'},
          'body': null,
        },
      }),
    );
    expect(answer.grant?.site, 'example.com');
    expect(answer.grant?.cookies, {'cf_clearance': 'fresh'});
    expect(Clearance.instance.checks['example.com']!.sources, {'nuvio:vixsrc'});
  });

  test(
    'a request from the site\'s page is answered with what the page got',
    () async {
      final b = broker([
        FakePage(
          const [Step('Example')],
          onFetch: (request) async => InPageResponse(
            status: 200,
            url: Uri.parse(request.url),
            headers: const {'content-type': 'text/html'},
            body: 'from the page',
          ),
        ),
      ]);
      final answer = NuvioAnswer.fromMap(
        await NuvioRuntime.answerCheck(b, {
          'op': 'fromPage',
          'source': 'nuvio:a',
          'request': {'url': 'https://example.com/list', 'method': 'GET'},
        }),
      );
      expect(answer.response, {
        'status': 200,
        'url': 'https://example.com/list',
        'headers': {'content-type': 'text/html'},
        'body': 'from the page',
      });
    },
  );

  test(
    'Cloudflare.solve is answered with the site\'s clearance, or nothing',
    () async {
      final b = broker([
        FakePage(const [Step.check()]),
      ]);
      final none = NuvioAnswer.fromMap(
        await NuvioRuntime.answerCheck(b, {
          'op': 'solve',
          'source': 'nuvio:a',
          'url': 'https://example.com/',
        }),
      );
      expect(none.grant, isNull);
      store.recordSolve(
        'example.com',
        cookies: [
          const StoredCookie(
            name: 'cf_clearance',
            value: 'ok',
            domain: '.example.com',
          ),
        ],
        agent: 'Browser/1.0',
        url: 'https://example.com/',
      );
      final some = NuvioAnswer.fromMap(
        await NuvioRuntime.answerCheck(b, {
          'op': 'solve',
          'source': 'nuvio:a',
          'url': 'https://example.com/',
        }),
      );
      expect(some.grant?.agent, 'Browser/1.0');
    },
  );

  group(
    'a scraper gets a clearance\'s check cookies, never the site\'s others',
    () {
      const session = StoredCookie(
        name: 'sessionid',
        value: 'signed-in',
        domain: '.example.com',
      );

      test('from Cloudflare.solve', () async {
        final b = broker([
          FakePage(const [Step('Example')]),
        ]);
        store.recordSolve(
          'example.com',
          cookies: const [
            StoredCookie(
              name: 'cf_clearance',
              value: 'ok',
              domain: '.example.com',
            ),
            StoredCookie(name: '__cf_bm', value: 'bm', domain: '.example.com'),
            StoredCookie(name: '__ddg1_', value: 'ddg', domain: '.example.com'),
            session,
          ],
          agent: 'Browser/1.0',
          url: 'https://example.com/',
        );
        final answer = NuvioAnswer.fromMap(
          await NuvioRuntime.answerCheck(b, {
            'op': 'solve',
            'source': 'nuvio:a',
            'url': 'https://example.com/',
          }),
        );
        expect(answer.grant?.cookies, {
          'cf_clearance': 'ok',
          '__cf_bm': 'bm',
          '__ddg1_': 'ddg',
        });
      });

      test('from a challenged request\'s solve', () async {
        final b = broker([
          FakePage(
            const [Step.check(), Step('Example', clearance: 'fresh')],
            alsoHolds: const [session],
          ),
        ]);
        final answer = NuvioAnswer.fromMap(
          await NuvioRuntime.answerCheck(b, {
            'op': 'challenged',
            'source': 'nuvio:a',
            'retried': false,
            'request': {'url': 'https://example.com/movie/1', 'method': 'GET'},
          }),
        );
        expect(answer.grant?.cookies, {'cf_clearance': 'fresh'});
      });

      test('in the clearances a run starts with', () {
        broker(const []);
        store.recordSolve(
          'example.com',
          cookies: const [
            StoredCookie(
              name: 'cf_clearance',
              value: 'ok',
              domain: '.example.com',
            ),
            session,
          ],
          agent: 'Browser/1.0',
          url: 'https://example.com/',
        );
        expect(NuvioRuntime.runGrants(Clearance.instance), [
          {
            'site': 'example.com',
            'cookies': {'cf_clearance': 'ok'},
            'userAgent': 'Browser/1.0',
          },
        ]);
      });
    },
  );

  test('without the app\'s clearances nothing is answered', () async {
    expect(
      await NuvioRuntime.answerCheck(null, {
        'op': 'solve',
        'url': 'https://example.com/',
      }),
      isEmpty,
    );
  });
}
