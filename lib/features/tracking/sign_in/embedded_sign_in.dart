import 'dart:async';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/widgets.dart';

import 'sign_in_method.dart';

/// Signs in inside SkyStream's own browser, in the check sheet, on every
/// platform. The provider's redirect is stopped before it loads
/// ([ChallengeBrowser.setNavigationStops]) and read from the stop. Returns it,
/// or null when the person closed the sheet.
Future<Uri?> signInEmbedded(
  BuildContext context, {
  required Uri authorize,
  required Uri redirect,
  required bool tv,
  required ChallengeSheetStrings strings,
}) async {
  final browser = await ChallengeBrowser.create();
  final answer = Completer<Uri>();
  final events = browser.events.listen((event) {
    if (event is NavigationStopped &&
        !answer.isCompleted &&
        isRedirectAnswer(event.url, redirect)) {
      answer.complete(event.url);
    }
  });
  try {
    // The provider's own cookies go, so the person picks the account, as the
    // old dialog's purge made them. Other sites' cookies, clearances among
    // them, stay.
    await browser.deleteCookies('${authorize.origin}/');
    await browser.setNavigationStops([stopPrefix(redirect)]);
    await browser.load(authorize.toString());
    if (!context.mounted) return null;
    await showChallengeSheet(
      context,
      browser: browser,
      strings: strings,
      cleared: answer.future,
      tv: tv,
    );
    return answer.isCompleted ? await answer.future : null;
  } finally {
    await events.cancel();
    await browser.dispose();
  }
}

/// The navigation stop for [redirect]: its scheme, host, port and path, with a
/// path after the host always, so `http://localhost/` can't match
/// `http://localhost.example.com/`.
@visibleForTesting
String stopPrefix(Uri redirect) {
  final path = redirect.path.isEmpty ? '/' : redirect.path;
  return '${redirect.scheme}://${redirect.authority}$path';
}
