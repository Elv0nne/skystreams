# challenge_browser

Runs one short-lived page in the platform's own browser engine, hidden or shown, so SkyStream can clear a site's check (Cloudflare and the like) and resolve pages the way a browser would.

| Platform | Engine | Shown as |
|---|---|---|
| Android | System WebView (androidx.webkit) | A platform view (hybrid composition) |
| iOS 15+, macOS 12+ | WKWebView | A platform view |
| Windows 10+ | WebView2 | A child window over the widget |
| Linux | WebKitGTK 4.1 | A `GtkOverlay` child over the widget |

## Use

```dart
final browser = await ChallengeBrowser.create(); // one page, hidden
browser.events.listen(print);                    // started, finished, errors, progress, messages, captures
await browser.load('https://example.com/');
final title = await browser.evaluate('document.title'); // JSON text
final cookies = await browser.cookies('https://example.com/'); // HttpOnly ones too
final reply = await browser.fetchInPage(InPageRequest('https://example.com/api')); // same origin, page's cookies
await browser.setCapture(true);                  // CapturedRequest events; observes only

// When a person has to finish the check:
final result = await showChallengeSheet(
  context,
  browser: browser,
  strings: strings, // the app's words
  cleared: clearanceArrived, // completes when the check clears
  tv: isTv,
);

await browser.dispose(); // as soon as the job is done
```

- **No browser at idle:** a page exists only between `create` and `dispose`. Nothing is pre-warmed or cached.
- **The engine's own user agent,** never overridden. `userAgent` reports it.
- **Nothing is clicked for the person,** and capture never changes a request.

## The check sheet

`showChallengeSheet` takes the shape that suits the screen:

- **Phone:** a bottom sheet (60% of the height, Full screen for all of it).
- **Tablet, desktop:** a 480×560 dialog; Full screen fills the window.
- **TV:** the whole screen, with Retry, Close and Done above the page, a D-pad press away.

It has an address line (lock for https, and the site), one note, a progress bar, the live page, Retry, Full screen, Close and Done. When `cleared` completes it says Verified and closes by itself.

## Keyboard and D-pad

The page counts as one control in Flutter's focus order:

- Tab, Shift+Tab and the arrow keys move into the page, at its first control (its last going backward), and back out at its edges.
- A click in the page brings Flutter's focus along; a click on Flutter content takes the keys back.
- Escape (desktop) and Back (Android, TV) go to Flutter, which closes the sheet.
- On Android TV the remote's OK becomes Space on checkboxes, radio buttons and in frames, where WebView's Enter ticks nothing.

## Setting up an app

- **Linux:** put the `FlView` in a `GtkOverlay` in the runner (`my_application.cc`), and install `libwebkit2gtk-4.1-dev` to build:

  ```c
  GtkWidget* overlay = gtk_overlay_new();
  gtk_widget_show(overlay);
  gtk_container_add(GTK_CONTAINER(overlay), GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), overlay);
  ```

- **Windows:** nothing. The WebView2 SDK is fetched at build time (pinned, hash-checked) and its loader is linked in statically. Windows 11 ships the WebView2 runtime; Windows 10 may need it installed.
- **macOS:** the app needs the `com.apple.security.network.client` entitlement.
- **Android:** `android.permission.INTERNET`.

## The example app

`example/` is a harness and the integration tests' app: a local test site with two origins (cookies, an echo, media requests, and a check whose box sits in a cross-origin frame), buttons for each call, and the sheet.

```sh
cd example
flutter test integration_test/challenge_browser_test.dart -d <device>
```

The desktop runners (macOS, Windows, Linux) have a test-only channel that sends real Tab, Escape, Space and clicks through the windowing system, so the keyboard tests run where no person is typing.

### Checking real sites

`integration_test/live_sites_test.dart` loads a list of sites behind Cloudflare and other bot checks in hidden pages, and prints one `SITE {json}` line per site: whether the check cleared by itself and how fast, the cookies, and how the clearance replays outside the page (with and without it, another agent, another site's clearance). It reaches the internet, so it runs only when asked:

```sh
flutter test integration_test/live_sites_test.dart -d <device> --dart-define=LIVE=true
# your own list, shown instead of hidden:
flutter test integration_test/live_sites_test.dart -d <device> --dart-define=LIVE=true \
  --dart-define=SITES=https://a.example/,https://b.example/ --dart-define=SHOW=true
```

While a check runs, read only the page's title, address and cookies. In testing, a script that looked up the check's own elements (`#challenge-stage`, the `cf-turnstile-response` field) every half second made Cloudflare's check loop: it set `cf_clearance`, reloaded, and challenged again. Reading the title or `window._cf_chl_opt` didn't.

## Regenerating the bindings

```sh
dart run pigeon --input pigeons/messages.dart
```
