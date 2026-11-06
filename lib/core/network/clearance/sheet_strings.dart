import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/foundation.dart';

// The check and sign-in sheets are in English whatever the app's language, as
// the pages in them are (`ChallengeBrowser.load`): Cloudflare's checks then
// read and lay out the same on every device, and nothing there needs
// translating (the owner, 2026-10-04).

/// The words of the sheet that shows [site]'s check to a person.
ChallengeSheetStrings checkSheetStrings(String site) => ChallengeSheetStrings(
  note:
      '$site checks that you are a person. Finish the check below; '
      'SkyStream remembers it for a while.',
  retry: 'Retry',
  fullScreen: 'Full screen',
  exitFullScreen: 'Exit full screen',
  close: 'Close',
  done: 'Done',
  verified: 'Verified',
  quiet: "Don't open this automatically",
  help: switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS =>
      'If this shows often, check that Automatic Verification is on: '
          'Settings > your name > Sign-In & Security.',
    TargetPlatform.android => 'Keeping Android System WebView updated helps.',
    _ => null,
  },
);

/// The words of the sheet that shows [provider]'s sign-in page.
ChallengeSheetStrings signInSheetStrings(String provider) =>
    ChallengeSheetStrings(
      note: 'Sign in to $provider to sync what you watch.',
      retry: 'Retry',
      fullScreen: 'Full screen',
      exitFullScreen: 'Exit full screen',
      close: 'Close',
      verified: 'Signed in',
    );
