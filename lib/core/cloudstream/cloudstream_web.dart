import 'package:challenge_browser/challenge_browser.dart';
import 'package:cs3_engine/cs3_engine.dart';

import '../network/clearance/clearance.dart';
import '../network/clearance/clearance_broker.dart';
import '../network/clearance/page_resolver.dart';
import 'extension_ui/extension_pages.dart';

/// What the app says back to the engine: [EngineReplies] in the app, a fake
/// in tests.
abstract interface class WebReplies {
  /// A solve's answer: the clearance, or nothing when the check wasn't
  /// cleared. [earned]: the browser got it in this solve, rather than it being
  /// held from before.
  Future<void> solved(
    int rid, {
    Map<String, String>? cookies,
    String? userAgent,
    bool? earned,
  });

  /// A fetch's or a resolve's answer ([Cs3Engine.webAnswer]).
  Future<void> answer(int rid, [Map<String, Object?> answer]);

  /// A request a resolve's page made. True when the engine is done with it.
  Future<bool> captured(int rid, String url, {String? method});

  Future<void> script(int rid, String result);

  /// What page [rid] did ([Cs3Engine.webPage]), and the engine's answer: an answering call's value, or a page dialog's
  /// answer (Phase 7c); nothing for the rest.
  Future<Map<String, dynamic>> page(int rid, String type, [Map<String, Object?> fields]);
}

/// [WebReplies] to a running engine.
class EngineReplies implements WebReplies {
  EngineReplies(this.engine);

  final Cs3Engine engine;

  @override
  Future<void> solved(
    int rid, {
    Map<String, String>? cookies,
    String? userAgent,
    bool? earned,
  }) => engine.webReply(
    rid,
    cookies: cookies,
    userAgent: userAgent,
    earned: earned,
  );

  @override
  Future<void> answer(int rid, [Map<String, Object?> answer = const {}]) =>
      engine.webAnswer(rid, answer);

  @override
  Future<bool> captured(int rid, String url, {String? method}) =>
      engine.webCaptured(rid, url, method: method);

  @override
  Future<void> script(int rid, String result) => engine.webScript(rid, result);

  @override
  Future<Map<String, dynamic>> page(int rid, String type, [Map<String, Object?> fields = const {}]) =>
      engine.webPage(rid, type, fields);
}

/// Answers the engine's `webRequest` events through the app's browser:
/// - a bot check to clear (`solve`);
/// - a request a site takes only from inside one of its pages (`fetch`);
/// - a page to load hidden while the engine watches its requests (`resolve`:
///   CloudStream's `WebViewResolver` on the JVM);
/// - a page shown in an extension's screen (`page`, `navigate`, `closePage`, `eval`: the JVM engine's web views),
///   through [pages].
class CloudStreamWeb {
  CloudStreamWeb(this.clearance, {required this.personWaiting, required this.source, ExtensionPages? pages})
    : _broker = ClearanceBroker(clearance),
      pages = pages ?? ExtensionPages.shared;

  final Clearance clearance;
  final ClearanceBroker _broker;

  /// Whether a person waits on the engine now, for the check sheet.
  final bool Function() personWaiting;

  /// Which extension a request on [url] is for, as the check it met is filed.
  final String Function(Uri url) source;

  /// The pages extension screens show on the JVM engine.
  final ExtensionPages pages;

  /// Answers [event]. Never throws: an engine that stopped meanwhile goes
  /// unanswered.
  Future<void> answer(WebReplies replies, Map<String, dynamic> event) async {
    final rid = (event['rid'] as num).toInt();
    final url = Uri.tryParse(event['url'] as String? ?? '');
    try {
      switch (event['op']) {
        case 'fetch':
          await _fetch(replies, rid, url, event);
        case 'resolve':
          await _resolve(replies, rid, url, event);
        case 'page':
          await pages.open(event, replies.page);
        case 'navigate':
          await pages.navigate(rid, event['url'] as String? ?? '', _texts(event['headers']), serve: event['serve']);
        case 'closePage':
          await pages.close(rid);
        case 'eval':
          final result = await pages.eval((event['page'] as num).toInt(), event['script'] as String? ?? '');
          await replies.answer(rid, {'result': result});
        default:
          await _solve(replies, rid, url, event['failed'] is Map ? _texts(event['failed']) : null);
      }
    } catch (_) {
      // The engine stopped meanwhile.
    }
  }

  /// The site's clearance, solved in a hidden page (or by a person, when one
  /// waits on a title opening), or none. [failed]: the cookies of the
  /// clearance the engine's request met the check with.
  Future<void> _solve(
    WebReplies replies,
    int rid,
    Uri? url,
    Map<String, String>? failed,
  ) async {
    Map<String, String>? cookies;
    String? agent;
    bool? earned;
    try {
      if (url != null && clearance.isReady) {
        final site = clearance.siteKeys.siteOf(url.host);
        // Reached through a move the app knows (the engine follows them): its row says where from.
        final movedFrom = [
          for (final move in clearance.store.moves.entries)
            if (clearance.siteKeys.siteOf(move.value.host) == site) clearance.siteKeys.siteOf(move.key),
        ].firstOrNull;
        // A fresh clearance its request didn't carry goes back as it is;
        // the one it met the check with doesn't.
        final grant = await _broker.solve(
          url,
          source: source(url),
          personWaiting: personWaiting(),
          movedFrom: movedFrom,
          failed: failed,
        );
        cookies = grant?.cookies;
        agent = grant?.agent;
        earned = grant?.earned;
      }
    } catch (_) {
      // Answered with no clearance: the extension gets the check's response.
    }
    await replies.solved(
      rid,
      cookies: cookies,
      userAgent: agent,
      earned: earned,
    );
  }

  /// Sends the extension's request from inside a page on its site, which
  /// refused it from the engine even with a fresh clearance. Whether the site
  /// lets only the browser through is the engine's to say (its
  /// `siteBrowserOnly` event): it asks a page about a refusal first, and a
  /// site's own refusal meets the page too.
  Future<void> _fetch(
    WebReplies replies,
    int rid,
    Uri? url,
    Map<String, dynamic> event,
  ) async {
    InPageResponse? reply;
    if (url != null && clearance.isReady) {
      reply = await _broker.sendFromPage(
        url,
        InPageRequest(
          url.toString(),
          method: event['method'] as String? ?? 'GET',
          headers: _texts(event['headers']),
          body: event['body'] as String?,
        ),
        markBrowserOnly: false,
      );
    }
    await replies.answer(
      rid,
      reply == null
          ? const {}
          : {
              'status': reply.status,
              'url': reply.url.toString(),
              'headers': reply.headers,
              'body': reply.body,
            },
    );
  }

  /// Loads the page hidden and hands the engine each request it makes, until
  /// the engine has what it needed.
  Future<void> _resolve(
    WebReplies replies,
    int rid,
    Uri? url,
    Map<String, dynamic> event,
  ) async {
    if (url != null && clearance.isReady) {
      await resolvePage(
        clearance.solver,
        url: url,
        headers: _texts(event['headers']),
        script: event['script'] as String?,
        timeout: Duration(
          milliseconds: (event['timeoutMs'] as num?)?.toInt() ?? 60000,
        ),
        onRequest: (request) => replies.captured(
          rid,
          request.url.toString(),
          method: request.method,
        ),
        onScript: (result) => replies.script(rid, result),
      );
    }
    await replies.answer(rid);
  }

  static Map<String, String> _texts(Object? json) => {
    if (json is Map)
      for (final e in json.entries) '${e.key}': '${e.value}',
  };
}
