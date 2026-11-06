import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The device's volume and brightness, through this plugin's own native code.
///
/// flutter_volume_controller's iOS listener set the session's category (its
/// default, `.ambient`, is muted by silent mode) as it started and deactivated
/// the session as it stopped; under a playing film that silenced libVLC's audio
/// output, and its stop then waited forever on the decoder (SkyStream on an
/// iPad, 2026-10-10). screen_brightness animated every change for a second, so
/// a drag's brightness trailed the finger.
void main() {
  String text(String path) => File(path).readAsStringSync();

  group('iOS', () {
    test(
      'the volume is read, watched and set without touching the session',
      () {
        final source = text(
          'ios/vlc_player/Sources/vlc_player/VlcSystemVolume.swift',
        );
        expect(source, contains('outputVolume'));
        // Set through the system's own volume control, as iOS allows.
        expect(source, contains('MPVolumeView'));
        expect(source, contains('UISlider'));
        // libVLC lets the session go as the film pauses, and with it go the
        // sets and the reports: taken back as VLC's player takes it, and
        // never let go or recategorised under libVLC.
        expect(source, contains('setActive(true)'));
        expect(source, isNot(contains('setActive(false')));
        expect(source, isNot(contains('setCategory')));
      },
    );

    test('a brightness drag is applied at once; the system level comes back as '
        'the app goes inactive, and the app level as it returns', () {
      final source = text(
        'ios/vlc_player/Sources/vlc_player/VlcScreenBrightness.swift',
      );
      final set = source.substring(
        source.indexOf('func set('),
        source.indexOf('func reset('),
      );
      expect(set, contains('screen.brightness = value'));
      expect(set, isNot(contains('fade(')));
      expect(source, isNot(contains('Thread.sleep')));
      expect(source, contains('willResignActiveNotification'));
      expect(source, contains('didBecomeActiveNotification'));
    });

    test('the plugin answers the device calls with no player', () {
      final source = text(
        'ios/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift',
      );
      final handle = source.indexOf('public func handle(');
      expect(handle, greaterThan(-1));
      // Ahead of the viewId guard: the calls name no player.
      expect(
        source.indexOf('handleDevice(call', handle),
        lessThan(source.indexOf('A valid viewId is required.', handle)),
      );
      for (final method in [
        'getSystemVolume',
        'setSystemVolume',
        'setPlayerShown',
        'isSystemVolumeFixed',
        'getScreenBrightness',
        'setScreenBrightness',
        'resetScreenBrightness',
      ]) {
        expect(source, contains('case "$method":'), reason: method);
      }
      expect(source, contains('"vlc_player/system_volume"'));
      expect(source, isNot(contains('setSystemVolumeUiShown')));
    });
  });

  group('Android', () {
    const dir = 'android/src/main/kotlin/com/lingjhf/vlc_player';

    test('the plugin answers the device calls with no player', () {
      final source = text('$dir/VlcPlayerPlugin.kt');
      expect(source, contains('ActivityAware'));
      expect(
        source.indexOf('handleDevice(call, result)'),
        lessThan(source.indexOf('A valid viewId is required.')),
      );
      for (final method in [
        'getSystemVolume',
        'setSystemVolume',
        'setPlayerShown',
        'isSystemVolumeFixed',
        'getScreenBrightness',
        'setScreenBrightness',
        'resetScreenBrightness',
      ]) {
        expect(source, contains('"$method" ->'), reason: method);
      }
      expect(source, contains('"vlc_player/system_volume"'));
    });

    test('the media stream, as VLC and Media3 set it: one call per new step, '
        "the safety prompt only for a raise that didn't take, off the main "
        'thread', () {
      final source = text('$dir/VlcSystemVolume.kt');
      expect(source, contains('AudioManager.STREAM_MUSIC'));
      expect(source, contains('if (wanted == before) return'));
      // The level that stood goes back, so a step of the rocker made right
      // after can be told from it.
      expect(source, contains('main.post { result.success(stood) }'));
      expect(source, contains('setStreamVolume(STREAM, wanted, 0)'));
      expect(
        source.indexOf('AudioManager.FLAG_SHOW_UI'),
        greaterThan(source.indexOf('VlcDeviceLevels.heldBack(')),
      );
      expect(source, contains('catch (e: RuntimeException)'));
      expect(source, contains('HandlerThread'));
      expect(source, contains('isVolumeFixed'));
      // The volume keys move the media stream while the player is up.
      expect(source, contains('volumeControlStream = STREAM'));
      // Changes: the broadcast, read back rather than trusted.
      expect(source, contains('"android.media.VOLUME_CHANGED_ACTION"'));
      expect(source, contains('Context.RECEIVER_NOT_EXPORTED'));
    });

    test(
      "brightness is the app's window's, with no system setting written",
      () {
        final source = text('$dir/VlcScreenBrightness.kt');
        expect(source, contains('screenBrightness = VlcDeviceLevels'));
        expect(source, contains('BRIGHTNESS_OVERRIDE_NONE'));
        expect(source, isNot(contains('WRITE_SETTINGS')));
        expect(source, isNot(contains('Settings.System.put')));
      },
    );
  });
}
