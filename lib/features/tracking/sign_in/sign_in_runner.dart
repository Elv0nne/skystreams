import 'package:flutter/widgets.dart';

import '../../../core/network/clearance/sheet_strings.dart';
import 'embedded_sign_in.dart';

/// Shows a tracker's sign-in page at [authorize] and returns the URL the
/// provider redirected to, or null when the person gave up.
typedef SignInRun = Future<Uri?> Function(Uri authorize, Uri redirect);

/// Runs a tracker's sign-in in SkyStream's own browser, in the check sheet
/// over [context]: the same on every platform (the owner's choice,
/// 2026-10-02).
class SignInRunner {
  SignInRunner(this.context, {required this.provider, required this.tv});

  final BuildContext context;

  /// The tracker's name, for the words around the sign-in.
  final String provider;
  final bool tv;

  Future<Uri?> call(Uri authorize, Uri redirect) {
    return signInEmbedded(
      context,
      authorize: authorize,
      redirect: redirect,
      tv: tv,
      strings: signInSheetStrings(provider),
    );
  }
}
