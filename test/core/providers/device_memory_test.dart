import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void answer(Future<Object?>? Function(MethodCall call)? handler) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deviceMemoryChannel, handler);

  tearDown(() => answer(null));

  (int?, int?, bool) fields(DeviceMemory m) => (m.totalMb, m.freeMb, m.lowRam);

  test('a runner reading is taken as it is', () async {
    answer((call) async {
      expect(call.method, 'read');
      return <String, Object?>{
        'totalMb': 7680,
        'freeMb': 2048,
        'lowRam': false,
      };
    });

    final memory = await readDeviceMemory(platform: TargetPlatform.android);

    expect(fields(memory), (7680, 2048, false));
  });

  test("Android's low-RAM verdict comes through", () async {
    answer(
      (_) async => <String, Object?>{
        'totalMb': 1024,
        'freeMb': 300,
        'lowRam': true,
      },
    );

    final memory = await readDeviceMemory(platform: TargetPlatform.android);

    expect(memory.lowRam, isTrue);
  });

  // The iOS simulator reports 0 for the app's allowance; a broken runner could
  // report anything. Neither may become a 0 MB buffer.
  test('zero, negative and missing numbers are unknown, never zero', () async {
    answer((_) async => <String, Object?>{'totalMb': 0, 'freeMb': -5});

    final memory = await readDeviceMemory(platform: TargetPlatform.iOS);

    expect(fields(memory), (null, null, false));
  });

  test('a runner that fails reads as unknown', () async {
    answer((_) async => throw PlatformException(code: 'unavailable'));

    final memory = await readDeviceMemory(platform: TargetPlatform.windows);

    expect(fields(memory), (null, null, false));
  });

  test('a runner with no channel reads as unknown', () async {
    final memory = await readDeviceMemory(platform: TargetPlatform.macOS);

    expect(fields(memory), (null, null, false));
  });

  test('Linux reads /proc/meminfo, in megabytes', () async {
    const meminfo =
        'MemTotal:       16314636 kB\n'
        'MemFree:         1048576 kB\n'
        'MemAvailable:   12345678 kB\n'
        'Buffers:          204800 kB\n';

    final memory = await readDeviceMemory(
      platform: TargetPlatform.linux,
      readMeminfo: () => meminfo,
    );

    expect(fields(memory), (15932, 12056, false));
  });

  test('a kernel without MemAvailable leaves free unknown', () async {
    final memory = await readDeviceMemory(
      platform: TargetPlatform.linux,
      readMeminfo: () => 'MemTotal:        2048000 kB\nMemFree:  512000 kB\n',
    );

    expect(fields(memory), (2000, null, false));
  });

  test("a test's Linux device reads what the test says", () async {
    debugMeminfo = () => 'MemTotal: 4194304 kB\nMemAvailable: 2097152 kB\n';
    addTearDown(() => debugMeminfo = null);

    final memory = await readDeviceMemory(platform: TargetPlatform.linux);

    expect(fields(memory), (4096, 2048, false));
  });

  test('an unreadable /proc/meminfo reads as unknown', () async {
    final memory = await readDeviceMemory(
      platform: TargetPlatform.linux,
      readMeminfo: () =>
          throw const FileSystemException('Permission denied', '/proc/meminfo'),
    );

    expect(fields(memory), (null, null, false));
  });
}
