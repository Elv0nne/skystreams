import 'dart:async';

import 'package:challenge_browser/challenge_browser.dart';

import '../../logger/app_logger.dart';
import 'clearance_solver.dart';

/// Headers a page load doesn't take from the caller: the browser sends its
/// own agent and cookies.
const _ownedByTheBrowser = {'user-agent', 'cookie', 'host', 'content-length'};

/// Loads [url] in a hidden page and hands each request the page makes to
/// [onRequest], in order, until it answers true. The page comes from
/// [solver]'s page budget. It also ends when [timeout] passes (counted from
/// the call, waiting for room included) or the page's renderer ends.
///
/// With [script], the page runs it after each request, one run at a time,
/// and [onScript] gets the result.
///
/// Never throws, and the page always closes. Whoever asked going away (an
/// [onRequest] that throws) ends it too. This is how CloudStream's
/// `WebViewResolver` runs on the JVM; its engine matches the requests.
Future<void> resolvePage(
  ClearanceSolver solver, {
  required Uri url,
  Map<String, String> headers = const {},
  String? script,
  required Duration timeout,
  required Future<bool> Function(CapturedRequest request) onRequest,
  Future<void> Function(String result)? onScript,
}) async {
  final deadline = DateTime.now().add(timeout);
  final CheckPage page;
  try {
    page = await solver.borrowPage();
  } catch (e) {
    talker.debug('[Clearance] no page to resolve $url: $e');
    return;
  }
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  // Each request is handed over once the one before has been answered.
  var reported = Future<void>.value();
  var scripting = false;
  final events = page.events.listen((event) {
    if (event is RendererGone) {
      finish();
      return;
    }
    if (event is! CapturedRequest) return;
    reported = reported.then((_) async {
      if (done.isCompleted) return;
      try {
        if (await onRequest(event)) finish();
      } catch (_) {
        finish();
      }
    });
    if (script == null || onScript == null || scripting) return;
    scripting = true;
    unawaited(() async {
      try {
        final result = await page.evaluate(script);
        if (!done.isCompleted) await onScript(result);
      } catch (_) {
        // Between documents, or the page has closed.
      } finally {
        scripting = false;
      }
    }());
  });
  try {
    // The budget had no room until the deadline had passed.
    if (!DateTime.now().isBefore(deadline)) return;
    await page.setCapture(true);
    await page.load(
      url.toString(),
      headers: {
        for (final e in headers.entries)
          if (!_ownedByTheBrowser.contains(e.key.toLowerCase())) e.key: e.value,
      },
    );
    await done.future.timeout(
      deadline.difference(DateTime.now()),
      onTimeout: () {},
    );
  } catch (e) {
    talker.debug('[Clearance] resolving $url failed: $e');
  } finally {
    finish();
    await events.cancel();
    await page.dispose();
  }
}
