import 'dart:async';
import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../network/clearance/challenge_triage.dart';
import '../../network/clearance/clearance.dart';
import '../../network/clearance/clearance_broker.dart';
import '../models/nuvio_models.dart';
import 'nuvio_clearance.dart';
import 'nuvio_engine.dart';
import 'nuvio_isolate_pool.dart';
import 'nuvio_tmdb.dart';

part 'nuvio_runtime.g.dart';

@Riverpod(keepAlive: true)
NuvioRuntime nuvioRuntime(Ref ref) {
  final runtime = NuvioRuntime(() => ref.read(effectiveNuvioTmdbKeyProvider));
  ref.onDispose(runtime.dispose);
  return runtime;
}

/// Runs Nuvio scraper plugins.
///
/// Nuvio wraps a scraper in `module/exports`, then calls
/// `getStreams(tmdbId, mediaType, season, episode)` and JSON-serialises the
/// result. SkyStream does the same on QuickJS, behind the environment in
/// [nuvioPolyfillSource]: fetch/XHR, timers, URL, Buffer, TextEncoder,
/// WebCrypto + CryptoJS, localStorage, cheerio and `require`.
///
/// The JavaScript itself runs on [NuvioIsolatePool] worker isolates, so a
/// 1 MB bundle being parsed can't stutter the UI and slow providers can't
/// starve fast ones.
class NuvioRuntime {
  NuvioRuntime(this._tmdbKey, {NuvioIsolatePool? pool})
    : _pool = pool ?? NuvioIsolatePool(broker: _answerWithApp);

  /// Scrapers call TMDB themselves; they get the key from the Nuvio tab.
  final String Function() _tmdbKey;
  final NuvioIsolatePool _pool;

  /// Matches Nuvio's own per-plugin budget. Scrapers chain 3–5 requests
  /// through slow mirrors; anything shorter silently drops working providers.
  static const Duration defaultTimeout = Duration(seconds: 60);

  /// Static gate for things the runtime genuinely cannot do. Kept deliberately
  /// empty: an earlier version rejected any file whose text contained
  /// "WebAssembly", which threw away bundles that merely *mention* it in dead
  /// polyfill branches. Real failures are reported per scraper instead.
  static String? unsupportedReason(String code) => null;

  void dispose() => _pool.dispose();

  static Future<Map<String, Object?>> _answerWithApp(
    Map<dynamic, dynamic> call,
  ) => answerCheck(
    Clearance.instance.isReady ? ClearanceBroker(Clearance.instance) : null,
    call,
  );

  /// The clearances a run starts with, with their check cookies only: a
  /// scraper is third-party code, and a site's other cookies in the app's
  /// browser can be a person's sign-in.
  @visibleForTesting
  static List<Map<String, Object?>> runGrants(Clearance clearance) => [
    for (final live in clearance.liveClearances())
      {
        ...live,
        'cookies': _checkCookies(
          (live['cookies'] as Map? ?? const {}).cast<String, String>(),
        ),
      },
  ];

  /// [grant] as a scraper gets it: its check cookies only.
  static NuvioGrant _scraperGrant(ClearanceGrant grant) => NuvioGrant(
    site: grant.site,
    cookies: _checkCookies(grant.cookies),
    agent: grant.agent,
  );

  static Map<String, String> _checkCookies(Map<String, String> cookies) => {
    for (final cookie in cookies.entries)
      if (isCheckCookie(cookie.key)) cookie.key: cookie.value,
  };

  /// Answers a run's call about a bot check through [broker], as the app
  /// answers CloudStream's engine: `challenged` (a request a site met with a
  /// challenge), `fromPage` (a site that lets only the browser through) and
  /// `solve` (`Cloudflare.solve`). Nothing without the app's clearances.
  @visibleForTesting
  static Future<Map<String, Object?>> answerCheck(
    ClearanceBroker? broker,
    Map<dynamic, dynamic> call,
  ) async {
    if (broker == null) return const {};
    final source = call['source']?.toString();
    final waiting = call['personWaiting'] == true;
    InPageRequest? asked() {
      final request = call['request'];
      if (request is! Map || request['url'] is! String) return null;
      return InPageRequest(
        request['url'] as String,
        method: request['method']?.toString() ?? 'GET',
        headers: {
          if (request['headers'] is Map)
            for (final e in (request['headers'] as Map).entries)
              if (e.value != null) e.key.toString(): e.value.toString(),
        },
        body: request['body']?.toString(),
      );
    }

    Map<String, Object?> page(InPageResponse? response) => response == null
        ? const {}
        : NuvioAnswer(
            response: {
              'status': response.status,
              'url': response.url.toString(),
              'headers': response.headers,
              'body': response.body,
            },
          ).toMap();

    switch (call['op']) {
      case 'challenged':
        final request = asked();
        if (request == null) return const {};
        final answer = await broker.answerChallenge(
          Uri.parse(request.url),
          request,
          source: source,
          personWaiting: waiting,
          retried: call['retried'] == true,
        );
        return switch (answer) {
          SendWithGrant(:final grant) => NuvioAnswer(
            grant: _scraperGrant(grant),
          ).toMap(),
          UsePageResponse(:final response) => page(response),
          KeepChallenge() => const {},
        };
      case 'fromPage':
        final request = asked();
        if (request == null) return const {};
        return page(await broker.sendFromPage(Uri.parse(request.url), request));
      case 'solve':
        final url = Uri.tryParse(call['url']?.toString() ?? '');
        if (url == null || url.host.isEmpty) return const {};
        final grant = await broker.solve(
          url,
          source: source,
          personWaiting: waiting,
        );
        return grant == null
            ? const {}
            : NuvioAnswer(grant: _scraperGrant(grant)).toMap();
    }
    return const {};
  }

  Future<List<NuvioStreamResult>> run({
    required String code,
    required String scraperId,
    required String scraperName,
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
    Map<String, dynamic> settings = const {},
    Duration timeout = defaultTimeout,
    String source = '',
    bool personWaiting = false,
  }) async {
    final raw = await _pool.execute(
      NuvioEngineRequest(
        code: code,
        scraperId: scraperId,
        scraperName: scraperName,
        tmdbId: tmdbId,
        mediaType: mediaType,
        season: season,
        episode: episode,
        settings: settings,
        tmdbKey: _tmdbKey(),
        timeoutMs: timeout.inMilliseconds,
        source: source,
        personWaiting: personWaiting,
        grants: runGrants(Clearance.instance),
      ),
    );

    final decoded = _decode(raw);
    final error = decoded['error'];
    if (error != null) throw NuvioRuntimeException(error.toString());

    final streams = decoded['streams'];
    if (streams is! List) return const [];

    final out = <NuvioStreamResult>[];
    for (final entry in streams) {
      if (entry is! Map) continue;
      final result = NuvioStreamResult.fromJson(
        Map<String, dynamic>.from(entry),
        scraperId: scraperId,
        scraperName: scraperName,
      );
      if (result != null) out.add(result);
    }
    return out;
  }

  /// Runs a scraper's `onSettings()` and returns the form it describes.
  ///
  /// Nuvio plugins ship their own settings UI as JSON (`header`, `info`,
  /// `text`, `select`, `toggle`); several of them (debrid keys, language,
  /// quality caps, proxies) return nothing useful until they are filled in.
  Future<List<NuvioSettingsField>> settingsLayout({
    required String code,
    required String scraperId,
    Map<String, dynamic> settings = const {},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final raw = await _pool.execute(
      NuvioEngineRequest(
        code: code,
        scraperId: scraperId,
        scraperName: scraperId,
        settings: settings,
        tmdbKey: _tmdbKey(),
        timeoutMs: timeout.inMilliseconds,
        mode: 'settings',
        grants: runGrants(Clearance.instance),
      ),
    );
    final decoded = _decode(raw);
    final error = decoded['error'];
    if (error != null) throw NuvioRuntimeException(error.toString());
    return NuvioSettingsField.parseLayout(decoded['layout']);
  }

  Map<String, dynamic> _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (error) {
      if (kDebugMode) debugPrint('[Nuvio] bad worker payload: $error');
      return {'error': 'Plugin returned an unreadable result'};
    }
  }
}

class NuvioRuntimeException implements Exception {
  final String message;
  const NuvioRuntimeException(this.message);
  @override
  String toString() => message;
}
