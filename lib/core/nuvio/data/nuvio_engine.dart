import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_js_ng/flutter_js.dart';

import '../../network/clearance/challenge_triage.dart';
import 'nuvio_clearance.dart';
import 'nuvio_crypto.dart';
import 'nuvio_dom.dart';
import 'nuvio_polyfill.dart';

/// Everything needed to run one scraper, in a shape that can be sent to
/// another isolate (plain values only).
class NuvioEngineRequest {
  final String code;
  final String scraperId;
  final String scraperName;
  final String tmdbId;
  final String mediaType;
  final int? season;
  final int? episode;
  final Map<String, dynamic> settings;
  final String tmdbKey;
  final int timeoutMs;

  /// `streams` runs `getStreams(...)`, `settings` runs `onSettings()`.
  final String mode;

  /// What a bot check the run meets is filed under (`nuvio:<scraper id>`).
  final String source;

  /// Whether a person waits on the run (the sources dialog), so a check that
  /// wants a click opens the check sheet.
  final bool personWaiting;

  /// The app's live clearances when the run started
  /// (`Clearance.liveClearances`), as plain maps for the worker.
  final List<Map<String, Object?>> grants;

  const NuvioEngineRequest({
    required this.code,
    required this.scraperId,
    required this.scraperName,
    this.tmdbId = '',
    this.mediaType = 'movie',
    this.season,
    this.episode,
    this.settings = const {},
    this.tmdbKey = '',
    this.timeoutMs = 60000,
    this.mode = 'streams',
    this.source = '',
    this.personWaiting = false,
    this.grants = const [],
  });

  Map<String, dynamic> toMap() => {
    'code': code,
    'scraperId': scraperId,
    'scraperName': scraperName,
    'tmdbId': tmdbId,
    'mediaType': mediaType,
    'season': season,
    'episode': episode,
    'settings': settings,
    'tmdbKey': tmdbKey,
    'timeoutMs': timeoutMs,
    'mode': mode,
    'source': source,
    'personWaiting': personWaiting,
    'grants': grants,
  };

  static NuvioEngineRequest fromMap(Map<dynamic, dynamic> map) =>
      NuvioEngineRequest(
        code: map['code']?.toString() ?? '',
        scraperId: map['scraperId']?.toString() ?? '',
        scraperName: map['scraperName']?.toString() ?? '',
        tmdbId: map['tmdbId']?.toString() ?? '',
        mediaType: map['mediaType']?.toString() ?? 'movie',
        season: (map['season'] as num?)?.toInt(),
        episode: (map['episode'] as num?)?.toInt(),
        settings: map['settings'] is Map
            ? Map<String, dynamic>.from(map['settings'] as Map)
            : const {},
        tmdbKey: map['tmdbKey']?.toString() ?? '',
        timeoutMs: (map['timeoutMs'] as num?)?.toInt() ?? 60000,
        mode: map['mode']?.toString() ?? 'streams',
        source: map['source']?.toString() ?? '',
        personWaiting: map['personWaiting'] == true,
        grants: [
          if (map['grants'] is List)
            for (final grant in map['grants'] as List)
              if (grant is Map) Map<String, Object?>.from(grant),
        ],
      );
}

/// Runs one Nuvio plugin on QuickJS and returns the raw JSON document the
/// plugin produced (`{"streams":[…]}`, `{"layout":[…]}` or `{"error":"…"}`).
///
/// Deliberately free of Dio, Riverpod and anything that needs the root
/// isolate: the same code runs on the UI isolate and inside the worker
/// isolates of [NuvioIsolatePool]. HTTP goes through `dart:io`'s HttpClient
/// with a per-run cookie jar, which also isolates each scraper's session.
class NuvioEngine {
  static const int maxResponseChars = 8 * 1024 * 1024;
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// What `Cloudflare.solve` resolves to: the headers a scraper sends with
  /// its retry, or null when the check wasn't cleared.
  static Map<String, String>? cloudflareReply(NuvioGrant? grant) {
    if (grant == null) return null;
    return {
      'Cookie': grant.cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; '),
      'User-Agent': grant.agent,
    };
  }

  /// Executes [request] and returns the JSON document produced by the plugin.
  /// [channel] reaches the main isolate for bot checks; without one, a run
  /// uses the clearances it was handed and nothing more.
  static Future<String> execute(
    NuvioEngineRequest request, {
    void Function(String line)? onLog,
    NuvioClearanceChannel? channel,
  }) async {
    final runtime = getJavascriptRuntime(
      xhr: false,
      extraArgs: {
        'stackSize': 4 * 1024 * 1024,
        // Several of these can be alive at once; 96 MB is far more than any
        // real bundle needs and keeps well clear of the per-process limit.
        'memoryLimit': 96 * 1024 * 1024,
      },
    );

    final completer = Completer<String>();
    final dom = NuvioDom();
    final clock = NuvioRunClock();
    final http = NuvioEngineHttp(
      grants: [for (final grant in request.grants) ?NuvioGrant.fromMap(grant)],
      channel: channel,
      // Settings forms use the clearances there are; they never ask for one.
      mayStart: request.mode == 'streams',
      clock: clock,
    );
    Timer? pump;
    // A response landing after the run finished must never touch a disposed
    // QuickJS context: that is a native use-after-free, not an exception.
    var disposed = false;

    void evalSafe(String script) {
      if (disposed) return;
      try {
        runtime.evaluate(script);
      } catch (error) {
        if (kDebugMode) debugPrint('[Nuvio] eval failed: $error');
      }
    }

    Map<String, dynamic> asMap(dynamic args) => args is Map
        ? Map<String, dynamic>.from(args)
        : jsonDecode(args.toString()) as Map<String, dynamic>;

    List<String> asIds(dynamic raw) => <String>[
      if (raw is List)
        for (final id in raw) id.toString(),
    ];

    try {
      runtime.onMessage('nuvio_result', (dynamic args) {
        if (!completer.isCompleted) {
          completer.complete(args is String ? args : jsonEncode(args));
        }
        return null;
      });

      runtime.onMessage('nuvio_log', (dynamic args) {
        final line = args is String ? args : jsonEncode(args);
        if (onLog != null) {
          onLog(line);
        } else if (kDebugMode) {
          debugPrint('[Nuvio:${request.scraperName}] $line');
        }
        return null;
      });

      runtime.onMessage(
        'nuvio_crypto',
        (dynamic args) => NuvioCrypto.handle(asMap(args)),
      );

      runtime.onMessage(
        'nuvio_dom_load',
        (dynamic args) => dom.load(asMap(args)['html']?.toString() ?? ''),
      );

      runtime.onMessage('nuvio_dom_query', (dynamic args) {
        final data = asMap(args);
        return jsonEncode(
          dom.query(
            data['doc']?.toString() ?? '',
            data['context']?.toString(),
            data['selector']?.toString() ?? '',
          ),
        );
      });

      runtime.onMessage('nuvio_dom_filter', (dynamic args) {
        final data = asMap(args);
        return jsonEncode(
          dom.filter(
            data['doc']?.toString() ?? '',
            asIds(data['nodes']),
            data['selector']?.toString() ?? '',
          ),
        );
      });

      runtime.onMessage('nuvio_dom_relation', (dynamic args) {
        final data = asMap(args);
        return jsonEncode(
          dom.relation(
            data['doc']?.toString() ?? '',
            asIds(data['nodes']),
            data['kind']?.toString() ?? '',
            data['selector']?.toString(),
          ),
        );
      });

      runtime.onMessage('nuvio_dom_describe', (dynamic args) {
        final data = asMap(args);
        return dom.describeBatch(
          data['doc']?.toString() ?? '',
          asIds(data['nodes']),
        );
      });

      runtime.onMessage('nuvio_dom_tag', (dynamic args) {
        final data = asMap(args);
        return jsonEncode(
          dom.tagsOf(data['doc']?.toString() ?? '', asIds(data['nodes'])),
        );
      });

      runtime.onMessage('nuvio_dom_text', (dynamic args) {
        final data = asMap(args);
        return dom.textOf(data['doc']?.toString() ?? '', asIds(data['nodes']));
      });

      runtime.onMessage('nuvio_dom_html', (dynamic args) {
        final data = asMap(args);
        return dom.html(
          data['doc']?.toString() ?? '',
          data['node']?.toString() ?? '',
        );
      });

      runtime.onMessage('nuvio_dom_attr', (dynamic args) {
        final data = asMap(args);
        return dom.attr(
              data['doc']?.toString() ?? '',
              data['node']?.toString() ?? '',
              data['name']?.toString() ?? '',
            ) ??
            '';
      });

      runtime.onMessage('nuvio_fetch', (dynamic args) {
        final data = asMap(args);
        final id = data['id'];
        if (id == null) return null;
        unawaited(
          http.fetch(data).then((payload) {
            if (disposed) return;
            final failure = payload[NuvioEngineHttp.errorKey];
            if (failure != null) {
              evalSafe(
                'globalThis.__nuvio_settle(${jsonEncode(id.toString())}, null, '
                '${jsonEncode(failure.toString())})',
              );
            } else {
              evalSafe(
                'globalThis.__nuvio_settle(${jsonEncode(id.toString())}, '
                '${jsonEncode(payload)}, null)',
              );
            }
          }),
        );
        return null;
      });

      runtime.onMessage('nuvio_cf_solve', (dynamic args) {
        final data = asMap(args);
        final id = data['id'];
        if (id == null) return null;
        unawaited(
          http.solveFor(data['url']?.toString() ?? '').then((grant) {
            if (disposed) return;
            final reply = cloudflareReply(grant);
            evalSafe(
              'globalThis.__nuvio_settle(${jsonEncode(id.toString())}, '
              '${reply == null ? 'null' : jsonEncode(reply)}, '
              '${reply == null ? jsonEncode('Cloudflare check not cleared') : 'null'})',
            );
          }),
        );
        return null;
      });

      // Promise jobs and timers only advance when QuickJS is pumped. Jobs are
      // drained often; timers are checked every ~32 ms, which is plenty for
      // the retry/rate-limit sleeps scrapers use. Timers run on the run's own
      // time ([clock]), which stops while it waits on a bot check.
      var tickCounter = 0;
      pump = Timer.periodic(const Duration(milliseconds: 8), (_) {
        if (disposed) return;
        try {
          runtime.executePendingJob();
          if (++tickCounter % 4 == 0) {
            runtime.evaluate(
              '__nuvio_tick && __nuvio_tick(${clock.running.inMilliseconds});',
            );
          }
        } catch (_) {
          // A scraper throwing inside a microtask is its own problem.
        }
      });

      runtime.evaluate(
        buildNuvioPolyfill(
          scraperIdJson: jsonEncode(request.scraperId),
          settingsJson: jsonEncode(request.settings),
          tmdbKeyJson: jsonEncode(request.tmdbKey),
        ),
      );
      runtime.evaluate(wrapScraper(request.code));
      runtime.evaluate(
        request.mode == 'settings' ? settingsCall : _streamsCall(request),
      );

      // The run's budget counts only its own time: not a check being cleared.
      return await Future.any([
        completer.future,
        clock
            .expires(Duration(milliseconds: request.timeoutMs))
            .then(
              (_) => jsonEncode({
                'error': 'Timed out after ${request.timeoutMs ~/ 1000}s',
              }),
            ),
      ]);
    } finally {
      pump?.cancel();
      disposed = true;
      http.close();
      dom.clear();
      try {
        runtime.dispose();
      } catch (_) {
        // Disposal races with in-flight jobs on some platforms; harmless.
      }
    }
  }

  /// Nuvio wraps every scraper in a CommonJS shell before calling into it.
  static String wrapScraper(String code) =>
      'var module = { exports: {} };\n'
      'var exports = module.exports;\n'
      '(function() {\n$code\n})();';

  static String _streamsCall(NuvioEngineRequest request) {
    final season = request.season?.toString() ?? 'undefined';
    final episode = request.episode?.toString() ?? 'undefined';
    return '''
      (async function () {
        try {
          var getStreams = (module.exports && module.exports.getStreams) ||
              globalThis.getStreams;
          if (!getStreams) {
            __nuvio_result(JSON.stringify({ error: 'getStreams not found' }));
            return;
          }
          var out = await getStreams(${jsonEncode(request.tmdbId)}, ${jsonEncode(request.mediaType)}, $season, $episode);
          __nuvio_result(JSON.stringify({ streams: out || [] }));
        } catch (e) {
          __nuvio_result(JSON.stringify({
            error: (e && e.message) ? e.message : String(e),
          }));
        }
      })();
    ''';
  }

  static const String settingsCall = '''
    (async function () {
      try {
        var onSettings = (module.exports && module.exports.onSettings) ||
            globalThis.onSettings;
        if (typeof onSettings !== 'function') {
          __nuvio_result(JSON.stringify({ layout: [] }));
          return;
        }
        var layout = await onSettings();
        __nuvio_result(JSON.stringify({ layout: layout || [] }));
      } catch (e) {
        __nuvio_result(JSON.stringify({
          error: (e && e.message) ? e.message : String(e),
        }));
      }
    })();
  ''';
}

/// The HTTP side of the plugin environment.
///
/// `dart:io` instead of Dio so it runs in a worker isolate, with cookies kept
/// per scraper run (several providers hand out a session cookie on the first
/// request and expect it back on the next one).
///
/// Bot checks go as for the app's own requests: the live clearances a run is
/// handed ([grants]) go with every request to their sites, and a request a
/// site meets with a challenge asks the main isolate ([channel]), which clears
/// the check in the app's browser. It is sent again once with the clearance,
/// or taken from a page on the site when the site lets only the browser
/// through. A block page is the answer as it is.
@visibleForTesting
class NuvioEngineHttp {
  NuvioEngineHttp({
    List<NuvioGrant> grants = const [],
    NuvioClearanceChannel? channel,
    bool mayStart = true,
    NuvioRunClock? clock,
    Duration maxWait = defaultMaxWait,
  }) : _grants = [...grants],
       _channel = channel,
       _mayStart = mayStart,
       _clock = clock,
       _waitLeft = maxWait;

  /// Most a run waits on the main isolate in all: its clock stops meanwhile,
  /// so a call that never came back would hold the run forever. A person
  /// slower than this still has Verify, and the run again after it.
  static const Duration defaultMaxWait = Duration(minutes: 2);

  final List<NuvioGrant> _grants;
  final NuvioClearanceChannel? _channel;

  /// False in settings runs: they use the clearances there are, and never
  /// ask for one.
  final bool _mayStart;
  final NuvioRunClock? _clock;
  Duration _waitLeft;

  /// A host's challenge being asked about, which other requests to it join.
  final Map<String, Future<NuvioAnswer>> _asking = {};

  /// Hosts that answered with a block page: `Cloudflare.solve` won't ask.
  final Set<String> _blocked = {};

  /// Hosts that refused a request of this run (403, 429, 503, or a check):
  /// the only ones `Cloudflare.solve` asks about, so a scraper reaches the
  /// app's browser for a site that stopped it, not any address it names.
  final Set<String> _refused = {};

  /// Key used to report a failure inside the payload map.
  static const String errorKey = '__nuvioError';

  /// Most of a video, audio or other binary body that is read.
  static const int mediaBodyLimit = 1024 * 1024;

  /// Deliberately has no `badCertificateCallback`: this client replays the
  /// per-host cookie jar upstream and the JSON it fetches decides where the
  /// video lives, so accepting any certificate would let an on-path attacker
  /// harvest the plugin's session and substitute the stream. A handshake Dart
  /// refuses surfaces to the plugin as a normal fetch failure, never as a
  /// throw; see [fetch].
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 15)
    ..autoUncompress = true;

  final Map<String, Map<String, String>> _cookies = {};
  var _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    try {
      _client.close(force: true);
    } catch (_) {
      // Already gone.
    }
  }

  String cookieHeaderFor(Uri uri) {
    final jar = _cookies[uri.host];
    if (jar == null || jar.isEmpty) return '';
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  bool get _canAsk => _channel != null && _mayStart && !_closed;

  /// The grant that covers [host], the most specific first.
  NuvioGrant? _grantFor(String host) {
    NuvioGrant? best;
    for (final grant in _grants) {
      if (grant.covers(host) &&
          (best == null || grant.site.length > best.site.length)) {
        best = grant;
      }
    }
    return best;
  }

  void _addGrant(NuvioGrant grant) {
    _grants
      ..removeWhere((g) => g.site == grant.site)
      ..add(grant);
  }

  /// The Cookie header for [uri]: the scraper's own, else the run's jar, with
  /// [grant]'s clearance cookies merged in and winning.
  String _cookieHeader(
    Uri uri,
    Map<String, String> headers,
    NuvioGrant? grant,
  ) {
    final own = headers.entries
        .where((e) => e.key.toLowerCase() == 'cookie')
        .firstOrNull
        ?.value;
    final cookies = <String, String>{};
    if (own != null) {
      for (final pair in own.split(';')) {
        final at = pair.indexOf('=');
        if (at > 0) {
          cookies[pair.substring(0, at).trim()] = pair.substring(at + 1).trim();
        }
      }
    } else {
      cookies.addAll(_cookies[uri.host] ?? const {});
    }
    if (grant != null) cookies.addAll(grant.cookies);
    return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Asks the main isolate, the run's clock stopped meanwhile, for at most
  /// what is left of the run's wait. [orElse] when it can't answer in time.
  Future<T> _ask<T>(Future<T> Function() call, T orElse) async {
    if (_waitLeft <= Duration.zero) return orElse;
    final waited = Stopwatch()..start();
    _clock?.pause();
    try {
      return await call().timeout(_waitLeft, onTimeout: () => orElse);
    } catch (_) {
      return orElse;
    } finally {
      _clock?.resume();
      _waitLeft -= waited.elapsed;
    }
  }

  /// [request]'s challenge on [host], asked once while others to the host
  /// wait for the same answer. A page's response answers only the request
  /// that asked: the others ask their own page.
  Future<NuvioAnswer> _challenged(
    String host,
    Map<String, dynamic> request,
  ) async {
    final running = _asking[host];
    if (running != null) {
      final shared = await running;
      if (shared.grant == null && shared.response != null) {
        return _ask(() => _channel!.fromPage(request), const NuvioAnswer());
      }
      return NuvioAnswer(grant: shared.grant);
    }
    final call = _ask(
      () => _channel!.challengedRequest(request, retried: false),
      const NuvioAnswer(),
    );
    _asking[host] = call;
    try {
      return await call;
    } finally {
      _asking.remove(host)?.ignore();
    }
  }

  /// `Cloudflare.solve(url)`: [url]'s clearance, asked for if need be. Null
  /// for a host that didn't refuse this run or answered with a block page,
  /// or when the check wasn't cleared.
  Future<NuvioGrant?> solveFor(String url) async {
    final host = Uri.tryParse(url)?.host ?? '';
    if (!_canAsk ||
        host.isEmpty ||
        _blocked.contains(host) ||
        !_refused.any(
          (h) => h == host || h.endsWith('.$host') || host.endsWith('.$h'),
        )) {
      return null;
    }
    final grant = await _ask(() => _channel!.solve(url), null);
    if (grant != null) _addGrant(grant);
    return grant;
  }

  /// What [payload] says about its site's check, noting a host that refused
  /// the request, and one that answered with a block page.
  Triage _triage(Map<String, dynamic> payload) {
    if (payload.containsKey(errorKey)) return Triage.none;
    final status = (payload['status'] as num?)?.toInt() ?? 0;
    final headers = (payload['headers'] as Map?) ?? const {};
    var triage = triageHeaders(
      status,
      (name) => headers[name.toLowerCase()]?.toString(),
    );
    if (triage == Triage.unsure) {
      triage = triageBody(payload['body']?.toString() ?? '');
    } else if (triage == Triage.none && status == 200) {
      // Anubis and HostAdmin answer 200 with their check.
      triage = triagePage(
        status,
        (name) => headers[name.toLowerCase()]?.toString(),
        payload['body']?.toString() ?? '',
      );
    }
    final host = Uri.tryParse(payload['url']?.toString() ?? '')?.host;
    if (host != null && host.isNotEmpty) {
      if (triage == Triage.block) _blocked.add(host);
      if (triage == Triage.challenge ||
          status == 403 ||
          status == 429 ||
          status == 503) {
        _refused.add(host);
      }
    }
    return triage;
  }

  /// A response taken from a page on the site, as a fetch payload.
  static Map<String, dynamic> _pagePayload(Map<String, dynamic> page) {
    final status = (page['status'] as num?)?.toInt() ?? 0;
    return {
      'ok': status >= 200 && status < 300,
      'status': status,
      'statusText': '',
      'url': page['url']?.toString() ?? '',
      'redirected': false,
      'headers': <String, String>{
        for (final e in ((page['headers'] as Map?) ?? const {}).entries)
          e.key.toString().toLowerCase(): e.value.toString(),
      },
      'body': page['body']?.toString() ?? '',
    };
  }

  void _storeCookies(Uri uri, HttpClientResponse response) {
    for (final cookie in response.cookies) {
      if (cookie.name.isEmpty) continue;
      (_cookies[uri.host] ??= {})[cookie.name] = cookie.value;
    }
  }

  /// Performs one plugin request. Never throws: a failure comes back as
  /// `{errorKey: message}` so the JS side can reject its promise.
  Future<Map<String, dynamic>> fetch(Map<String, dynamic> data) async {
    final rawUrl = data['url']?.toString() ?? '';
    final method = (data['method']?.toString() ?? 'GET').toUpperCase();
    final body = data['body']?.toString();
    final follow = data['follow'] != false;
    final headers = <String, String>{};
    final rawHeaders = data['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (key is String && value != null) headers[key] = value.toString();
      });
    }

    Future<Map<String, dynamic>> doFetch({bool persistent = true}) async {
      var uri = Uri.parse(rawUrl);
      var redirects = 0;
      while (true) {
        if (_closed) return {errorKey: 'client closed'};
        final request = await _client.openUrl(method, uri);
        request.followRedirects = false;
        request.persistentConnection = persistent;
        if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
          request.headers.set('user-agent', NuvioEngine.defaultUserAgent);
        }
        if (!headers.keys.any((k) => k.toLowerCase() == 'accept')) {
          request.headers.set('accept', '*/*');
        }
        headers.forEach((key, value) {
          // The client asks for gzip and decodes it itself. A plugin's own
          // Accept-Encoding - usually a browser's, `br` included - gets
          // Brotli back from Cloudflare, which dart:io cannot decode: the page
          // reached the scraper as bytes. Nuvio drops the header too.
          if (key.toLowerCase() == 'accept-encoding') return;
          try {
            request.headers.set(key, value);
          } catch (_) {
            // Some header names are rejected by dart:io; skip them.
          }
        });
        // A cleared site's cookie holds only with the agent it was issued to.
        final grant = _grantFor(uri.host);
        if (grant != null) request.headers.set('user-agent', grant.agent);
        final cookieHeader = _cookieHeader(uri, headers, grant);
        if (cookieHeader.isNotEmpty) {
          request.headers.set('cookie', cookieHeader);
        }
        if (body != null && body.isNotEmpty && method != 'GET') {
          request.add(utf8.encode(body));
        }

        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        _storeCookies(uri, response);

        final location = response.headers.value('location');
        final isRedirect =
            response.statusCode >= 300 &&
            response.statusCode < 400 &&
            location != null;
        if (isRedirect && follow && redirects < 5) {
          redirects++;
          unawaited(response.drain<void>().catchError((_) {}));
          uri = uri.resolve(location);
          continue;
        }

        final text = await _readBody(
          response,
          _isMedia(response.headers.contentType)
              ? mediaBodyLimit
              : NuvioEngine.maxResponseChars,
        );

        final responseHeaders = <String, String>{};
        response.headers.forEach((name, values) {
          if (values.isNotEmpty) {
            responseHeaders[name.toLowerCase()] = values.first;
          }
        });

        return {
          'ok': response.statusCode >= 200 && response.statusCode < 300,
          'status': response.statusCode,
          'statusText': response.reasonPhrase,
          'url': uri.toString(),
          'redirected': redirects > 0,
          'headers': responseHeaders,
          'body': text,
        };
      }
    }

    Future<Map<String, dynamic>> once() async {
      try {
        return await doFetch(persistent: true);
      } on HandshakeException {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return await doFetch(persistent: false);
        } catch (retryError) {
          return {errorKey: retryError.toString()};
        }
      } on SocketException {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return await doFetch(persistent: false);
        } catch (retryError) {
          return {errorKey: retryError.toString()};
        }
      } catch (error) {
        return {errorKey: error.toString()};
      }
    }

    Map<String, dynamic> asked(String url) => {
      'url': url,
      'method': method,
      'headers': headers,
      'body': body,
    };

    // A site that lets only the browser through is asked from its page.
    final start = Uri.tryParse(rawUrl);
    final startGrant = start == null ? null : _grantFor(start.host);
    if (_canAsk && startGrant != null && startGrant.browserOnly) {
      final page = await _ask(
        () => _channel!.fromPage(asked(rawUrl)),
        const NuvioAnswer(),
      );
      if (page.response != null) return _pagePayload(page.response!);
    }

    final first = await once();
    if (_triage(first) != Triage.challenge || !_canAsk) return first;
    final at = first['url']?.toString() ?? rawUrl;
    final answer = await _challenged(Uri.parse(at).host, asked(at));
    if (answer.response != null) return _pagePayload(answer.response!);
    final grant = answer.grant;
    if (grant == null) return first;
    _addGrant(grant);

    final again = await once();
    if (_triage(again) != Triage.challenge || !_canAsk) return again;
    // Refused with a fresh clearance: the site lets only the browser through.
    final atAgain = again['url']?.toString() ?? at;
    final last = await _ask(
      () => _channel!.challengedRequest(asked(atAgain), retried: true),
      const NuvioAnswer(),
    );
    return last.response != null ? _pagePayload(last.response!) : again;
  }

  /// A video, audio or other binary body: a scraper fetching one only wants
  /// to know it is there, and reading it whole cost the full read timeout.
  static bool _isMedia(ContentType? type) {
    if (type == null) return false;
    final primary = type.primaryType.toLowerCase();
    if (primary == 'video' || primary == 'audio') return true;
    final mime = type.mimeType.toLowerCase();
    return mime == 'application/octet-stream' ||
        mime == 'application/x-matroska' ||
        mime == 'application/zip';
  }

  /// At most [limit] bytes of [response], then the connection is dropped
  /// rather than drained - the rest of a 5 GB file is not coming anyway.
  static Future<String> _readBody(
    HttpClientResponse response,
    int limit,
  ) async {
    final bytes = BytesBuilder(copy: false);
    final done = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    subscription = response.listen(
      (chunk) {
        final room = limit - bytes.length;
        if (chunk.length < room) {
          bytes.add(chunk);
          return;
        }
        if (room > 0) bytes.add(chunk.sublist(0, room));
        unawaited(subscription.cancel());
        finish();
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
    await done.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => unawaited(subscription.cancel()),
    );
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
}
