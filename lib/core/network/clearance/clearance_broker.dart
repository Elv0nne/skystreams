import 'package:challenge_browser/challenge_browser.dart';

import 'clearance.dart';
import 'clearance_solver.dart';

/// A site's clearance, for clients outside the shared HTTP client: its
/// cookies, and the agent they were issued to. [earned]: the browser got it
/// in the solve that answered, or moments before ([ClearanceStore.justSolved]),
/// rather than it being held from before.
typedef ClearanceGrant = ({
  String site,
  Map<String, String> cookies,
  String agent,
  bool earned,
});

/// What to do with a request a site answered with a challenge.
sealed class BrokerAnswer {
  const BrokerAnswer();
}

/// Send it again with [grant].
class SendWithGrant extends BrokerAnswer {
  const SendWithGrant(this.grant);
  final ClearanceGrant grant;
}

/// Answer it with what a page on the site got: the site lets only the browser
/// through.
class UsePageResponse extends BrokerAnswer {
  const UsePageResponse(this.response);
  final InPageResponse response;
}

/// The challenge is the answer: no clearance, or none would help yet.
class KeepChallenge extends BrokerAnswer {
  const KeepChallenge();
}

/// The app's side of a bot check, for engines that send their own requests:
/// CloudStream's (its `webRequest` events) and Nuvio's workers. The shared
/// HTTP client decides the same way for SkyStream's own requests
/// (`ClearanceInterceptor`).
class ClearanceBroker {
  ClearanceBroker(this.clearance);

  final Clearance clearance;

  /// [url]'s clearance: a fresh one as it is, else solved in a hidden page, or
  /// by a person in the check sheet when one waits. The check is filed under
  /// [source], the extension that met it. [failed]: the cookies of the
  /// clearance the request met the check with; when they are the one held,
  /// it has lapsed however fresh, and is solved again, unless it was solved
  /// moments ago ([ClearanceStore.justSolved]): then the check says the site
  /// lets only the browser through. Null when there's none.
  Future<ClearanceGrant?> solve(
    Uri url, {
    String? source,
    bool personWaiting = false,
    String? movedFrom,
    Map<String, String>? failed,
  }) async {
    if (!clearance.isReady) return null;
    final store = clearance.store;
    final site = clearance.siteKeys.siteOf(url.host);
    final justSolved = store.isJustSolved(site);
    final solving =
        !store.isFresh(site) || (_holds(site, failed) && !justSolved);
    if (solving) {
      store.recordCheck(site, url.toString());
      clearance.checks.met(site, source: source, movedFrom: movedFrom);
      await clearance.solver.solve(url, personWaiting: personWaiting);
    }
    return _grantFor(url, earned: solving || justSolved);
  }

  /// Whether [site]'s clearance is the one whose [cookies] met a check.
  bool _holds(String site, Map<String, String>? cookies) {
    final entry = clearance.store[site];
    if (cookies == null || cookies.isEmpty || entry == null) return false;
    return cookies.entries.every(
      (sent) => entry.cookies.any(
        (held) => held.name == sent.key && held.value == sent.value,
      ),
    );
  }

  /// [request] sent from inside a page on [url]'s site, which refused it from
  /// outside the browser even with a fresh clearance. The site is marked
  /// browser-only, so its next requests go there first, unless
  /// [markBrowserOnly] is false: the CloudStream engine asks a page first, and
  /// says itself when the page got past what the site refused.
  Future<InPageResponse?> sendFromPage(
    Uri url,
    InPageRequest request, {
    bool markBrowserOnly = true,
  }) async {
    if (!clearance.isReady) return null;
    if (markBrowserOnly) {
      clearance.store.markBrowserOnly(clearance.siteKeys.siteOf(url.host));
    }
    return clearance.solver.sendFromPage(url, request);
  }

  /// What to do with [request], which [url]'s site answered with a challenge.
  /// [retried]: it had been sent again with a clearance already, and only
  /// that tells a site that lets only the browser through: an engine sends
  /// with the clearances it started with, so a site cleared since may not
  /// have been on the request (the shared client applies the current one, and
  /// reads a challenge right after a solve itself).
  Future<BrokerAnswer> answerChallenge(
    Uri url,
    InPageRequest request, {
    String? source,
    bool personWaiting = false,
    bool retried = false,
  }) async {
    if (!clearance.isReady) return const KeepChallenge();
    final store = clearance.store;
    final solver = clearance.solver;
    final site = clearance.siteKeys.siteOf(url.host);
    clearance.checks.met(site, source: source);
    if (solver.isIneffective(site)) {
      // Solving again wouldn't help yet, which the solver's row says.
      await solver.solve(checkUrlFor(url, request));
      return const KeepChallenge();
    }
    if (retried) {
      // A fresh clearance refused: the site lets only the browser through.
      final response = await sendFromPage(url, request);
      return response == null
          ? const KeepChallenge()
          : UsePageResponse(response);
    }
    store.recordCheck(site, url.toString());
    final outcome = await solver.solve(
      checkUrlFor(url, request),
      personWaiting: personWaiting,
    );
    if (outcome.result != SolveResult.cleared) return const KeepChallenge();
    final grant = _grantFor(url, earned: true);
    return grant == null ? const KeepChallenge() : SendWithGrant(grant);
  }

  /// The page a check on [request] is cleared in: the request's own address
  /// for a page, its site's root for an API call.
  static Uri checkUrlFor(Uri url, InPageRequest request) {
    String? header(String name) => request.headers.entries
        .where((e) => e.key.toLowerCase() == name)
        .firstOrNull
        ?.value;
    final page =
        request.method.toUpperCase() == 'GET' &&
        !(header('accept') ?? '').contains('application/json') &&
        header('x-requested-with') == null;
    return page
        ? url
        : Uri(
            scheme: url.scheme,
            host: url.host,
            port: url.hasPort ? url.port : null,
            path: '/',
          );
  }

  ClearanceGrant? _grantFor(Uri url, {required bool earned}) {
    final found = clearance.forUri(url);
    if (found == null || found.cookies.isEmpty) return null;
    return (
      site: clearance.siteKeys.siteOf(url.host),
      cookies: found.cookies,
      agent: found.agent,
      earned: earned,
    );
  }
}
