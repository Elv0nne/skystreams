import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/utils/linux_wakelock.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// wakelock_plus' Linux plugin, as its source has it: each enable opens a new portal inhibitor and keeps only the
/// newest handle; a disable closes that one.
class _Portal extends WakelockPlusPlatformInterface {
  int open = 0;
  bool _held = false;
  int failures = 0;

  @override
  Future<void> toggle({required bool enable}) async {
    // The D-Bus call takes a turn of the event loop, as the plugin's does.
    await Future<void>.delayed(Duration.zero);
    if (failures > 0) {
      failures--;
      throw StateError('the portal is gone');
    }
    if (enable) {
      open++;
      _held = true;
    } else if (_held) {
      open--;
      _held = false;
    }
  }

  @override
  Future<bool> get enabled async => _held;
}

void main() {
  late _Portal portal;
  late OneInhibitorWakelock wakelock;

  setUp(() {
    portal = _Portal();
    wakelock = OneInhibitorWakelock(portal);
  });

  test("the plugin alone leaks: an enable while one is held leaves the first open after the disable", () async {
    // The finding, from the follow-ups' second review: after an alt-tab during a film or a game, the screen never
    // slept again until SkyStream quit.
    await portal.toggle(enable: true);
    await portal.toggle(enable: true);
    await portal.toggle(enable: false);
    expect(portal.open, 1);
  });

  test('an enable while one is held opens nothing: one disable lets the screen sleep', () async {
    await wakelock.toggle(enable: true);
    await wakelock.toggle(enable: true);
    expect(portal.open, 1);
    expect(await wakelock.enabled, isTrue);
    await wakelock.toggle(enable: false);
    expect(portal.open, 0);
    expect(await wakelock.enabled, isFalse);
  });

  test('calls made together run one at a time: still one inhibitor', () async {
    await Future.wait<void>([
      wakelock.toggle(enable: true),
      wakelock.toggle(enable: true),
      wakelock.toggle(enable: true),
    ]);
    expect(portal.open, 1);
    await Future.wait<void>([wakelock.toggle(enable: false), wakelock.toggle(enable: false)]);
    expect(portal.open, 0);
  });

  test("a call that fails reaches its caller, and doesn't hold up the next", () async {
    portal.failures = 1;
    await expectLater(wakelock.toggle(enable: true), throwsStateError);
    await wakelock.toggle(enable: true);
    expect(portal.open, 1);
  });

  test("through wakelock_plus' own calls, as the player and the full-screen window make them", () async {
    wakelockPlusPlatformInstance = wakelock;
    await WakelockPlus.enable();
    await WakelockPlus.enable();
    await WakelockPlus.disable();
    expect(portal.open, 0);
  });

  test('installed on Linux only, around the plugin there', () {
    final before = WakelockPlusPlatformInterface.instance;
    installLinuxWakelock(linux: false);
    expect(WakelockPlusPlatformInterface.instance, same(before));
    installLinuxWakelock(linux: true);
    final installed = WakelockPlusPlatformInterface.instance;
    expect(installed, isA<OneInhibitorWakelock>());
    expect((installed as OneInhibitorWakelock).inner, same(before));
    WakelockPlusPlatformInterface.instance = before;
  });
}
