## 0.1.1

- `showChallengeSheet` no longer throws when the page doesn't say where it is as the sheet opens (`evaluate`'s timeout, seen on the Android TV emulator, or an answer that can't be read): the address waits for the page's next event.
- `tap(x, y)` taps or clicks a hidden page as a person would (Android, macOS, Windows, Linux). `evaluateIsolated` reads a page from an isolated script world (macOS, iOS, Windows, Linux). `capabilities()` and `engineVersion()` say what a platform offers.
- Hidden pages lay out at 1024×768 CSS pixels everywhere (Windows at any display scale), with Android's text at 100% whatever the system font size; a shown page follows the person's.
- English: Windows and Linux set the whole browser to English, and the sheet is in English whatever the app's language. Android's and Apple's pages keep the device's language: their engines take a language only per request, and a language on the first request alone made Cloudflare check again after every clearance.
- Narrow sheets (phones, the desktop dialog) keep Close and Done in sight and put the other buttons under a menu; the phone sheet is at least 460 dp tall.

## 0.1.0

- First version: one page per `ChallengeBrowser` on Android (System WebView), iOS and macOS (WKWebView), Windows (WebView2) and Linux (WebKitGTK 4.1).
- Cookies with their flags, script evaluation, document-start scripts, script messages, in-page requests, request capture.
- `ChallengeBrowserView`: platform views on Android, iOS and macOS; an overlay on Windows and Linux. Keyboard and D-pad focus move into and out of the page.
- `showChallengeSheet`: bottom sheet, dialog or TV full screen, closing by itself once the check clears.
- `evaluate` gives up after a timeout (10 s by default), and `fetchInPage`'s timeout covers sending its script: an engine can fail to answer at all. Windows turns SmartScreen off on pages.
