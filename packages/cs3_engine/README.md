# cs3_engine

Runs CloudStream extensions (`.cs3` files) in SkyStream on Android, iOS, macOS, Windows and Linux.
The app side (repositories, the CloudStream screen, providers on Home and in search) lives in
`lib/core/cloudstream/` and `lib/features/cloudstream/` of the app.

| Platform | How the engine runs | Extensions run as |
|---|---|---|
| Android | In the app process | DEX, loaded as CloudStream loads it |
| iOS | An embedded OpenJDK Zero VM (no JIT): `ios/Frameworks/OpenJDKRuntime.xcframework` | JVM classes, converted from DEX |
| macOS, Windows, Linux | A `java` process, on the Java runtime the build bundles: the app's child on macOS and Windows, detached on Linux (below) | JVM classes, converted from DEX |

```dart
final engine = await Cs3Engine.start(dataDir: dir.path);
final loaded = await engine.loadPlugin(cs3File.path, url: downloadUrl);   // {providers: [...], extractors: n, notes: {...}}
final results = await engine.search('Internet Archive', 'His Girl Friday', plugin: cs3File.path);
final details = await engine.load('Internet Archive', url, plugin: cs3File.path);
final links = await engine.loadLinks('Internet Archive', data, plugin: cs3File.path);
engine.events.listen((event) { /* {"event": "repositoryAdded", ...} */ });
```

## Layout

| Path | What | Made by |
|---|---|---|
| `lib/` | The Dart API and the desktop transport | - |
| `android/` | The Android plugin; compiles `engine/engine-core`, `engine/ui-core` and `engine/app-shims` in | - |
| `ios/` | The iOS plugin and the embedded VM | `tool/ios/` (the xcframework) |
| `engine/` | The engine (Kotlin, Gradle): `engine-core` (the protocol), `app-shims` (stand-ins for the CloudStream app classes extensions call), `ui-core` (extension screens read as trees, and the person's actions applied to them; Android compiles it in too), `android-stubs` (Android's classes on the JVM: hand-written stand-ins that hold state and call listeners, and the readers for an extension's resources), `framework-gen` (the build step that completes the stand-ins and indexes every other framework class), `engine-jvm` (desktop and iOS: DEX conversion, the stdio server, the JNI entry, the screens' host) | - |
| `engine/test-fixtures/` | SkyStream's test extension, built, and a compact `resources.arsc`, for the engine's own tests; committed | `tool/build_test_extension.sh` |
| `test_extension/` | SkyStream's own test extension: a settings screen with every kind of control, for device tests | `tool/build_test_extension.sh` (into `test_extension/build/`, not committed) |
| `assets/engine/` | The engine's jars for desktop and iOS, committed | `tool/build_engine.sh` |
| `assets/runtime/` | The desktop Java runtime, not committed | `tool/build_runtime.dart` |
| `m2/` | CloudStream's library (Android and JVM variants), committed | `tool/build_cloudstream_library.sh` |

See [BUILD_INSTRUCTIONS.md](BUILD_INSTRUCTIONS.md) for when and how to rebuild each.

## How it works

- **One protocol everywhere:** a JSON request in, a JSON response out (`hello`, `loadPlugin`,
  `unloadPlugin`, `providers`, `mainPage`, `search`, `load`, `loadLinks`, `setRepositories`,
  `setClearances`, and the browser's answers `webReply`, `webCaptured`, `webScript` and `webPage`;
  see `engine/engine-core/.../Engine.kt`). Events go the other way, unprompted: desktop writes them
  to stdout as lines without a request id, Android sends them over the method channel, and on iOS
  the VM calls a native `EmbeddedEntry.emit`.
- **On Linux the engine runs detached,** not as the app's child. While Dart waits on a child it
  started, it collects any child of the app that ends, and libVLC waits forever for a helper it
  runs before each connection (libproxy's `proxy`) once something else collected it, which froze
  the player. A detached engine has no exit code, so its output closing is its end.
- **Sites that move.** `setClearances` also carries the app's moves (`{host: origin}`): requests to
  a moved host go straight to where it went, and other hosts of its site stay where they are. When
  a request reaches another host through permanent redirects that keep its path and query, and
  meets a bot check there, the engine reports `siteMoved`, from the address the extension asked for, and the app decides with
  its site list whether that is a move. A moved host whose new domain doesn't answer is dropped
  (`siteMoveDropped`), and the request goes to the extension's address. A check is solved where
  the request ended, not where it started.
- **Repositories belong to the app.** It hands the engine its list (`setRepositories`), which
  extensions read through CloudStream's `RepositoryManager`, and hears of each one an extension adds
  (`repositoryAdded`). That is how MegaRepo works: its plugin has no provider and adds every
  repository in CloudStream's community list when it loads.
- **The app's browser, for extensions.** Extensions reach it through the engine for three things:
  - a bot check to clear (`solve`), naming the clearance the request met it with (`failed`), which
    the app doesn't hand back; the answer says whether the browser earned its clearance in that
    solve (`earned`), and a held one that meets the check again is named in a second solve;
  - a request a site takes only from inside one of its pages (`fetch`). A site that refuses a
    clearance the browser just earned lets only the browser through (behind `CloudflareKiller`, a
    403 with none of a check's marks counts only when the site's page gets past it): its later
    requests go to its pages first, and the engine reports `siteBrowserOnly`, which the app keeps;
  - a page for CloudStream's `WebViewResolver` to load hidden (`resolve`). Each request the page
    makes comes back to the engine, which matches it with the extension's own patterns.

  CloudStream's library is built with one patch for that (`tool/patches/`), on every platform:
  Android's pages go through the app's browser too, its page budget and its handling of a
  renderer that ends.
- **Extensions' own screens** (settings, and the dialogs they open) are drawn by the app, in its
  sheet:
  - **The protocol:**
    - requests: `openSettings`, `uiAction`, `closeUi`, `reloadPlugin` and `setLanguage`;
    - events: `ui` (a screen's windows, as trees), `uiClosed` and `restartRequested`, and on the
      desktops and iOS also `toast`, `copy` and `openUrl`.

    `engine/ui-core` reads a window's views into a tree, and applies the person's taps, ticks,
    typing, choices and slides to them.
  - **Android** shows the extension's real views, invisible and untouchable: a window hook hides each
    window an open screen's extension adds, before it exists. Android resolves an extension layout's
    references through the app's resources, as CloudStream does, so two things are put right: words left
    as raw references ("@2130968613") are read from the extension's own resources, and its views keep the
    ids its layouts give them, through a factory the host activity installs on its inflater
    (`ExtensionLayoutIds`). Without it, an id that lands on an app resource pointing elsewhere takes that
    resource's id, and the extension's `findViewById` misses the view.
  - **The desktops and iOS** run the same extension code against the stand-ins in
    `engine/android-stubs`, which hold state and call listeners; nothing is measured or drawn.
    - At build time, `framework-gen` gives them every public and protected method of the real classes
      (android.jar API 36, and the AndroidX and Material versions the Android app uses) as no-ops that
      never cover a hand-written one, nor one the JDK class under a stand-in has, and checks them against
      Android.
    - An extension's strings and layouts come from its `resources.arsc` and compiled XML: night
      values first, and the app's language where the extension ships it. A layout's attributes are
      set in the stand-ins' constructors, each class its own, as Android's are, so an extension's own
      view sees them in its init.
    - The host reads a changed screen after each task on the engine's main thread, at most every
      50 ms.
  - **Restarts become reloads.** An extension's restart throws before it happens, and the app reloads
    the extension instead. That covers a restart through the activity or the application context,
    and an exit: on the desktops and iOS the converter rewrites `System.exit`, `Runtime.exit`/`halt`,
    `Process.killProcess` and `exitProcess`.
  - **Unloads end screens.** An extension unloaded with its screen open (an update installed, a utility
    plugin run again at launch) has the screen ended first, with `uiClosed` reason `unloaded`, and its
    windows closed before its code goes.
  - **Pop-ups never show over the app.** A window an extension shows with no screen of its open is sorted
    by the spec's rules (engine-core's `ExtensionUi`; the hosts apply them):
    - while the person waits on the extension (its `load` or `loadLinks`, and 5 s after), it opens in
      SkyStream's sheet as a screen of its own (`uiOpened`; kept instead while another screen is open),
      and nothing reloads after. While it's open, calls' clocks stand still, as for the check sheet (5
      minutes at most);
    - in the background, one with a page in it is parked and sorted again 5 s later: dismissed as if closed
      (`popupDropped`) while a call of its extension still runs (the call waits on it: SkyStream's own bot
      checks cover the site), else kept as a promotion, as below;
    - anything else is kept out of sight (`popupKept`, and `popups` with the titles), at most 3 per
      extension, newest first, the same words replacing the older one. The extension's row shows Support,
      which opens them live (`openPopups`). They go when it unloads.
    - On Android a window is hidden as it's added, before it exists, and a kept one's root is GONE, so it
      has no drawing surface while it waits; one added off the main thread shows as Android draws it, and
      is reported (`popupEscaped`).
  - **Pages:** on Android an extension's own WebView is lent to the sheet (platform view `cs3_engine/page`)
    and goes back to its window after; on the JVM engine (desktop, iOS) its stand-in WebView asks the app for a
    page (`webRequest` op `page`), which the app opens in its own browser engine with the extension's user
    agent and shows at the node, and the page's events come back as `webPage`. A WebView no open screen holds
    loads nothing.
- **Conversion (desktop and iOS):** dex2jar (ThexXTURBOXx's maintained fork) turns DEX into JVM
  classes once per plugin file, cached by hash in `<dataDir>/converted`. Methods convert on a few
  shared threads, outside the engine's load lock: without a JIT (iOS) a conversion is a median of
  2 s, and up to minutes for the largest. dex2jar drops named local classes' enclosing methods,
  which kotlin-reflect needs; the converter puts them back from the DEX. It also sends an
  extension's exits and `Class.forName` calls to the engine's stand-ins (below). Cache entries of
  the previous version are carried over with those calls rewritten, not converted again.
- **Plugin class loaders** take Android's classes from the stand-ins, and make every other framework
  class an extension mentions from the index `framework-gen` writes: its real superclass and
  interfaces, enum constants, R ids, and no-op methods. Each is made once, for every extension. Names
  outside the index still get empty stubs (throwables, for the exceptions and errors among them), as
  do CloudStream app classes SkyStream lacks, so code that merely mentions one still loads. A stub is
  marked as one: an extension that asks whether a class exists (`Class.forName`) gets Android's
  answer, "missing" (WatchParty tells CloudStream from Nuvio so).
  The loaders don't keep an unloaded extension's classes alive through threads it started. Unloading
  removes its providers, extractors, listeners and Jackson cache entries.
- **The desktop runtime:** `tool/build_runtime.dart` links a trimmed Java runtime (every standard
  module, plus the JDK modules extensions use) from the JDK of the platform being built; the build
  carries it as an asset and the app unpacks it once into `<dataDir>/../runtime`. Without one, the
  app uses the machine's Java 17 or newer (JAVA_HOME, macOS's java_home, Android Studio's).
- **Android** loads the `.cs3` DEX directly, like CloudStream. The host activity must be an
  `AppCompatActivity` that extends `com.lagradost.cloudstream3.MainActivity`, because extensions
  cast to it; SkyStream's `MainActivity` hosts Flutter in a `FlutterFragment` for that. The app's
  `Application` must be `dev.akash.cs3engine.android.ExtensionHostApplication` (or extend it): an
  extension restarting the app through its application context is stopped there.
- **Failures stay contained:** calls time out even when an extension blocks its thread, a failing
  load leaves nothing registered, and on Android a crash on an extension's thread is ignored.

## Tests

- The app's `test/core/cloudstream/` and `test/features/cloudstream/` cover the app side.
- **Extension screens, on a device**, in `integration_test/cloudstream/`:
  - `extension_settings_test.dart`: SkyStream's test extension, with every control, the restart
    alert, and Force close;
  - `cnc_round_trip_test.dart`: CNC Verse's settings, both ways;
  - `settings_walk_test.dart`: sub-screens;
  - `settings_corpus_test.dart`: the 79 real screens. Compare a run with Android's using
    `tool/compare_trees.dart`;
  - `extension_popups_test.dart`: the test extension's own windows: Home's support pop-up kept for Support,
    search's page dialog dropped once sorted, its links' choice in the sheet; and a TV by the D-pad;
  - `popup_corpus_test.dart`: the 30 extensions that can open windows in the background: none shows, none
    opens a screen, and Support opens what each kept.
  - `cloudstream_switch_test.dart`: CloudStream switched off unloads the test extension at once, with its kept
    pop-up, and nothing loads it back while off; on again it's listed and loads when used; and a TV by the D-pad;
  - `extension_pages_test.dart`: the test extension's pages in the sheet: its sign-in (cookie, header, interface,
    title, redirect, user agent), a page promotion behind Support, a page while the person waits, and a TV's
    D-pad;
  - `real_pages_test.dart`: real extensions' sign-in and Cloudflare pages in their screens (Cinemacity, Kartoons,
    StreamPlay, Aniworld, AnimeWorldIndia).

  On a Mac, a test's frames stop while the display sleeps, and every pump waits for one: the macOS
  app's tests keep the display awake while they run, and print `CS3-NO-FRAMES` if frames stop anyway.
  Run the iOS simulator's under `caffeinate -di`.

  The engine's own tests (`engine/*/src/test`, `cd engine && ./gradlew test`) cover the stand-ins,
  the readers, the inflater, the fill and the host.
- `integration_test/cloudstream/` in the app installs extensions and plays a video, on a device:
  `flutter test integration_test/cloudstream/playback_test.dart -d DEVICE --dart-define=CS3_E2E=true`.
  They reach live sites, so CI leaves them out.
- `integration_test/cloudstream/maestro/` runs on release builds, which `flutter test` can't:
  `cloudstream_playback.yaml` (install and play), `extension_settings_release.yaml` (CNC Verse's
  settings), `extension_popups_release.yaml` (HDrezka's pop-up, kept and opened through Support),
  `cloudstream_switch_release.yaml` (CloudStream switched off and on) and `extension_pages_release.yaml`
  (AnimeWorldIndia's Cloudflare page in the sheet).

## Licensing

- CloudStream's library (`m2/`) is GPL-3.0, so an app that ships it must be GPL-3.0. So is this
  package (`LICENSE`); the stand-ins adapted from CloudStream's app are marked in their headers.
- OpenJDK is GPL-2.0 with the Classpath Exception. The iOS build applies patches from Mangatan's
  repository, and compiles in `symbol_keeper.cpp` from openjdk-mobile/ios-tools (AGPL-3.0).
- dex2jar is Apache-2.0, ASM is BSD-3-Clause, Gson is Apache-2.0.
