import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/sheet_strings.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('the check sheet speaks English: it names the site, and lets the '
      'person keep it from opening by itself', () {
    final strings = checkSheetStrings('anime4up.rest');
    expect(
      strings.note,
      startsWith('anime4up.rest checks that you are a person.'),
    );
    expect(
      [strings.retry, strings.fullScreen, strings.exitFullScreen],
      ['Retry', 'Full screen', 'Exit full screen'],
    );
    expect(
      [strings.close, strings.done, strings.verified],
      ['Close', 'Done', 'Verified'],
    );
    expect(strings.quiet, "Don't open this automatically");
  });

  test("its help fits the platform's browser", () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(checkSheetStrings('a.com').help, contains('Android System WebView'));
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(checkSheetStrings('a.com').help, contains('Automatic Verification'));
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(checkSheetStrings('a.com').help, contains('Automatic Verification'));
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(checkSheetStrings('a.com').help, isNull);
  });

  test('the sign-in sheet speaks English, and has no Done: a sign-in '
      'finishes by itself', () {
    final strings = signInSheetStrings('MyAnimeList');
    expect(strings.note, 'Sign in to MyAnimeList to sync what you watch.');
    expect(strings.verified, 'Signed in');
    expect(strings.done, isNull);
    expect(strings.quiet, isNull);
  });
}
