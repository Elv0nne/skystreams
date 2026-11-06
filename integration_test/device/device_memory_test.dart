/// The memory channel answers on this platform (spec 1.2): installed memory,
/// and what is free for the app now.
///
/// ```
/// flutter test integration_test/device/device_memory_test.dart -d DEVICE
/// ```
///
/// Prints one `MEMORY {json}` line.
// The printed line is the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/providers/device_memory.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the memory channel answers', (tester) async {
    final memory = await readDeviceMemory();
    print(
      'MEMORY ${jsonEncode({'platform': Platform.operatingSystem, 'totalMb': memory.totalMb, 'freeMb': memory.freeMb, 'lowRam': memory.lowRam})}',
    );
    expect(memory.totalMb, greaterThan(512));
    // iOS reports the app's own allowance, and the simulator has none.
    if (!Platform.isIOS) {
      expect(memory.freeMb, isNotNull);
      expect(memory.freeMb, lessThanOrEqualTo(memory.totalMb!));
    }
  });
}
