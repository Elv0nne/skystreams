import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/models/extension_repository.dart';
import 'package:skystream/core/extensions/services/repository_service.dart';

/// The web as Dio sees it: [routes] by address, anything else a 404. Records
/// every request.
class _Net implements HttpClientAdapter {
  _Net(this.routes);

  final Map<String, ResponseBody Function()> routes;
  final List<String> requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requested.add(url);
    return routes[url]?.call() ?? ResponseBody.fromString('not found', 404);
  }

  @override
  void close({bool force = false}) {}
}

/// A shortener with SkyStream's `sky-universe` in lower case, and a
/// stranger's bare `Universe` - as cutt.ly has them: its codes are
/// case-sensitive, and anyone can register one. Records every lookup.
class _Shortener extends RepositoryService {
  _Shortener() : super(Dio());

  final List<String> looked = <String>[];

  static const Map<String, String> _codes = {
    'https://cutt.ly/sky-universe': 'https://example.com/universe.json',
    'https://cutt.ly/Universe': 'https://forms.test/a-strangers-form',
  };

  @override
  Future<String?> resolveShortLink(String shortUrl) async {
    looked.add(shortUrl);
    return _codes[shortUrl];
  }
}

/// Adding an extension repository by URL or by shortcode.
///
/// The old resolver understood exactly two things: a full `https://…` URL, or
/// a bare code looked up at `cutt.ly/sky-CODE` that answered with a redirect
/// header. Everything else — a host without a scheme, a code that lives at
/// `cutt.ly/CODE`, a shortener that answers 200 with a meta refresh — failed
/// with "Invalid URL format" or silently resolved to nothing.
void main() {
  late HttpServer server;
  late String base;
  late RepositoryService service;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    service = RepositoryService(Dio());
    server.listen((request) async {
      switch (request.uri.path) {
        case '/redirect':
          request.response
            ..statusCode = 302
            ..headers.set('location', 'https://example.com/repo.json');
        case '/meta':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              '<html><head><meta http-equiv="refresh" '
              'content="0;url=https://example.com/meta.json"></head></html>',
            );
        case '/js':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              "<html><script>window.location = "
              "'https://example.com/js.json';</script></html>",
            );
        case '/dead':
          request.response
            ..statusCode = 302
            ..headers.set('location', 'https://cutt.ly/404');
        case '/relative':
          request.response
            ..statusCode = 302
            ..headers.set('location', '/repo.json');
        case '/meta-relative':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              '<html><head><meta http-equiv="refresh" '
              'content="0;url=/meta.json"></head></html>',
            );
        case '/js-relative':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              "<html><script>window.location = '/js.json';</script></html>",
            );
        case '/plain':
          request.response
            ..statusCode = 302
            ..headers.set('location', 'http://example.com/plain.json');
        case '/scheme':
          request.response
            ..statusCode = 302
            ..headers.set('location', 'javascript:alert(1)');
        case '/empty-location':
          request.response
            ..statusCode = 302
            ..headers.set('location', '');
        case '/hash-location':
          request.response
            ..statusCode = 302
            ..headers.set('location', '#');
        case '/no-host':
          request.response
            ..statusCode = 302
            ..headers.set('location', 'http:foo');
        case '/meta-hash':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write(
              '<html><head><meta http-equiv="refresh" '
              'content="0;url=#"></head></html>',
            );
        case '/js-query':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.html
            ..write("<script>location.href = '?lang=en';</script>");
        case '/plugins.json':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              '[{"packageName":"com.example.alpha","name":"Alpha",'
              '"url":"https://cdn.test/alpha.sky","version":1}]',
            );
        case '/plugins-claiming.json':
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              '[{"packageName":"com.example.alpha","name":"Alpha",'
              '"url":"https://cdn.test/alpha.sky","version":1,'
              '"repositoryUrl":{"a":1}},'
              '{"packageName":"com.example.bravo","name":"Bravo",'
              '"url":"https://cdn.test/bravo.sky","version":1,'
              '"repositoryUrl":"https://evil.test/repo.json"}]',
            );
        case '/missing':
          request.response.statusCode = 404;
        case '/busy':
          request.response.statusCode = 429;
        default:
          request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  group('repository url parsing', () {
    test('keeps a full url as-is', () async {
      expect(
        await service.parseRepoUrl(' https://example.com/repo.json '),
        'https://example.com/repo.json',
      );
    });

    test('adds the scheme to a bare host or path', () async {
      expect(
        await service.parseRepoUrl('raw.githubusercontent.com/u/r/main/x.json'),
        'https://raw.githubusercontent.com/u/r/main/x.json',
      );
      expect(await service.parseRepoUrl('example.com'), 'https://example.com');
    });

    test('accepts a custom scheme share link', () async {
      expect(
        await service.parseRepoUrl('skystream://example.com/repo.json'),
        'https://example.com/repo.json',
      );
    });

    test('an empty value asks for input instead of crashing', () {
      expect(() => service.parseRepoUrl('   '), throwsA(isA<Exception>()));
    });
  });

  group('shortcode resolution', () {
    test('follows a redirect header', () async {
      expect(
        await service.resolveShortLink('$base/redirect'),
        'https://example.com/repo.json',
      );
    });

    test('follows a meta refresh page', () async {
      expect(
        await service.resolveShortLink('$base/meta'),
        'https://example.com/meta.json',
      );
    });

    test('follows a javascript redirect page', () async {
      expect(
        await service.resolveShortLink('$base/js'),
        'https://example.com/js.json',
      );
    });

    test('treats the shortener 404 page as "no such code"', () async {
      expect(await service.resolveShortLink('$base/dead'), isNull);
      expect(await service.resolveShortLink('$base/missing'), isNull);
    });

    test('a shortener turning the lookup away is not "no such code"', () {
      expect(
        service.resolveShortLink('$base/busy'),
        throwsA(isA<DioException>()),
      );
    });

    test('recognises the shortener dead ends', () {
      expect(service.isDeadEnd('https://cutt.ly/404'), isTrue);
      expect(service.isDeadEnd('https://cutt.ly/'), isTrue);
      expect(service.isDeadEnd('https://py.md/404'), isTrue);
      expect(service.isDeadEnd('https://py.md'), isTrue);
      expect(service.isDeadEnd(''), isTrue);
      expect(service.isDeadEnd('https://example.com/x.json'), isFalse);
    });

    test('unescapes html entities in a redirect target', () {
      expect(
        service.unescapeHtml('https://e.com/a.json?x=1&amp;y=2'),
        'https://e.com/a.json?x=1&y=2',
      );
    });
  });

  // Read against the short link that answered, as a browser would, and
  // never left on plain http: a repository's address decides which code the
  // app installs and runs.
  group('a redirect target', () {
    String local(String path) => 'https://127.0.0.1:${server.port}$path';

    test('in a relative Location is read against the short link', () async {
      expect(
        await service.resolveShortLink('$base/relative'),
        local('/repo.json'),
      );
    });

    test('in a relative meta refresh is read the same way', () async {
      expect(
        await service.resolveShortLink('$base/meta-relative'),
        local('/meta.json'),
      );
    });

    test('in a relative javascript redirect is read the same way', () async {
      expect(
        await service.resolveShortLink('$base/js-relative'),
        local('/js.json'),
      );
    });

    test('on plain http is taken over https', () async {
      expect(
        await service.resolveShortLink('$base/plain'),
        'https://example.com/plain.json',
      );
    });

    test('that is not a web address leads nowhere', () async {
      expect(await service.resolveShortLink('$base/scheme'), isNull);
    });

    // Each of these is the short link's own page again, or no address at
    // all: none is where the code leads. An empty Location was a dead end
    // before redirects were read against the short link.
    for (final (path, kind) in <(String, String)>[
      ('/empty-location', 'an empty Location'),
      ('/hash-location', 'a fragment-only Location'),
      ('/meta-hash', 'a fragment-only meta refresh'),
      ('/js-query', 'a query-only javascript redirect'),
      ('/no-host', 'a Location with a scheme and no host'),
    ]) {
      test('in $kind leads nowhere', () async {
        expect(await service.resolveShortLink('$base$path'), isNull);
      });
    }

    test('back at the short link lets the next spelling be tried', () async {
      expect(
        await service.resolveShortcode([
          '$base/hash-location',
          '$base/redirect',
        ]),
        'https://example.com/repo.json',
      );
    });
  });

  // A repository added by its code is kept as the short link the code was
  // found at, so later launches look that one code up - never the case
  // variants a typed code is tried in, which anyone could register later.
  group('a repository found by its code', () {
    late _Net net;
    late RepositoryService web;

    setUp(() {
      net = _Net({
        'https://cutt.ly/sky-abc': () => ResponseBody.fromString(
          '',
          302,
          headers: {
            'location': ['http://repo.test/repo.json'],
          },
        ),
        'https://repo.test/repo.json': () => ResponseBody.fromString(
          jsonEncode({
            'name': 'Repo',
            'packageName': 'repo.test',
            'pluginLists': ['https://repo.test/plugins.json'],
          }),
          200,
        ),
      });
      web = RepositoryService(Dio()..httpClientAdapter = net);
    });

    test('carries the short link it was found at', () async {
      final repo = await web.fetchRepository('Abc');

      expect(repo?.name, 'Repo');
      expect(repo?.shortLink, 'https://cutt.ly/sky-abc');
    });

    test('kept as that short link, loads by following it one hop, the way a '
        'code is followed', () async {
      final repo = await web.fetchRepository('https://cutt.ly/sky-abc');

      expect(repo?.name, 'Repo');
      expect(repo?.url, 'https://cutt.ly/sky-abc');
      expect(repo?.shortLink, isNull);
      // That code alone, and the manifest over https.
      expect(net.requested, <String>[
        'https://cutt.ly/sky-abc',
        'https://repo.test/repo.json',
      ]);
    });
  });

  test('plugins read from a repository carry its address', () async {
    final plugins = await service.getRepoPlugins(
      ExtensionRepository(
        name: 'A',
        url: '$base/repo.json',
        pluginLists: <String>['$base/plugins.json'],
        explicitId: 'repo.a',
      ),
    );

    expect(plugins.single.repositoryUrl, '$base/repo.json');
    expect(plugins.single.repositoryId, 'repo.a');
  });

  // Plugins come from the lists a repository names. A list written into the
  // manifest itself is not read: no repository publishes one - SkyStream's
  // CLI writes pluginLists only - and SkyStream no longer supports them.
  test('a manifest\'s own plugins list is not read', () async {
    final repo = ExtensionRepository.fromJson(<String, dynamic>{
      'name': 'A',
      'packageName': 'repo.a',
      'pluginLists': <String>['$base/plugins.json'],
      'plugins': <Map<String, dynamic>>[
        <String, dynamic>{
          'packageName': 'com.example.inline',
          'name': 'Inline',
          'url': 'https://cdn.test/inline.sky',
          'version': 1,
        },
      ],
    }, '$base/repo.json');

    final plugins = await service.getRepoPlugins(repo);

    expect(plugins.map((plugin) => plugin.packageName), <String>[
      'com.example.alpha',
    ]);
  });

  // Where a plugin comes from is where it was listed, whatever the entry
  // says - and an entry saying something that is not an address does not
  // take the rest of the listing down with it.
  test('a listing entry cannot set the address its plugin carries', () async {
    final plugins = await service.getRepoPlugins(
      ExtensionRepository(
        name: 'A',
        url: '$base/repo.json',
        pluginLists: <String>['$base/plugins-claiming.json'],
        explicitId: 'repo.a',
      ),
    );

    expect(plugins.map((plugin) => plugin.packageName), <String>[
      'com.example.alpha',
      'com.example.bravo',
    ]);
    expect(
      plugins.map((plugin) => plugin.repositoryUrl),
      everyElement('$base/repo.json'),
    );
  });

  // Codes are case-sensitive, and a television keyboard or a phone's may
  // capitalise the first letter: "Universe" found nothing. SkyStream's own
  // codes come first in either case - the bare code as typed is anyone's,
  // and cutt.ly/Universe is a stranger's form.
  group('a shortcode', () {
    test('typed with capitals finds SkyStream\'s code in lower case before '
        'anyone\'s bare one', () async {
      final shortener = _Shortener();

      expect(
        await shortener.parseRepoUrl('Universe'),
        'https://example.com/universe.json',
      );
      expect(shortener.looked, <String>[
        'https://cutt.ly/sky-Universe',
        'https://cutt.ly/sky-universe',
      ]);
    });

    test('is looked up in SkyStream\'s codes, then bare, each as typed and '
        'then in lower case', () async {
      final shortener = _Shortener();

      await expectLater(
        shortener.parseRepoUrl('NoSuch'),
        throwsA(isA<Exception>()),
      );
      expect(shortener.looked, <String>[
        'https://cutt.ly/sky-NoSuch',
        'https://cutt.ly/sky-nosuch',
        'https://cutt.ly/NoSuch',
        'https://cutt.ly/nosuch',
      ]);
    });

    test('typed in lower case is looked up as typed, and only that', () async {
      final shortener = _Shortener();

      await expectLater(
        shortener.parseRepoUrl('nosuchcode'),
        throwsA(isA<Exception>()),
      );
      expect(shortener.looked, <String>[
        'https://cutt.ly/sky-nosuchcode',
        'https://cutt.ly/nosuchcode',
      ]);
    });
  });
}
