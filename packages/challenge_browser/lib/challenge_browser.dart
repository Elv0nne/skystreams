/// One short-lived page in the platform's own browser engine, hidden or shown: for clearing
/// challenges and resolving pages. See [ChallengeBrowser], [ChallengeBrowserView] and
/// [showChallengeSheet].
library;

export 'src/browser.dart'
    show BrowserCapabilities, BrowserCookie, ChallengeBrowser, InPageFetchException, InPageRequest, InPageResponse;
export 'src/events.dart';
export 'src/messages.g.dart' show DialogKind, FocusDirection;
export 'src/sheet.dart' show ChallengeSheetResult, ChallengeSheetStrings, showChallengeSheet;
export 'src/view.dart' show ChallengeBrowserView;
