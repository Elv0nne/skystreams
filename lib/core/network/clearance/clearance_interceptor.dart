import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;
import 'dart:typed_data';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:dio/dio.dart';

import '../../logger/app_logger.dart';
import 'challenge_triage.dart';
import 'clearance_solver.dart';
import 'clearance_store.dart';
import 'site_checks.dart';
import 'site_moves.dart';
import 'site_keys.dart';

/// Request `extra` keys the interceptor reads.
abstract final class ClearanceExtra {
  /// False: leave the request alone (it is a solve's own, or a probe).
  static const enabled = 'clearance.enabled';

  /// True: a person waits on this request (a title opening, playback), so a
  /// check that wants a person opens the check sheet.
  static const personWaiting = 'clearance.personWaiting';

  /// Set on the request sent again after a solve.
  static const retried = 'clearance.retried';

  /// Which extension's request this is (`SkyStreamProvider.checkSource`), for
  /// the bot check it may meet.
  static const source = 'clearance.source';

  /// Set on a request sent to where its site moved: the address it had.
  static const movedFrom = 'clearance.movedFrom';
}

/// Sends a request with the plugin's own user agent even to a cleared site.
/// Stripped before sending.
const keepUserAgentHeader = 'X-SkyStream-Keep-User-Agent';

/// Applies sites' clearances to the shared client's requests: plain HTTP
/// first, with the site's cookies and the agent they hold under; a check is
/// solved in a hidden page and the request sent again; a site that still
/// refuses goes browser-only, and its requests go through a page.
class ClearanceInterceptor extends Interceptor {
  ClearanceInterceptor({
    required this.dio,
    required this.store,
    required this.solver,
    required this.siteKeys,
    required this.checks,
  });

  final Dio dio;
  final ClearanceStore store;
  final ClearanceSolver solver;
  final SiteKeys siteKeys;

  /// Where each check met is filed, with the extension that met it.
  final SiteChecks checks;

  /// Bodies read to tell a challenge from a block; bigger ones are neither.
  static const _peekLimit = 512 * 1024;

  /// How much of a 200 HTML answer is read for Anubis' or HostAdmin's check:
  /// their marks are in the page's head.
  static const _pageHead = 16 * 1024;

  /// Whether an answer of [type] may be a check page: one with no type, or HTML.
  static bool _mayBeCheckPage(String? type) =>
      type == null || type.toLowerCase().contains('html');

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final keepAgent =
        _removeHeader(options.headers, keepUserAgentHeader) != null;
    if (options.extra[ClearanceExtra.enabled] == false) {
      return handler.next(options);
    }
    _followMove(options);
    final uri = options.uri;
    final site = siteKeys.siteOf(uri.host);
    final entry = store[site];
    if (entry != null) {
      if (entry.hasClearance) _apply(options, entry, keepAgent: keepAgent);
      if (entry.browserOnly &&
          store.isFresh(site) &&
          !solver.isIneffective(site)) {
        final fromPage = await _sendFromPage(options);
        if (fromPage != null) return handler.resolve(fromPage, true);
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final settled = await _settle(response);
    if (settled == null) return handler.next(response);
    handler.resolve(settled);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final from = err.requestOptions.extra[ClearanceExtra.movedFrom] as String?;
    if (from != null && _unreachable(err)) {
      // The site's new domain stopped answering: its own address says where
      // it is now. Once: the request sent there isn't rewritten again.
      store.forgetMove(Uri.parse(from).host);
      final again = err.requestOptions.copyWith(
        path: from,
        queryParameters: <String, dynamic>{},
      );
      again.extra.remove(ClearanceExtra.movedFrom);
      try {
        return handler.resolve(await dio.fetch<dynamic>(again));
      } on DioException catch (e) {
        return handler.next(e);
      }
    }
    final response = err.response;
    if (err.type != DioExceptionType.badResponse || response == null) {
      return handler.next(err);
    }
    final settled = await _settle(response);
    if (settled == null) return handler.next(err);
    handler.resolve(settled);
  }

  /// What to answer instead of [response]: null to let it through as it is.
  Future<Response<dynamic>?> _settle(Response<dynamic> response) async {
    final options = response.requestOptions;
    if (options.extra[ClearanceExtra.enabled] == false) return null;
    // The site is the one the request ended on, after any redirect.
    final requested = options.uri;
    final uri = response.realUri;
    final site = siteKeys.siteOf(uri.host);
    final moved = movedOrigin(
      requested: requested,
      reached: uri,
      codes: response.redirects.map((r) => r.statusCode),
      keys: siteKeys,
    );
    final from = options.extra[ClearanceExtra.movedFrom] as String?;
    // The address the extension asked for: a request sent where its site
    // moved, and moved on from there, moved for good from that address.
    final original = from == null ? requested : Uri.parse(from);
    final movedFrom = moved != null || from != null
        ? siteKeys.siteOf(original.host)
        : null;
    // Back where the extension asked: the move is no more.
    if (moved != null && siteKeys.siteOf(moved.host) == movedFrom) {
      store.forgetMove(original.host);
    }
    final status = response.statusCode ?? 0;

    var triage = triageHeaders(status, response.headers.value);
    var replacement = response;
    if (triage == Triage.unsure) {
      final peeked = await _peek(response);
      replacement = peeked.response;
      triage = peeked.body == null ? Triage.none : triageBody(peeked.body!);
    } else if (triage == Triage.none &&
        status == 200 &&
        _mayBeCheckPage(response.headers['content-type']?.join(','))) {
      // Anubis and HostAdmin answer 200 with their check: seen only in a body
      // already read, an HTML one, in its head (as the engine reads it). A
      // streamed one is the caller's to read.
      final data = response.data;
      final body = data is String
          ? (data.length > _pageHead ? data.substring(0, _pageHead) : data)
          : data is List<int>
          ? utf8.decode(
              data.length > _pageHead ? data.sublist(0, _pageHead) : data,
              allowMalformed: true,
            )
          : null;
      if (body != null) {
        triage = triagePage(
          status,
          (name) => response.headers[name]?.join('\n'),
          body,
        );
      }
    }
    if (triage != Triage.challenge) {
      if (status < 400) store.recordAccepted(site);
      return identical(replacement, response) ? null : replacement;
    }

    // Read now: whatever happens next, the challenge may be the answer, and
    // a streamed body can be read only once.
    if (identical(replacement, response)) {
      replacement = (await _peek(response)).response;
    }
    // A move is followed only for a site behind a check, where it matters: its
    // clearance is on the new domain. Other hosts send addresses elsewhere for
    // good for their own reasons (GitHub's raw host to github.com).
    if (moved != null && siteKeys.siteOf(moved.host) != movedFrom) {
      store.recordMove(original.host, moved);
    }
    final retried = options.extra[ClearanceExtra.retried] == true;
    // Sent on to another site, whose clearance it didn't carry: it goes there
    // with it, before anything counts as a check.
    if (!retried &&
        siteKeys.siteOf(requested.host) != site &&
        store.isFresh(site)) {
      try {
        return await dio.fetch<dynamic>(_sentOn(options, uri));
      } on DioException catch (e) {
        return e.response ?? replacement;
      }
    }
    checks.met(
      site,
      source: options.extra[ClearanceExtra.source] as String?,
      movedFrom: movedFrom,
    );
    if (solver.isIneffective(site)) {
      // Solving again wouldn't help yet, which the solver's row says.
      await solver.solve(_checkUrl(options, uri));
      return replacement;
    }
    if (retried || store.isJustSolved(site)) {
      // A fresh clearance refused: the site lets only the browser through.
      talker.debug('[Clearance] $site refuses requests outside the browser');
      store.markBrowserOnly(site);
      return await _sendFromPage(options, uri) ?? replacement;
    }

    store.recordCheck(site, uri.toString());
    final outcome = await solver.solve(
      _checkUrl(options, uri),
      personWaiting: options.extra[ClearanceExtra.personWaiting] == true,
    );
    if (outcome.result != SolveResult.cleared) return replacement;

    // Sent where the request ended: a moved site's new domain holds the
    // clearance, and a cookie set for it wouldn't follow a redirect there.
    try {
      return await dio.fetch<dynamic>(_sentOn(options, uri));
    } on DioException catch (e) {
      return e.response ?? replacement;
    }
  }

  /// [options] sent again to [uri], where it ended. Sent on to another site,
  /// it leaves its own cookies behind, as a browser would: the clearance is
  /// all it carries there.
  RequestOptions _sentOn(RequestOptions options, Uri uri) {
    final again = options.copyWith(
      path: uri.toString(),
      queryParameters: <String, dynamic>{},
      headers: {...options.headers},
      extra: {...options.extra, ClearanceExtra.retried: true},
    );
    if (siteKeys.siteOf(options.uri.host) != siteKeys.siteOf(uri.host)) {
      _removeHeader(again.headers, 'cookie');
    }
    return again;
  }

  /// Sends [options] to where its host moved, path and query kept, noting the
  /// address it had. Its cookies were the old site's, and stay behind.
  void _followMove(RequestOptions options) {
    if (options.extra[ClearanceExtra.movedFrom] != null) return;
    final uri = options.uri;
    final to = store.movedTo(uri.host);
    if (to == null) return;
    _removeHeader(options.headers, 'cookie');
    options.extra[ClearanceExtra.movedFrom] = uri.toString();
    options.path = Uri(
      scheme: to.scheme,
      userInfo: uri.userInfo,
      host: to.host,
      port: to.hasPort ? to.port : null,
      path: uri.path,
      query: uri.hasQuery ? uri.query : null,
    ).toString();
    options.queryParameters = <String, dynamic>{};
  }

  /// Whether the host didn't answer at all: no connection, or no TLS
  /// handshake (a parked domain's certificate is another's).
  static bool _unreachable(DioException err) =>
      err.type == DioExceptionType.connectionError ||
      err.type == DioExceptionType.connectionTimeout ||
      err.type == DioExceptionType.badCertificate ||
      err.error is IOException;

  /// The page to clear the check on: the request itself for a page load, the
  /// site's root for anything a browser wouldn't navigate to (a POST, an API).
  Uri _checkUrl(RequestOptions options, Uri uri) {
    final accept = _header(options.headers, 'accept') ?? '';
    final page =
        options.method == 'GET' &&
        !accept.contains('application/json') &&
        _header(options.headers, 'x-requested-with') == null;
    return page
        ? uri
        : Uri(
            scheme: uri.scheme,
            host: uri.host,
            port: uri.hasPort ? uri.port : null,
            path: '/',
          );
  }

  void _apply(
    RequestOptions options,
    SiteClearance entry, {
    required bool keepAgent,
  }) {
    final uri = options.uri;
    final cookies = <String, String>{};
    final existing = _header(options.headers, 'cookie');
    if (existing != null) {
      for (final pair in existing.split(';')) {
        final at = pair.indexOf('=');
        if (at > 0) {
          cookies[pair.substring(0, at).trim()] = pair.substring(at + 1).trim();
        }
      }
    }
    for (final cookie in entry.cookies) {
      if (cookie.matches(uri.host, uri.path)) {
        cookies[cookie.name] = cookie.value;
      }
    }
    _removeHeader(options.headers, 'cookie');
    if (cookies.isNotEmpty) {
      options.headers['Cookie'] = [
        for (final e in cookies.entries) '${e.key}=${e.value}',
      ].join('; ');
    }
    if (!keepAgent) {
      _removeHeader(options.headers, 'user-agent');
      options.headers['User-Agent'] = entry.agent;
    }
  }

  /// Sends [options] from inside a page on its origin, or null when it can't
  /// be (a body that isn't text) or the site refused the page too.
  Future<Response<dynamic>?> _sendFromPage(
    RequestOptions options, [
    Uri? at,
  ]) async {
    final target = at ?? options.uri;
    final body = switch (options.data) {
      null => null,
      final String text => text,
      final Map<String, dynamic> map
          when (options.contentType ?? '').contains('json') =>
        jsonEncode(map),
      final Map<String, dynamic> map => Transformer.urlEncodeMap(map),
      _ => '',
    };
    if (body == '') return null;
    final reply = await solver.sendFromPage(
      target,
      InPageRequest(
        target.toString(),
        method: options.method,
        headers: {
          for (final e in options.headers.entries) e.key: e.value.toString(),
        },
        body: body,
      ),
    );
    return reply == null ? null : _response(options, reply);
  }

  Response<dynamic> _response(RequestOptions options, InPageResponse reply) {
    final headers = Headers.fromMap({
      for (final e in reply.headers.entries) e.key: [e.value],
    });
    final type = reply.headers['content-type'] ?? '';
    final Object? data = switch (options.responseType) {
      ResponseType.stream => ResponseBody.fromString(
        reply.body,
        reply.status,
        headers: headers.map,
      ),
      ResponseType.bytes => utf8.encode(reply.body),
      ResponseType.json when type.contains('json') => _json(reply.body),
      _ => reply.body,
    };
    return Response<dynamic>(
      requestOptions: options,
      statusCode: reply.status,
      data: data,
      headers: headers,
      redirects: const [],
    );
  }

  static Object? _json(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  /// Reads a small body to triage it, and puts it back for the caller.
  Future<({Response<dynamic> response, String? body})> _peek(
    Response<dynamic> response,
  ) async {
    final data = response.data;
    if (data is String) return (response: response, body: data);
    if (data is List<int>) {
      return (
        response: response,
        body: utf8.decode(data, allowMalformed: true),
      );
    }
    if (data is! ResponseBody) return (response: response, body: null);
    final declared = int.tryParse(
      response.headers.value(Headers.contentLengthHeader) ?? '',
    );
    if (declared != null && declared > _peekLimit) {
      return (response: response, body: null);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in data.stream) {
      bytes.add(chunk);
      if (bytes.length > _peekLimit) break;
    }
    final read = bytes.takeBytes();
    final copy = Response<dynamic>(
      requestOptions: response.requestOptions,
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      headers: response.headers,
      isRedirect: response.isRedirect,
      redirects: response.redirects,
      extra: response.extra,
      data: ResponseBody.fromBytes(
        read,
        response.statusCode ?? 0,
        headers: response.headers.map,
        statusMessage: response.statusMessage,
        isRedirect: response.isRedirect,
      ),
    );
    return (response: copy, body: utf8.decode(read, allowMalformed: true));
  }

  static String? _header(Map<String, dynamic> headers, String name) {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == name) return e.value?.toString();
    }
    return null;
  }

  static Object? _removeHeader(Map<String, dynamic> headers, String name) {
    final lower = name.toLowerCase();
    final key = headers.keys.where((k) => k.toLowerCase() == lower).firstOrNull;
    return key == null ? null : headers.remove(key);
  }
}
