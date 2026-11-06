import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/challenge_triage.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';

void main() {
  group('SiteKeys', () {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );

    test('a site is its registrable domain', () {
      expect(keys.siteOf('www.example.com'), 'example.com');
      expect(keys.siteOf('a.b.example.com'), 'example.com');
      expect(keys.siteOf('example.com'), 'example.com');
      expect(keys.siteOf('cdn.example.co.uk'), 'example.co.uk');
      expect(keys.siteOf('W1.Anime4UP.rest'), 'anime4up.rest');
    });

    test('hosting platforms keep their tenants apart', () {
      expect(keys.siteOf('a.pages.dev'), 'a.pages.dev');
      expect(keys.siteOf('x.a.pages.dev'), 'a.pages.dev');
      expect(keys.siteOf('b.workers.dev'), 'b.workers.dev');
      expect(keys.siteOf('user.github.io'), 'user.github.io');
    });

    test('wildcards and their exceptions', () {
      // *.ck and !www.ck
      expect(keys.siteOf('foo.bar.ck'), 'foo.bar.ck');
      expect(keys.siteOf('www.ck'), 'www.ck');
      expect(keys.siteOf('a.www.ck'), 'www.ck');
    });

    test('addresses and bare names are their own site', () {
      expect(keys.siteOf('127.0.0.1'), '127.0.0.1');
      expect(keys.siteOf('::1'), '::1');
      expect(keys.siteOf('localhost'), 'localhost');
      expect(keys.siteOf('com'), 'com');
    });
  });

  group('triage', () {
    String? Function(String) headers(Map<String, String> map) =>
        (name) => map[name];

    test('cf-mitigated is a challenge, whatever the body', () {
      expect(
        triageHeaders(403, headers({'cf-mitigated': 'challenge'})),
        Triage.challenge,
      );
    });

    test('a Cloudflare 403 without it is decided by the body', () {
      final cf = headers({'server': 'cloudflare'});
      expect(triageHeaders(403, cf), Triage.unsure);
      expect(triageHeaders(503, cf), Triage.unsure);
      expect(triageHeaders(200, cf), Triage.none);
      expect(
        triageBody('<script>window._cf_chl_opt={}</script>'),
        Triage.challenge,
      );
      expect(
        triageBody('<title>Attention Required! | Cloudflare</title>'),
        Triage.block,
      );
      expect(triageBody('{"error":"forbidden"}'), Triage.none);
    });

    test('Cloudflare\'s detection script is in every kind of page', () {
      const script =
          '<script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js">'
          '</script>';
      expect(
        triageBody(
          '<title>Attention Required! | Cloudflare</title>'
          '<div id="cf-error-details"></div>$script',
        ),
        Triage.block,
      );
      expect(triageBody('<title>Site</title>$script'), Triage.none);
      expect(
        triageBody(
          '<title>Just a moment...</title><script src="/cdn-cgi/'
          'challenge-platform/h/b/orchestrate/chl_page/v1"></script>',
        ),
        Triage.challenge,
      );
    });

    test('other servers are left alone, DDoS-Guard aside', () {
      expect(triageHeaders(403, headers({'server': 'nginx'})), Triage.none);
      expect(
        triageHeaders(403, headers({'server': 'ddos-guard'})),
        Triage.unsure,
      );
    });

    test("AWS WAF's and Vercel's challenge headers, whatever the server", () {
      expect(
        triageHeaders(
          202,
          headers({'x-amzn-waf-action': 'challenge', 'server': 'Server'}),
        ),
        Triage.challenge,
      );
      expect(
        triageHeaders(
          429,
          headers({'x-vercel-mitigated': 'challenge', 'server': 'Vercel'}),
        ),
        Triage.challenge,
      );
      expect(triageHeaders(429, headers({'server': 'Vercel'})), Triage.none);
    });

    const anubis =
        '<!doctype html><html lang="en"><head><title>Making sure you&#39;re '
        'not a bot!</title><link rel="stylesheet" '
        'href="/.within.website/x/xess/xess.min.css?cachebuster=v1.27.0">';
    const hostAdmin =
        '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">'
        '<title>Verification...</title></head><body>Checking your browser '
        'before accessing the website...';

    test("a 200 page can be Anubis's check, or HostAdmin's", () {
      expect(
        triagePage(200, headers({'content-type': 'text/html'}), anubis),
        Triage.challenge,
      );
      expect(
        triagePage(
          200,
          headers({
            'content-type': 'text/html; charset=UTF-8',
            'set-cookie': 'ha-waf-ticket=b2f2; Path=/; HttpOnly',
          }),
          hostAdmin,
        ),
        Triage.challenge,
      );
      expect(
        triagePage(200, headers({}), anubis),
        Triage.challenge,
        reason: 'no content type: the markers decide',
      );
    });

    test('a page that only looks like one, or no 200 page, is not a check', () {
      expect(
        triagePage(200, headers({'content-type': 'text/html'}), hostAdmin),
        Triage.none,
        reason: "HostAdmin's title without its cookie",
      );
      expect(
        triagePage(
          200,
          headers({'content-type': 'text/html'}),
          '<title>Email verification</title><p>HostAdmin</p>',
        ),
        Triage.none,
      );
      expect(
        triagePage(
          200,
          headers({'content-type': 'application/json'}),
          '{"a": "/.within.website/"}',
        ),
        Triage.none,
      );
      expect(
        triagePage(403, headers({'content-type': 'text/html'}), anubis),
        Triage.none,
      );
    });

    test('check titles, translated', () {
      expect(checkTitle.hasMatch('Just a moment...'), isTrue);
      expect(checkTitle.hasMatch('Un instant…'), isTrue);
      expect(checkTitle.hasMatch('DDoS-Guard'), isTrue);
      expect(checkTitle.hasMatch('Animes VF et VOSTFR'), isFalse);
    });

    test("each vendor's check, from what a glance reads", () {
      PageGlance glance(
        String title, {
        bool cloudflare = false,
        bool awsWaf = false,
      }) => PageGlance(
        title: title,
        href: 'https://example.com/',
        ready: 'complete',
        cloudflare: cloudflare,
        awsWaf: awsWaf,
      );
      expect(glance('Site', cloudflare: true).vendor, CheckVendor.cloudflare);
      expect(glance('Just a moment...').vendor, CheckVendor.cloudflare);
      expect(glance('Un instant…').vendor, CheckVendor.cloudflare);
      expect(glance('', awsWaf: true).vendor, CheckVendor.awsWaf);
      expect(glance('Vercel Security Checkpoint').vendor, CheckVendor.vercel);
      expect(
        glance("Making sure you're not a bot!").vendor,
        CheckVendor.anubis,
      );
      expect(glance('Проверяем, что вы не бот!').vendor, CheckVendor.anubis);
      expect(glance('Verification...').vendor, CheckVendor.hostAdmin);
      expect(glance('DDoS-Guard').vendor, CheckVendor.ddosGuard);
      expect(glance('Checking your browser...').vendor, CheckVendor.other);
      expect(glance('Animes VF et VOSTFR').vendor, isNull);
      for (final title in [
        'Vercel Security Checkpoint',
        "Making sure you're not a bot!",
        'Verification...',
      ]) {
        expect(glance(title).checking, isTrue, reason: title);
      }
      expect(glance('Animes VF et VOSTFR').checking, isFalse);
    });
  });

  group('ClearanceStore', () {
    late DateTime time;
    late ClearanceStore store;
    const cookie = StoredCookie(
      name: 'cf_clearance',
      value: 'v1',
      domain: '.example.com',
    );

    setUp(() {
      time = DateTime(2026, 10, 1, 12);
      store = ClearanceStore(clock: () => time);
    });

    test('fresh until the lifetime, less a margin', () {
      store.recordSolve(
        'example.com',
        cookies: [cookie],
        agent: 'A',
        url: 'https://example.com/',
      );
      expect(store.isFresh('example.com'), isTrue);
      time = time.add(const Duration(minutes: 27));
      expect(store.isFresh('example.com'), isTrue);
      time = time.add(const Duration(minutes: 2));
      expect(store.isFresh('example.com'), isFalse);
    });

    test('a lapse teaches the lifetime and drops the cookies', () {
      store.recordSolve(
        'example.com',
        cookies: [cookie],
        agent: 'A',
        url: 'https://example.com/',
      );
      time = time.add(const Duration(minutes: 20));
      store.recordAccepted('example.com');
      time = time.add(const Duration(minutes: 41)); // 61 min after the solve
      store.recordCheck('example.com', 'https://example.com/x');
      final entry = store['example.com']!;
      expect(entry.hasClearance, isFalse);
      expect(entry.lifetime, const Duration(minutes: 60));
      expect(entry.lastCheckAt, time);
    });

    test('the shortest lapse wins, never below what was accepted', () {
      expect(
        learnLifetime(known: null, lapsedAfter: const Duration(minutes: 33)),
        const Duration(minutes: 30),
      );
      expect(
        learnLifetime(
          known: const Duration(minutes: 60),
          lapsedAfter: const Duration(minutes: 31),
        ),
        const Duration(minutes: 30),
      );
      expect(
        learnLifetime(
          known: const Duration(minutes: 30),
          lapsedAfter: const Duration(minutes: 90),
        ),
        const Duration(minutes: 30),
      );
      expect(
        learnLifetime(
          known: null,
          lapsedAfter: const Duration(minutes: 33),
          acceptedFor: const Duration(minutes: 44),
        ),
        const Duration(minutes: 44),
      );
      expect(
        learnLifetime(known: null, lapsedAfter: const Duration(minutes: 2)),
        const Duration(minutes: 5),
      );
    });

    test('a learned lifetime decides freshness', () {
      store.recordSolve(
        'example.com',
        cookies: [cookie],
        agent: 'A',
        url: 'https://example.com/',
      );
      time = time.add(const Duration(minutes: 61));
      store.recordCheck('example.com', 'https://example.com/');
      store.recordSolve(
        'example.com',
        cookies: [cookie],
        agent: 'A',
        url: 'https://example.com/',
      );
      time = time.add(const Duration(minutes: 50));
      expect(store.isFresh('example.com'), isTrue);
    });

    test('a solve under another agent drops the old clearances', () {
      store.recordSolve(
        'a.com',
        cookies: [cookie],
        agent: 'Engine/1',
        url: 'https://a.com/',
      );
      store.recordSolve(
        'b.com',
        cookies: [cookie],
        agent: 'Engine/2',
        url: 'https://b.com/',
      );
      expect(store['a.com']!.hasClearance, isFalse);
      expect(store['b.com']!.hasClearance, isTrue);
    });

    test('sites not to ask about by themselves are saved, read back, and '
        'can be asked about again', () async {
      final dir = await Directory.systemTemp.createTemp('clearance');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/clearances.json');
      final first = ClearanceStore(file: file, clock: () => time);
      expect(first.isQuiet('a.com'), isFalse);
      first.setQuiet('a.com', true);
      expect(first.isQuiet('a.com'), isTrue);
      await first.flush();
      final second = ClearanceStore(file: file, clock: () => time);
      await second.load();
      expect(second.isQuiet('a.com'), isTrue);
      second.setQuiet('a.com', false);
      await second.flush();
      final third = ClearanceStore(file: file, clock: () => time);
      await third.load();
      expect(third.isQuiet('a.com'), isFalse);
    });

    test('saved and read back', () async {
      final dir = await Directory.systemTemp.createTemp('clearance');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/clearances.json');
      final first = ClearanceStore(file: file, clock: () => time);
      first.recordSolve(
        'example.com',
        cookies: [cookie],
        agent: 'A',
        url: 'https://example.com/',
      );
      first.markBrowserOnly('example.com');
      first.markNeedsPerson('other.com', 'https://other.com/');
      await first.flush();
      final second = ClearanceStore(file: file, clock: () => time);
      await second.load();
      final entry = second['example.com']!;
      expect(entry.cookies.single.value, 'v1');
      expect(entry.agent, 'A');
      expect(entry.browserOnly, isTrue);
      expect(second.isFresh('example.com'), isTrue);
    });

    test('a needs-a-person mark is not saved', () async {
      final dir = await Directory.systemTemp.createTemp('clearance');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/clearances.json');
      final first = ClearanceStore(file: file, clock: () => time)
        ..markNeedsPerson('a.com', 'https://a.com/');
      await first.flush();
      final second = ClearanceStore(file: file, clock: () => time);
      await second.load();
      expect(second['a.com']?.needsPerson, isFalse);
    });

    // Earlier development builds learned "moves" from any permanent
    // redirect, GitHub's raw host to github.com among them, which broke
    // every download from it. Those aren't read.
    test('moves saved by earlier builds are not read', () async {
      final dir = Directory.systemTemp.createTempSync('clr');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/clearances.json')
        ..writeAsStringSync(
          '{"version": 1, "sites": [], "moves": '
          '{"raw.githubusercontent.com": "https://github.com"}}',
        );
      final store = ClearanceStore(file: file);
      await store.load();
      expect(store.movedTo('raw.githubusercontent.com'), isNull);
    });

    test('moves are saved and read back, and forgotten', () async {
      final dir = Directory.systemTemp.createTempSync('clr');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/clearances.json');
      final first = ClearanceStore(file: file)
        ..recordMove('old.com', Uri.parse('https://www.new.org'));
      await first.flush();
      final second = ClearanceStore(file: file);
      await second.load();
      expect(second.movedTo('old.com'), Uri.parse('https://www.new.org'));
      second.forgetMove('old.com');
      expect(second.movedTo('old.com'), isNull);
    });

    test('cookies match their domain and path', () {
      const site = StoredCookie(name: 'a', value: '1', domain: '.example.com');
      const host = StoredCookie(name: 'b', value: '2', domain: 'example.com');
      const path = StoredCookie(
        name: 'c',
        value: '3',
        domain: '.example.com',
        path: '/api',
      );
      expect(site.matches('cdn.example.com', '/x'), isTrue);
      expect(site.matches('notexample.com', '/'), isFalse);
      expect(host.matches('cdn.example.com', '/'), isFalse);
      expect(path.matches('example.com', '/api/v1'), isTrue);
      expect(path.matches('example.com', '/apix'), isFalse);
    });
  });
}
