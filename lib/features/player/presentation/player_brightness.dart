/// The screen's brightness for the player's swipe, behind one seam.
///
/// A seam for the same reasons as the system volume's: the controls' gesture
/// can be tested without a platform channel, and the platform's refusals stop
/// here.
library;

import 'package:flutter/foundation.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../core/utils/latest_value_sender.dart';

/// Reads and sets the screen's brightness for the player, 0..1.
abstract interface class PlayerBrightness {
  /// The level the screen shows now, or null where the platform did not
  /// answer.
  Future<double?> read();

  /// Sets the app's level, at once.
  void set(double level);

  /// Gives the screen back to the system's level.
  void reset();
}

/// The real one, through the player's own plugin on Android and iOS
/// ([VlcScreenBrightness]): applied as asked, with no animation, so the screen
/// follows the finger.
///
/// screen_brightness, used here before, animated every change for a second on
/// iOS, so a swipe's brightness trailed the finger and only arrived once it
/// stopped. A swipe sets the level many times a second, so the sets go one at
/// a time with only the newest waiting ([LatestValueSender]), and [reset]
/// rides the same queue: a set still waiting as the player closes is dropped
/// rather than landing after the reset and leaving the screen dim.
class PlatformPlayerBrightness implements PlayerBrightness {
  /// A level to set, or null for the reset.
  late final LatestValueSender<double?> _calls = LatestValueSender<double?>(
    (level) => level == null
        ? VlcScreenBrightness.reset()
        : VlcScreenBrightness.set(level),
  );

  @override
  Future<double?> read() async {
    try {
      return await VlcScreenBrightness.read();
    } catch (error) {
      if (kDebugMode) debugPrint('screen brightness read failed: $error');
      return null;
    }
  }

  @override
  void set(double level) => _calls.send(level.clamp(0.0, 1.0));

  @override
  void reset() => _calls.send(null);
}
