import 'package:flutter/services.dart';

/// The app's screen brightness on Android and iOS, 0..1, through this plugin.
///
/// Applied as asked, with no animation, so the screen follows a finger. On
/// Android it is the app's window that changes, and the system's level comes
/// back by itself when the app leaves. iOS has one brightness for the whole
/// device, so the plugin keeps the system's level and gives it back on
/// [reset] and while the app is in the background.
///
/// Android and iOS only: elsewhere the calls fail with a
/// [MissingPluginException]. A desktop's brightness is the monitor's, and the
/// player leaves it alone.
abstract final class VlcScreenBrightness {
  static const MethodChannel _methods = MethodChannel('vlc_player');

  /// The level the screen shows now.
  static Future<double?> read() async =>
      (await _methods.invokeMethod<num>('getScreenBrightness'))?.toDouble();

  /// Sets the app's level.
  static Future<void> set(double level) =>
      _methods.invokeMethod<void>('setScreenBrightness', {'level': level});

  /// Gives the screen back to the system's level.
  static Future<void> reset() =>
      _methods.invokeMethod<void>('resetScreenBrightness');
}
