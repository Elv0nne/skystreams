/// The device's memory, as the player sizes its read-ahead from it (spec
/// 1.2): installed, free for this app now, and the OEM's low-RAM verdict.
///
/// Read at each open, because free memory changes. Android, iOS, macOS and
/// Windows answer on the `dev.akash.skystream/device_memory` channel from
/// their runners; Linux is read here, from `/proc/meminfo`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The runners' memory channel. Its one method, `read`, answers a map of
/// `totalMb`, `freeMb` and `lowRam`.
const deviceMemoryChannel = MethodChannel('dev.akash.skystream/device_memory');

/// One reading. A number nobody could read is null, never zero: a failed read
/// must not shrink a buffer to nothing.
@immutable
class DeviceMemory {
  const DeviceMemory({this.totalMb, this.freeMb, this.lowRam = false});

  /// A channel reading. Missing, zero and negative numbers are unknown.
  factory DeviceMemory.fromChannel(Object? reading) {
    if (reading is! Map) return const DeviceMemory();
    int? mb(Object? value) => value is num && value > 0 ? value.round() : null;
    return DeviceMemory(
      totalMb: mb(reading['totalMb']),
      freeMb: mb(reading['freeMb']),
      lowRam: reading['lowRam'] == true,
    );
  }

  /// Linux's `/proc/meminfo`. Kernels before 3.14 have no `MemAvailable`, so
  /// free is unknown there.
  factory DeviceMemory.fromMeminfo(String meminfo) {
    int? mb(String key) {
      final match = RegExp(
        '^$key:\\s+(\\d+) kB',
        multiLine: true,
      ).firstMatch(meminfo);
      final kib = match == null ? 0 : int.parse(match.group(1)!);
      return kib > 0 ? kib ~/ 1024 : null;
    }

    return DeviceMemory(totalMb: mb('MemTotal'), freeMb: mb('MemAvailable'));
  }

  /// Installed memory in MB, or null when the platform didn't say.
  final int? totalMb;

  /// Memory this app can still use, in MB, or null when unknown.
  ///
  /// Android: `MemoryInfo.availMem`. iOS: `os_proc_available_memory()`, the
  /// app's own allowance before the OS ends it. macOS: free, inactive,
  /// purgeable and speculative pages. Windows: `ullAvailPhys`. Linux:
  /// `MemAvailable`.
  final int? freeMb;

  /// Android's `ActivityManager.isLowRamDevice()`, which the OEM sets. Not
  /// `MemoryInfo.lowMemory`, which only says memory is short at this moment.
  /// False elsewhere.
  final bool lowRam;
}

/// What `/proc/meminfo` reads as in widget tests, so a test's Linux device
/// doesn't take the memory of the machine the tests run on. Null reads the
/// file.
@visibleForTesting
String Function()? debugMeminfo;

/// Reads the device's memory now. Never throws: what can't be read is
/// unknown. [platform] and [readMeminfo] are for tests.
///
/// `/proc/meminfo` is a small file the kernel writes as it is read, so it is
/// read at once, not awaited.
Future<DeviceMemory> readDeviceMemory({
  TargetPlatform? platform,
  String Function()? readMeminfo,
}) async {
  try {
    if ((platform ?? defaultTargetPlatform) == TargetPlatform.linux) {
      final read =
          readMeminfo ??
          debugMeminfo ??
          () => File('/proc/meminfo').readAsStringSync();
      return DeviceMemory.fromMeminfo(read());
    }
    return DeviceMemory.fromChannel(
      await deviceMemoryChannel.invokeMethod<Object?>('read'),
    );
  } on Object {
    return const DeviceMemory();
  }
}
