/// Which handsets and tablets turn when the app asks them to.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';

void main() {
  // Measured on 2026-10-11 with the player's rotate button: both phones and
  // the API 35 tablet emulator turned; the iPad Pro 11-inch (M5) simulator on
  // iPadOS 26.5 and the API 36 emulator at 1600x2560 / 320 dpi stayed put.
  group('obeysOrientationRequests', () {
    test('a phone turns, on either platform', () {
      expect(
        obeysOrientationRequests(isIOS: false, isTablet: false, androidSdk: 36),
        isTrue,
      );
      expect(obeysOrientationRequests(isIOS: true, isTablet: false), isTrue);
    });

    test('an Android tablet turns before Android 16, and not from it', () {
      expect(
        obeysOrientationRequests(isIOS: false, isTablet: true, androidSdk: 35),
        isTrue,
      );
      expect(
        obeysOrientationRequests(isIOS: false, isTablet: true, androidSdk: 36),
        isFalse,
      );
      expect(
        obeysOrientationRequests(isIOS: false, isTablet: true, androidSdk: 37),
        isFalse,
      );
    });

    test('an iPad does not', () {
      expect(obeysOrientationRequests(isIOS: true, isTablet: true), isFalse);
    });
  });

  group('androidTier', () {
    test("the OEM's low-RAM verdict makes a device low, whatever its RAM", () {
      expect(androidTier(lowRam: true, physicalRamMb: 4096), DeviceTier.low);
    });

    test('without it, the RAM decides', () {
      expect(androidTier(lowRam: false, physicalRamMb: 1536), DeviceTier.low);
      expect(
        androidTier(lowRam: false, physicalRamMb: 4096),
        DeviceTier.standard,
      );
      expect(androidTier(lowRam: false, physicalRamMb: 8192), DeviceTier.high);
    });
  });
}
