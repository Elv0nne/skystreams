# Building cs3_engine's artifacts

The app builds with what is committed here: nothing below is needed to run SkyStream, except the
desktop Java runtime, which desktop builds should carry. Rebuild an artifact when its source
changes, and commit what the script writes.

| Artifact | Rebuild when | Command | Needs |
|---|---|---|---|
| `assets/engine/*.jar` | anything under `engine/` changes | `tool/build_engine.sh` | JDK 17+, and the Android SDK's API 36 platform (`platforms/android-36/android.jar`, through `ANDROID_HOME`, `ANDROID_SDK_ROOT` or `~/Library/Android/sdk`), which `framework-gen` reads; the pinned AndroidX and Material artifacts download from Google's Maven |
| `engine/test-fixtures/` and `test_extension/build/SkyStreamTest.cs3` | `test_extension/` changes | `tool/build_test_extension.sh` | JDK 17+, the Android SDK (platform 36; build-tools' `d8` and `aapt2`) |
| `m2/` (CloudStream's library) | moving to a newer CloudStream, or a patch in `tool/patches/` changes | `tool/build_cloudstream_library.sh` | JDK 21, Android SDK |
| `ios/Frameworks/OpenJDKRuntime.xcframework` | the VM or its patches change | `tool/ios/build_openjdk.sh sim`, `tool/ios/build_openjdk.sh device`, then `tool/ios/package_openjdk.sh` | macOS, Xcode, JDK 21, `brew install autoconf make` |
| `assets/runtime/runtime-<os>-<arch>.tar.gz` | every desktop build (not committed) | `dart run packages/cs3_engine/tool/build_runtime.dart` | a JDK 17+ of the platform and architecture being built, with `jmods` |

Android needs nothing: it compiles `engine/engine-core`, `engine/ui-core` and `engine/app-shims` with the app and
resolves CloudStream's library from `m2/`, which the plugin adds to the build's repositories.

## The desktop Java runtime

Run from the repository root before `flutter build macos|windows|linux`:

```sh
dart run packages/cs3_engine/tool/build_runtime.dart              # JAVA_HOME, or macOS's java_home
dart run packages/cs3_engine/tool/build_runtime.dart --java-home /path/to/jdk
```

It links every standard Java module, plus jdk.unsupported, jdk.crypto.ec, jdk.charsets,
jdk.localedata, jdk.dynalink and jdk.zipfs, into a 66 MB image (46 MB compressed), for the JDK's
own platform and architecture. For a macOS x64 build on Apple Silicon, use an x64 JDK. Android
Studio's bundled runtime has no `jmods`, so use a full JDK (Temurin, Zulu...).

CI does this in `ci.yml`, `release.yml` and `preview.yml`, with Temurin 21 of each build's
architecture. A build without it still works where Java 17+ is installed.

## Notes

- `tool/build_openjdk.sh` pins openjdk/mobile, three patches from Mangatan and ios-tools'
  `symbol_keeper.cpp` to the commits Mangatan's `embedded-openjdk-ios13-v16` runtime was built from,
  so the VM can reuse that release's `java.base` class image. Its work tree goes in `.build/`
  (about 2 GB, ignored).
- `tool/build_cloudstream_library.sh` builds CloudStream at a pinned commit (`CLOUDSTREAM_COMMIT`),
  with `tool/patches/` applied. There is one: `WebViewResolver` asks the resolver the engine sets
  (`WebViewResolverHost`, added to the library's common code) first, on both builds. Upstream's JVM
  one is a `TODO()`; Android's own WebView stays as the fallback when none is set. Moving to a newer
  commit means checking that it still applies.
- **The framework's pins** are `engine/engine-jvm/build.gradle.kts`'s `framework(...)` lines: the
  versions SkyStream's Android app resolves.
  - **Moving one:** rebuild the jars, run the engine's tests, and run the 79-screen corpus on a
    desktop (`integration_test/cloudstream/settings_corpus_test.dart`), compared with Android's by
    `tool/compare_trees.dart`.
  - **What stops the build:** `framework-gen` refuses a hand-written stand-in that disagrees with
    Android (its kind, superclass, `final`, a constant), or that lacks a method its interfaces or
    abstract superclasses ask for. Its no-ops never cover a method the JDK class under a stand-in has
    (ICU's `SimpleDateFormat` keeps `DateFormat`'s final `format`), and the engine's tests load every
    class of the filled jar, so a clash stops them.
  - **What the build prints:** the stand-ins, the no-ops added, the framework classes written whole
    (the types the stand-ins' own methods name, with their superclasses, so reflection on a stand-in
    finds them), and the classes indexed.
- **The test extension** (`test_extension/`) has a settings screen with every kind of control, and its
  providers show its own windows as real extensions do: a support pop-up from the home page, a page dialog
  from search, and a choice of server from links. The engine's pop-up tests and
  `integration_test/cloudstream/extension_popups_test.dart` read them. It compiles against what the app
  provides when it runs (CloudStream's library, `app-shims`, AppCompat, Material, RecyclerView and
  kotlinx.coroutines), never packed.
