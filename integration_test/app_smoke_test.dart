/// What the unit suite structurally cannot see.
///
/// `flutter test` runs on `flutter_tester`, where **no plugin is registered**.
/// So nothing a plugin does at registration — the moment this project's two
/// worst bugs happened — is observable there, and both compiled cleanly in CI:
///
///   * `screen_brightness_windows` issued DDC/CI (I²C over the display cable)
///     to the monitor's firmware from its constructor, and wrote brightness
///     back on every `WM_CLOSE`. Users reported SkyStream resetting their
///     screen brightness. The plugin is gone: the player's brightness comes
///     from its own plugin, on Android and iOS only.
///   * WebView2 was handed its default user-data folder, `<exe_dir>\WebView2`,
///     which on an installed build is inside `C:\Program Files` and unwritable
///     to a standard user — so the Cloudflare bypass may never have worked in
///     the shipped Windows artifact. challenge_browser, which replaced it, keeps
///     the folder under the user's local app data.
///
/// These run against a real engine with real plugins registered. They are
/// deliberately few, fast and offline: the job is to catch a native failure at
/// startup on a real platform, not to re-test behaviour the unit suite already
/// covers. Nothing here touches the network.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app support directory exists and is writable', (
    tester,
  ) async {
    final dir = await getApplicationSupportDirectory();
    expect(dir.existsSync(), isTrue, reason: 'no app support directory');

    // The assertion that would have caught the Program Files bug. Everything
    // the app persists - Hive boxes, logs, the WebView2 user-data folder -
    // depends on this being writable by the user running the app.
    final probe = File(p.join(dir.path, '.write_probe'));
    addTearDown(() {
      if (probe.existsSync()) probe.deleteSync();
    });

    probe.writeAsStringSync('ok');
    expect(
      probe.readAsStringSync(),
      'ok',
      reason:
          'app support is not writable: ${dir.path}. On Windows this is what '
          'sends WebView2 back to <exe_dir>\\WebView2 inside Program Files.',
    );
  });

  testWidgets('a WebView2 user-data folder can be created where we put it', (
    tester,
  ) async {
    if (kIsWeb || !Platform.isWindows) return;

    // Not ChallengeBrowser.create itself - that would spawn a real
    // msedgewebview2.exe in CI. The failure mode being pinned is the folder:
    // WebView2 could not create its store because the app had pointed it at an
    // unwritable directory. challenge_browser keeps it at
    // %LOCALAPPDATA%\<executable name>\WebView2 (UserDataFolder() in
    // packages/challenge_browser/windows/challenge_browser_plugin.cpp).
    final local = Platform.environment['LOCALAPPDATA'];
    expect(local, isNotNull, reason: 'no LOCALAPPDATA');
    final folder = Directory(
      p.join(
        local!,
        p.basenameWithoutExtension(Platform.resolvedExecutable),
        'WebView2',
      ),
    );

    // The same folder a shipped app uses, so this is a real user's live
    // WebView2 profile - their cf_clearance cookies, their browser cache. Clean
    // up only what this test created: the probe file always, the folder itself
    // only if it was not already there. Never `deleteSync(recursive: true)` on
    // a path the app owns at runtime.
    final preexisting = folder.existsSync();
    final probe = File(p.join(folder.path, '.write_probe'));
    addTearDown(() {
      if (probe.existsSync()) probe.deleteSync();
      // Non-recursive and only when empty: if anything else ended up in
      // there, leaving it is the correct outcome.
      if (!preexisting && folder.existsSync() && folder.listSync().isEmpty) {
        folder.deleteSync();
      }
    });

    if (!preexisting) folder.createSync(recursive: true);
    probe.writeAsStringSync('ok');

    expect(probe.existsSync(), isTrue);
    expect(
      folder.path.toLowerCase(),
      isNot(contains('program files')),
      reason:
          'WebView2 must keep its store under the user\'s local app data, '
          'never inside the installation directory',
    );
  });
}
