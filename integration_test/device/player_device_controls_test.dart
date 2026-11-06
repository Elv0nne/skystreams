/// The player's volume and brightness on a real Android or iOS device, through
/// vlc_player's own device calls.
///
/// ```
/// flutter test integration_test/device/player_device_controls_test.dart -d <device> \
///   --dart-define=DEVICE_CONTROLS_E2E=true
/// ```
///
/// On request only, like the CloudStream and clearance runs: it needs a real
/// screen and a real audio route, which CI's emulator and simulator lack, and
/// without the define every test skips.
///
/// Leaves the volume and the brightness as it found them, and prints one
/// `DEVICE {json}` line. With `--dart-define=ROCKER=true` it also waits up to
/// 30 s, after printing `WAITING_FOR_ROCKER`, for the volume to change from
/// outside the app: a hardware button, or
/// `adb shell input keyevent KEYCODE_VOLUME_UP`. Nothing plays meanwhile, and
/// Android then spends the first press on showing its volume panel
/// (AudioService suppresses it), so press twice.
// The printed line is the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vlc_player/vlc_player.dart';

const bool _rocker = bool.fromEnvironment('ROCKER');

bool get _run =>
    const bool.fromEnvironment('DEVICE_CONTROLS_E2E') &&
    !kIsWeb &&
    (Platform.isAndroid || Platform.isIOS);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a volume set reads back as one of the stream\'s steps, the '
    'platform reports it, and the level comes back',
    skip: !_run,
    (tester) async {
      await tester.runAsync(() async {
        final before = await VlcSystemVolume.read();
        final fixed = await VlcSystemVolume.isFixed();
        final reported = <double>[];
        final changes = VlcSystemVolume.changes.listen(reported.add);
        await VlcSystemVolume.setPlayerShown(true);

        // Away from wherever it was, so the write is a change.
        final asked = (before ?? 0.5) > 0.5 ? 0.2 : 0.8;
        final clock = Stopwatch()..start();
        await VlcSystemVolume.write(asked);
        final written = clock.elapsedMilliseconds;
        await Future<void>.delayed(const Duration(milliseconds: 800));
        final after = await VlcSystemVolume.read();
        final echoes = List<double>.of(reported);

        double? rocker;
        if (_rocker) {
          reported.clear();
          print('WAITING_FOR_ROCKER');
          final deadline = DateTime.now().add(const Duration(seconds: 30));
          while (reported.isEmpty && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          rocker = reported.isEmpty ? null : reported.last;
        }

        if (before != null) await VlcSystemVolume.write(before);
        await VlcSystemVolume.setPlayerShown(false);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await changes.cancel();
        final report = {
          'test': 'volume',
          'before': before,
          'fixed': fixed,
          'asked': asked,
          'after': after,
          'writeMs': written,
          'echoes': echoes,
          'rocker': rocker,
        };
        print('DEVICE ${jsonEncode(report)}');

        expect(fixed, isFalse, reason: 'a phone or tablet');
        expect(after, isNotNull);
        expect((after! - asked).abs(), lessThan(0.07));
        expect(echoes, isNotEmpty, reason: 'the platform reports the write');
        if (_rocker) expect(rocker, isNotNull, reason: 'no key reached media');
      });
    },
  );

  testWidgets(
    'a brightness set is the screen\'s at once, never under the '
    'floor, and a reset gives the system level back',
    skip: !_run,
    (tester) async {
      await tester.runAsync(() async {
        // A moment after each set: iOS reports the screen's level as it gets
        // there.
        const settle = Duration(milliseconds: 400);
        final before = await VlcScreenBrightness.read();
        await VlcScreenBrightness.set(0.2);
        await Future<void>.delayed(settle);
        final set = await VlcScreenBrightness.read();
        await VlcScreenBrightness.set(0);
        await Future<void>.delayed(settle);
        final floor = await VlcScreenBrightness.read();
        await VlcScreenBrightness.reset();
        // iOS fades the system's level back over about 0.3 s.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        final after = await VlcScreenBrightness.read();
        final report = {
          'test': 'brightness',
          'before': before,
          'set': set,
          'floor': floor,
          'after': after,
        };
        print('DEVICE ${jsonEncode(report)}');

        expect(set, closeTo(0.2, 0.01));
        if (Platform.isAndroid) {
          expect(floor, closeTo(0.01, 0.001), reason: "Android's floor");
        }
        expect(after, closeTo(before!, 0.02));
      });
    },
  );
}
