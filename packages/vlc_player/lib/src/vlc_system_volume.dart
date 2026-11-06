import 'package:flutter/services.dart';

/// The device's media volume on Android and iOS, 0..1, through this plugin.
///
/// Nothing here touches the app's audio session. On iOS the level is read and
/// watched through `AVAudioSession.outputVolume` and set through the system's
/// own volume slider: a volume plugin that changed the session's category, or
/// deactivated it, under a playing film silenced libVLC's audio output, and
/// stopping the player then waited forever on its decoder. On Android it is
/// the media stream's volume.
///
/// Android and iOS only: elsewhere the calls fail with a
/// [MissingPluginException]. The desktops keep the machine's mixer and use
/// the player's own gain instead.
abstract final class VlcSystemVolume {
  static const MethodChannel _methods = MethodChannel('vlc_player');
  static const EventChannel _events = EventChannel('vlc_player/system_volume');

  /// The current level, or null if the platform gave none.
  static Future<double?> read() async =>
      (await _methods.invokeMethod<num>('getSystemVolume'))?.toDouble();

  /// Sets the level, without the system's own volume pop-up, and answers the
  /// level that stood, where the platform knows it: Android's media stream
  /// rounds to its steps, and a raise its hearing-safety limit held back
  /// stays where it was.
  static Future<double?> write(double level) async =>
      (await _methods.invokeMethod<num>('setSystemVolume', {
        'level': level,
      }))?.toDouble();

  /// Tells the platform whether the player, which draws a volume rail of its
  /// own, is on screen. While it is, iOS shows no volume pop-up for the
  /// hardware buttons, and on Android the buttons move the media volume even
  /// while the film is paused. [shown] false gives both back.
  static Future<void> setPlayerShown(bool shown) =>
      _methods.invokeMethod<void>('setPlayerShown', {'shown': shown});

  /// Whether the device's volume is fixed: Android's `isVolumeFixed`, true on
  /// Chromebooks and some TV boxes, where an app can't change it. The player
  /// then keeps a gain of its own for the whole range.
  static Future<bool> isFixed() async =>
      await _methods.invokeMethod<bool>('isSystemVolumeFixed') ?? false;

  /// Each change of the level: the hardware buttons, Control Center, another
  /// app.
  static Stream<double> get changes => _events.receiveBroadcastStream().map(
    (level) => (level as num).toDouble(),
  );
}
