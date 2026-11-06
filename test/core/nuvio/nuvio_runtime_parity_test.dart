import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/nuvio/data/nuvio_dom.dart';
import 'package:skystream/core/nuvio/data/nuvio_engine.dart';

/// The Nuvio app's plugin runtime is the environment its scrapers are written
/// and tested against. Where SkyStream's runtime answered differently, a
/// scraper that works there quietly returned nothing here - or worse, the
/// wrong episode. Each group below is one such difference, measured by running
/// the same repository through both.
void main() {
  group('selectors cheerio and Nuvio accept', () {
    const html = '''
      <div class="card"><span class="fmt">Movie</span><a href="/m">m</a></div>
      <div class="card"><span class="fmt">Series</span><a href="/s">s</a></div>
      <p><a href="/hub">HubCloud [FSL]</a><a href="/drive">HubDrive</a></p>
      <script>var go = "x?go=abc";</script>
    ''';

    // 4KHDHub finds its search results with `.movie-card-format:contains(..)`
    // and moviesmod / uhdmovies their download scripts with
    // `script:contains(?go=)`. package:html rejects the pseudo-class, and a
    // rejected selector read as "no matches": every card was dropped.
    test(':contains keeps the elements whose text has it', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      final found = dom.query(doc, null, '.fmt:contains("Series")');
      expect(found, hasLength(1));
      expect(dom.textOf(doc, found), 'Series');
    });

    test('in single quotes, bare, and in any case, as Nuvio reads it', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      expect(dom.query(doc, null, "a:contains('HubDrive')"), hasLength(1));
      expect(dom.query(doc, null, 'script:contains(?go=)'), hasLength(1));
      expect(dom.query(doc, null, 'a:contains("hubcloud")'), hasLength(1));
    });

    test('walks the combinators around it', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      final links = dom.query(doc, null, '.card:contains("Series") a');
      expect(links, hasLength(1));
      expect(dom.attr(doc, links.single, 'href'), '/s');
      expect(dom.query(doc, null, 'p > a:contains("Hub")'), hasLength(2));
      expect(dom.query(doc, null, 'a:contains("FSL") + a'), hasLength(1));
    });

    test('within a context, and in document order across a list', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      final cards = dom.query(doc, null, '.card');
      expect(
        dom.query(doc, cards.last, '.fmt:contains("Series")'),
        hasLength(1),
      );
      expect(dom.query(doc, cards.first, '.fmt:contains("Series")'), isEmpty);
      final both = dom.query(doc, null, 'a:contains("Drive"), a:contains("m")');
      expect(
        [for (final id in both) dom.attr(doc, id, 'href')],
        ['/m', '/drive'],
      );
    });

    // HDHub4u finds a movie's stream links with `.page-body > div a`. They sit
    // in a div inside the div under `.page-body`, and package:html settles a
    // descendant step on the nearest ancestor that fits it without trying one
    // further up, so every one of them was missed.
    const nested = '''
      <main class="pb"><div class="h"><div class="hc"><div>
        <h4><a href="/1">1</a></h4>
      </div></div></div></main>
      <section>
        <div class="x"><span class="x"><a href="/2">2</a></span></div>
        <h2 class="t"></h2><h3 class="t"></h3><p>p</p>
      </section>
    ''';

    test('a step tries every ancestor and sibling, not the nearest', () {
      final dom = NuvioDom();
      final doc = dom.load(nested);
      expect(dom.query(doc, null, '.pb > div a'), hasLength(1));
      expect(dom.query(doc, null, 'div.x a'), hasLength(1));
      expect(dom.query(doc, null, 'h2.t ~ p'), hasLength(1));
      final links = dom.query(doc, null, 'a');
      expect(dom.filter(doc, links, '.pb > div a'), hasLength(1));
      expect(dom.filter(doc, links, 'div.x a'), hasLength(1));
    });

    // cheerio's find, like the Jsoup select behind Nuvio's, keeps a selector
    // inside its context: the context itself may take the first step, but an
    // ancestor above it may not.
    test('find keeps a selector inside its context', () {
      final dom = NuvioDom();
      final doc = dom.load(nested);
      String? only(String selector) =>
          dom.query(doc, null, selector).singleOrNull;
      expect(dom.query(doc, only('span'), 'div a'), isEmpty);
      expect(dom.query(doc, only('section > div'), 'div a'), hasLength(1));
      expect(dom.query(doc, only('.hc'), '.pb > div a'), isEmpty);
      expect(dom.query(doc, only('main'), 'main > div a'), hasLength(1));
      final found = dom.query(doc, only('section'), '.x a');
      expect([for (final id in found) dom.attr(doc, id, 'href')], ['/2']);
    });

    test('and narrows a selection through filter', () {
      final dom = NuvioDom();
      final doc = dom.load(html);
      final links = dom.query(doc, null, 'a');
      final kept = dom.filter(doc, links, 'a:contains("Drive")');
      expect([for (final id in kept) dom.attr(doc, id, 'href')], ['/drive']);
    });
  });

  group('the scraper environment', () {
    Future<Map<String, dynamic>> run(String code) async {
      final raw = await NuvioEngine.execute(
        NuvioEngineRequest(
          code: code,
          scraperId: 'parity',
          scraperName: 'Parity',
          tmdbId: '1',
          timeoutMs: 20000,
        ),
      );
      return jsonDecode(raw) as Map<String, dynamic>;
    }

    String nameOf(Map<String, dynamic> result) =>
        ((result['streams'] as List).single as Map)['name'] as String;

    // HDHub4u collects an episode's links by walking the headings after it
    // until the <hr> that closes the episode, checking `.get(0).tagName`.
    // A node that had no tagName never matched "hr", so the first episode
    // took every episode's links - offered as that one episode.
    test('a node from get() has the tag name cheerio gives it', () async {
      final result = await run(r'''
        var cheerio = require('cheerio-without-node-native');
        function getStreams() {
          var $ = cheerio.load('<h3>Episode 1</h3><p><a href="/e1">1</a></p>' +
              '<hr><h3>Episode 2</h3><p><a href="/e2">2</a></p>');
          var links = [];
          var next = $('h3').first().next();
          while (next.length && next.get(0).tagName !== 'hr') {
            next.find('a').each(function (i, a) { links.push($(a).attr('href')); });
            next = next.next();
          }
          var each = [];
          $('p, hr').each(function (i, el) { each.push(el.name + ':' + el.type); });
          return Promise.resolve([{ url: 'https://x/' + links.join(','),
              name: next.get(0).tagName + '|' + each.join(',') + '|' +
                  $('a').get(0).attribs.href }]);
        }
        module.exports = { getStreams: getStreams };
      ''');
      final stream = (result['streams'] as List).single as Map;
      expect(stream['url'], 'https://x//e1');
      expect(stream['name'], 'hr|p:tag,hr:tag,p:tag|/e1');
    });

    // HDHub4u moves a search result onto the site's current domain with
    // `url.hostname = ...` and then fetches `url.toString()`. The setter was
    // lost, so the page came from a domain that no longer resolves, and a
    // query that was only read came back re-encoded.
    test('URL setters change the address as the standard ones do', () async {
      final result = await run(r'''
        function getStreams() {
          var u = new URL('https://new1.old.af/f1-the-movie/?id=a+b/c=');
          var parts = [u.href];
          u.hostname = new URL('https://new6.new.cl/').hostname;
          parts.push(u.toString(), u.origin);
          u.search = '?p=1';
          u.searchParams.set('q', '2');
          parts.push(u.search + ',' + u.searchParams.get('id'));
          u.port = '8080';
          parts.push(u.host);
          u.port = '443';
          parts.push(u.host);
          u.hash = 'top';
          u.pathname = '/a/./b/../c';
          parts.push(u.href);
          parts.push(new URL('../y?z=1', 'https://a.com/b/c/d').href);
          parts.push(new URL('HTTPS://A.COM:443/X').href);
          parts.push(new URL('https://user:pw@a.com/').href);
          parts.push(new URL('\n https://A.com/x \t').href);
          return Promise.resolve([{ url: 'https://x/', name: parts.join('|') }]);
        }
        module.exports = { getStreams: getStreams };
      ''');
      // What Node answers for the same script.
      expect(
        nameOf(result),
        'https://new1.old.af/f1-the-movie/?id=a+b/c=|'
        'https://new6.new.cl/f1-the-movie/?id=a+b/c=|https://new6.new.cl|'
        '?p=1&q=2,null|new6.new.cl:8080|new6.new.cl|'
        'https://new6.new.cl/a/c?p=1&q=2#top|https://a.com/b/y?z=1|'
        'https://a.com/X|https://user:pw@a.com/|https://a.com/x',
      );
    });

    test(':contains works from inside a scraper', () async {
      final result = await run(r'''
        var cheerio = require('cheerio-without-node-native');
        function getStreams() {
          var $ = cheerio.load('<div class="c"><i class="f">Movie</i></div>' +
              '<div class="c"><i class="f">Series</i></div>');
          var cards = $('.c').filter(function (_, el) {
            return $(el).find('.f:contains("Series")').length > 0;
          });
          return Promise.resolve([{ url: 'https://x/', name: 'cards:' + cards.length }]);
        }
        module.exports = { getStreams: getStreams };
      ''');
      expect(nameOf(result), 'cards:1');
    });

    // Nuvio's fetch never rejects: a request that cannot be made resolves as
    // `{ok: false, status: 0}`. Scrapers written against that check `ok` and
    // carry on to their next mirror; here the rejection escaped them and took
    // the whole provider down.
    test('a request that cannot be made resolves as status 0', () async {
      final result = await run(r'''
        function getStreams() {
          return fetch('http://127.0.0.1:1/nope').then(function (r) {
            return [{ url: 'https://x/', name: 'status:' + r.status + ':' + r.ok }];
          });
        }
        module.exports = { getStreams: getStreams };
      ''');
      expect(nameOf(result), 'status:0:false');
    });

    group('against a server', () {
      late HttpServer server;
      late String base;

      setUp(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        base = 'http://127.0.0.1:${server.port}';
        server.listen((request) async {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write('<html><body>Just a moment...</body></html>');
          await request.response.close();
        });
      });
      tearDown(() => server.close(force: true));

      // Nuvio's json() answers null for a body that is not JSON - a
      // Cloudflare page, an error page - and scrapers test for null.
      test('json() of a page that is not JSON is null', () async {
        final result = await run('''
          function getStreams() {
            return fetch('$base/api').then(function (r) { return r.json(); })
                .then(function (data) {
                  return [{ url: 'https://x/', name: 'json:' + data }];
                });
          }
          module.exports = { getStreams: getStreams };
        ''');
        expect(nameOf(result), 'json:null');
      });

      // DVDPlay and MalluMV copy the response headers with
      // `Object.fromEntries(response.headers)`, which needs Headers to be
      // iterable as the Fetch standard's is: it threw "{} is not iterable" and
      // every HubCloud link was lost.
      test(
        'headers and search params iterate as the standard ones do',
        () async {
          final result = await run('''
          function getStreams() {
            return fetch('$base/page').then(function (r) {
              var headers = Object.fromEntries(r.headers);
              var params = Object.fromEntries(new URLSearchParams('a=1&b=2'));
              var pairs = [];
              for (var pair of r.headers) { pairs.push(pair[0]); }
              return [{ url: 'https://x/', name: headers['content-type'] +
                  '|' + params.b + '|' + (pairs.indexOf('content-type') >= 0) }];
            });
          }
          module.exports = { getStreams: getStreams };
        ''');
          expect(nameOf(result), 'text/html; charset=utf-8|2|true');
        },
      );
    });
  });

  group('the plugin HTTP layer', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        switch (request.uri.path) {
          case '/encoding':
            request.response.write(
              request.headers.value('accept-encoding') ?? 'none',
            );
          case '/video':
            request.response.headers.contentType = ContentType(
              'video',
              'x-matroska',
            );
            final chunk = List<int>.filled(1024 * 1024, 65);
            try {
              for (var i = 0; i < 64; i++) {
                request.response.add(chunk);
                await request.response.flush();
              }
            } catch (_) {
              // The client hung up, which is the point.
            }
        }
        try {
          await request.response.close();
        } catch (_) {}
      });
    });
    tearDown(() => server.close(force: true));

    // DVDPlay copies a browser's headers, `br` included, and Cloudflare then
    // answers in Brotli, which dart:io cannot decode: the page reached the
    // scraper as bytes and its search found nothing. Nuvio drops the header.
    test('never asks for an encoding it cannot decode', () async {
      final http = NuvioEngineHttp();
      addTearDown(http.close);
      final result = await http.fetch({
        'url': '$base/encoding',
        'headers': {'Accept-Encoding': 'gzip, deflate, br'},
      });
      expect(result['body'], isNot(contains('br')));
    });

    // A scraper that asks for a video only wants to know it is there. The
    // whole file was read until the 30 second timeout, per link.
    test('stops reading a large body at the cap', () async {
      final http = NuvioEngineHttp();
      addTearDown(http.close);
      final watch = Stopwatch()..start();
      final result = await http.fetch({'url': '$base/video'});
      expect(result['status'], 200);
      expect(
        (result['body'] as String).length,
        lessThanOrEqualTo(NuvioEngineHttp.mediaBodyLimit),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });
}
