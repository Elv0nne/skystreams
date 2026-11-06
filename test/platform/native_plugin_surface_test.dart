/// What native code every platform build registers, pinned.
///
/// A dependency is added once, in `pubspec.yaml`, usually for one platform —
/// but it is bought for all five, and the bill is paid at **registration**, not
/// at use. `generated_plugin_registrant` constructs every registered plugin at
/// startup, so "no Dart code calls this" does not stop a plugin doing whatever
/// it likes the moment the app launches. Nothing else in this repo records what
/// each platform is carrying.
///
/// That is the mechanism behind both of the worst bugs this project has
/// shipped, and neither was visible to the rest of the suite:
///
///   * `screen_brightness` was added for the mobile player's touch rail. It
///     silently bought a Windows plugin that drives DDC/CI — I²C over the
///     display cable — at its registrar and again on `WM_CLOSE`, for a feature
///     `vlc_player_controls.dart` returns early from on desktop. Users reported
///     SkyStream resetting their monitor's brightness. It is gone now, with
///     `flutter_volume_controller`: the player's own plugin, `vlc_player`,
///     does both on Android and iOS and registers nothing new anywhere.
///   * `flutter_inappwebview` was added for the Cloudflare bypass. It silently
///     bought a Windows plugin whose constructor builds a WinRT dispatcher
///     queue, a Graphics.Capture probe, a hardware D3D11 device and a
///     compositor before any Dart runs — none of which this app ever uses.
///     It is gone now: bot checks and tracker sign-in moved to
///     `challenge_browser` (webview roadmap, Phase 2).
///
/// This test is the ledger. It does not judge; it makes a change to the native
/// surface **impossible to make silently**. When it fails, the diff names the
/// plugin, and someone decides — on purpose, in the pull request — rather than
/// finding out on release day on a platform they cannot build.
///
/// Editing the expected sets is a normal part of adding a dependency. What is
/// not normal is editing them without reading what the new plugin does at
/// registration on the platform you do not build.
///
/// This runs on any host: `flutter pub get` resolves the full five-platform
/// graph regardless of which machine it runs on, and `flutter test` runs
/// `pub get` first, so the manifest is always fresh.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Plugins that compile and register native code, per platform.
///
/// Dart-only plugins are deliberately excluded: they register nothing and cost
/// nothing at startup. `flutter_torrent_server` is the in-repo example — it
/// declares `dartPluginClass` with no `pluginClass` on desktop, so it appears
/// in no registrant at all.
const Map<String, Set<String>> _expected = <String, Set<String>>{
  'android': {
    'android_file_picker',
    'background_downloader',
    // Read before adding, per this file's rule. Registration sets up the
    // plugin's message channels and, on Android, iOS and macOS, a platform
    // view factory. No browser, renderer, window or GPU device exists until a
    // page is created for a bot check (core/network/clearance), and none
    // stays after it; Windows creates no WebView2 environment until then.
    'challenge_browser',
    'connectivity_plus',
    // Read before adding, per this file's rule. `onAttachedToEngine` sets up
    // one method channel and points the engine's log, toast and event hooks at
    // logcat, a Toast and that channel; as an ActivityAware plugin it hands
    // CloudStream's code the current Activity. The engine itself, and every
    // extension, loads on the first CloudStream call, never at registration.
    'cs3_engine',
    'device_info_plus',
    'dynamic_color',
    'flutter_displaymode',
    'flutter_js_ng',
    'flutter_secure_storage',
    'flutter_torrent_server',
    'integration_test',
    'jni',
    'jni_flutter',
    'open_file_android',
    'package_info_plus',
    'permission_handler_android',
    'share_plus',
    'shared_preferences_android',
    'sqflite_android',
    'url_launcher_android',
    // Also the player's brightness and system volume. `onAttachedToEngine`
    // sets up a method channel, an event channel and a platform view factory;
    // the volume's worker thread starts on the first volume call, the
    // broadcast receiver while the player listens, and the Activity's
    // `volumeControlStream` is pointed at media only while the player says it
    // is on screen.
    'vlc_player',
    'wakelock_plus',
  },
  'ios': {
    'background_downloader',
    // Read before adding, per this file's rule. Registration sets up the
    // plugin's message channels and, on Android, iOS and macOS, a platform
    // view factory. No browser, renderer, window or GPU device exists until a
    // page is created for a bot check (core/network/clearance), and none
    // stays after it; Windows creates no WebView2 environment until then.
    'challenge_browser',
    'connectivity_plus',
    // See the Android note. `register` sets up one method channel and notes
    // where the engine's jars are; its worker threads and the embedded Java VM
    // start on the first CloudStream call, never at registration.
    'cs3_engine',
    'device_info_plus',
    'file_picker_darwin',
    'flutter_js_ng',
    'flutter_secure_storage_darwin',
    'flutter_torrent_server',
    'integration_test',
    'open_file_ios',
    'package_info_plus',
    'permission_handler_apple',
    'share_plus',
    'shared_preferences_foundation',
    'sqflite_darwin',
    'url_launcher_ios',
    // See the Android note. The off-screen `MPVolumeView` is built on the
    // first volume call, and no audio session is touched at all.
    'vlc_player',
    'wakelock_plus',
  },
  'macos': {
    // Read before adding, per this file's rule. Registration sets up the
    // plugin's message channels and, on Android, iOS and macOS, a platform
    // view factory. No browser, renderer, window or GPU device exists until a
    // page is created for a bot check (core/network/clearance), and none
    // stays after it; Windows creates no WebView2 environment until then.
    'challenge_browser',
    'connectivity_plus',
    'device_info_plus',
    'dynamic_color',
    'file_picker_darwin',
    'flutter_js_ng',
    'flutter_secure_storage_darwin',
    'open_file_mac',
    'package_info_plus',
    'screen_retriever_macos',
    'share_plus',
    'shared_preferences_foundation',
    'sqflite_darwin',
    'url_launcher_macos',
    'vlc_player',
    'wakelock_plus',
    'window_manager',
  },
  'linux': {
    // Read before adding, per this file's rule. Registration sets up the
    // plugin's message channels; no WebKitGTK view or web context exists until
    // a page is created for a bot check. It needs libwebkit2gtk-4.1 to build
    // (CI installs it) and the runner's GtkOverlay around Flutter's view.
    'challenge_browser',
    'dynamic_color',
    'flutter_js_ng',
    'flutter_secure_storage_linux',
    'jni',
    'open_file_linux',
    'screen_retriever_linux',
    'url_launcher_linux',
    'vlc_player',
    'window_manager',
  },
  'windows': {
    // Read before adding, per this file's rule. Registration sets up the
    // plugin's message channels and, on Android, iOS and macOS, a platform
    // view factory. No browser, renderer, window or GPU device exists until a
    // page is created for a bot check (core/network/clearance), and none
    // stays after it; Windows creates no WebView2 environment until then.
    'challenge_browser',
    'connectivity_plus',
    'dynamic_color',
    'flutter_js_ng',
    'flutter_secure_storage_windows',
    'jni',
    // Dead code on Windows — every Permission.* call site is Platform.isAndroid
    // gated — but its registrar only builds method and event channels, so it is
    // not worth a stub package to remove.
    'permission_handler_windows',
    'screen_retriever_windows',
    'share_plus',
    'url_launcher_windows',
    'vlc_player',
    'window_manager',
  },
};

void main() {
  test('every platform registers exactly the native plugins we expect', () {
    final manifest = File('.flutter-plugins-dependencies');
    expect(
      manifest.existsSync(),
      isTrue,
      reason:
          'run from the package root; `flutter pub get` writes this file and '
          '`flutter test` runs pub get first, so it should always be here',
    );

    final plugins =
        (jsonDecode(manifest.readAsStringSync())
                as Map<String, dynamic>)['plugins']
            as Map<String, dynamic>;

    final problems = <String>[];

    for (final platform in _expected.keys) {
      final listed = (plugins[platform] as List<dynamic>? ?? <dynamic>[])
          .cast<Map<String, dynamic>>();
      final actual = listed
          .where((p) => p['native_build'] == true)
          .map((p) => p['name'] as String)
          .toSet();

      final added = actual.difference(_expected[platform]!);
      final removed = _expected[platform]!.difference(actual);

      for (final name in added) {
        problems.add(
          '$platform GAINED "$name". Something now compiles and registers '
          'native code on $platform. Read what it does at registration before '
          'adding it to the list — that is the step both shipped bugs skipped.',
        );
      }
      for (final name in removed) {
        problems.add(
          '$platform LOST "$name". If that was deliberate, delete it from the '
          'expected set. If not, a dependency or override has been dropped.',
        );
      }
    }

    expect(
      problems,
      isEmpty,
      reason:
          'The native plugin surface changed.\n\n${problems.join('\n\n')}\n\n'
          'This list is not a rule, it is a ledger: update it in the same '
          'commit as the dependency change, once you know what the plugin does '
          'when it registers.',
    );
  });
}
