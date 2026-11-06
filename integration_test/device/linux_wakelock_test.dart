/// Linux, in a GNOME session: SkyStream keeps the screen awake with one portal inhibitor however often it asks (the
/// player as playback goes on, a full-screen game back from the background), and a disable lets the screen sleep.
/// wakelock_plus' own Linux plugin opens one per enable and closes only the newest: the first is shown leaking, then
/// the app's wrapper ([installLinuxWakelock]) holding one.
///
/// ```
/// flutter test integration_test/device/linux_wakelock_test.dart -d linux
/// ```
///
/// Counts GNOME's session inhibitors (`gdbus`), and prints one `WAKELOCK {json}` line.
// The printed line is the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/utils/linux_wakelock.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// The session's inhibitors whose reason is a wakelock_plus one (`<app name>: wakelock active`).
Future<int> _held() async {
  Future<String> call(String path, String method) async {
    final result = await Process.run('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.gnome.SessionManager',
      '--object-path',
      path,
      '--method',
      method,
    ]);
    if (result.exitCode != 0) throw StateError('gdbus $method: ${result.stderr}');
    return result.stdout as String;
  }

  final list = await call('/org/gnome/SessionManager', 'org.gnome.SessionManager.GetInhibitors');
  var held = 0;
  for (final path in RegExp(r"'(/org/gnome/SessionManager/Inhibitor\d+)'").allMatches(list)) {
    final reason = await call(path.group(1)!, 'org.gnome.SessionManager.Inhibitor.GetReason');
    if (reason.contains('wakelock active')) held++;
  }
  return held;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('one inhibitor however often the screen is kept awake, and none after', skip: !Platform.isLinux, (
    tester,
  ) async {
    await tester.runAsync(() async {
      final before = await _held();
      // The plugin alone, as wakelock_plus has it: two enables and a disable leave the first inhibitor open.
      final plugin = WakelockPlusPlatformInterface.instance;
      await plugin.toggle(enable: true);
      await plugin.toggle(enable: true);
      await plugin.toggle(enable: false);
      final leaked = await _held() - before;

      // The app's wrapper, as main() installs it, through wakelock_plus' own calls.
      installLinuxWakelock();
      final start = await _held();
      await WakelockPlus.enable();
      await WakelockPlus.enable();
      await WakelockPlus.enable();
      final whileOn = await _held() - start;
      await WakelockPlus.disable();
      final after = await _held() - start;
      print('WAKELOCK ${jsonEncode({'pluginLeaked': leaked, 'heldWhileOn': whileOn, 'heldAfter': after})}');
      expect(whileOn, 1);
      expect(after, 0);
    });
  });
}
