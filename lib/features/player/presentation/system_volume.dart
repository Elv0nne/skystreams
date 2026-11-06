/// The operating system's media volume, behind one seam.
///
/// A seam rather than a direct call so the player's volume logic can be tested
/// without a platform channel, and so the one place that decides whether to
/// touch the system at all is [VolumeRouting] rather than a scattering of
/// platform checks.
///
/// Every method swallows its own failures. The system stream is a courtesy:
/// on a desktop nothing here is ever called, and on a handset a refusal - no
/// permission, a headset transition, a plugin that does not implement the
/// platform - must leave the player's own gain working rather than take the
/// volume control down with it.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../core/utils/latest_value_sender.dart';

/// Reads and writes the platform's media volume, 0..1.
abstract interface class SystemVolume {
  /// The current level, or null where the platform did not answer.
  Future<double?> read();

  /// Sets the level. Silently does nothing where the platform refuses.
  Future<void> write(double level);

  /// Fires whenever the level changes from outside this app - which on a
  /// handset is the hardware rocker, and is the whole reason the player cannot
  /// simply remember what it last set.
  Stream<double> get changes;

  /// Whether apps can't change the device's volume (Android's
  /// `isVolumeFixed`: Chromebooks, some TV boxes). The player then keeps a gain
  /// of its own for the whole range.
  Future<bool> isFixed();

  /// Tells the platform the player, which draws its own volume rail, is on
  /// screen or no longer is. See [VlcSystemVolume.setPlayerShown].
  Future<void> setPlayerShown(bool shown);

  /// Releases the platform listener.
  void dispose();
}

/// The real one, through the player's own plugin on Android and iOS
/// ([VlcSystemVolume]), which touches no audio session.
///
/// flutter_volume_controller, used here before, set the app's session
/// category on iOS as its listener started (`.ambient`, which silent mode
/// mutes) and deactivated the session as it stopped, both under a playing
/// film: a film went silent a second in, and leaving the player froze the
/// app.
///
/// A swipe or a held key writes the level many times a second, and the
/// platform reports each write back a moment later, as VLC's players see it:
///
/// * One write goes at a time, and only the newest waits ([LatestValueSender]),
///   so the level never trails the finger.
/// * The platform's reports while writes are going and for [settle] after the
///   last are echoes of them, and are dropped: the rail already shows the
///   level asked for, and a late echo would pull it back mid-swipe. VLC's iOS
///   player ignores them the same way while its volume swipe runs.
/// * Once the writes settle the level is read once, and reported where it
///   moved from the level the platform said stood after the last write (the
///   rocker), or where it isn't the one asked for (Android's hearing-safety
///   limit held a raise back).
class PlatformSystemVolume implements SystemVolume {
  PlatformSystemVolume({
    @visibleForTesting this.settle = const Duration(milliseconds: 400),
  });

  /// How long after the last write the platform's reports count as its echoes.
  final Duration settle;

  /// How far the settled level may be from the one that stood after the last
  /// write and still be it: float noise, under any stream's step.
  static const double _moved = 0.01;

  /// How far the settled level may be from the one asked for and still be it:
  /// a step of a 15-step stream, which is what Android rounds a level to.
  static const double _heldBack = 0.07;

  final StreamController<double> _changes =
      StreamController<double>.broadcast();
  StreamSubscription<double>? _subscription;
  late final LatestValueSender<double> _writes = LatestValueSender<double>(
    _send,
    onIdle: _settleFromNow,
  );
  double? _asked;

  /// The level the platform said stood after the last write, or null where it
  /// gave none.
  double? _stood;
  Timer? _settling;
  bool _disposed = false;

  @override
  Stream<double> get changes {
    // Attached lazily: the plugin registers a platform listener, and a player
    // on a form factor that never reads the system volume should not be
    // holding one.
    _subscription ??= VlcSystemVolume.changes.listen(
      _reported,
      onError: (Object _) {},
    );
    return _changes.stream;
  }

  void _reported(double level) {
    if (_writes.busy || (_settling?.isActive ?? false)) return;
    _add(level);
  }

  @override
  Future<double?> read() async {
    try {
      return await VlcSystemVolume.read();
    } catch (error) {
      if (kDebugMode) debugPrint('system volume read failed: $error');
      return null;
    }
  }

  @override
  Future<void> write(double level) async {
    final value = level.clamp(0.0, 1.0);
    _asked = value;
    _settleFromNow();
    _writes.send(value);
  }

  Future<void> _send(double level) async {
    _stood = await VlcSystemVolume.write(level);
  }

  void _settleFromNow() {
    // A write still in flight when the player went drains afterwards.
    if (_disposed) return;
    _settling?.cancel();
    _settling = Timer(settle, _settled);
  }

  Future<void> _settled() async {
    // Still writing: the queue's drain starts the clock again.
    if (_writes.busy) return;
    final asked = _asked;
    final stood = _stood;
    final level = await read();
    // A write made while the read was out is newer than what it read.
    if (_writes.busy || _asked != asked) return;
    if (asked == null || level == null) return;
    final moved = stood != null && (level - stood).abs() > _moved;
    if (moved || (level - asked).abs() > _heldBack) _add(level);
  }

  void _add(double level) {
    if (!_changes.isClosed) _changes.add(level);
  }

  @override
  Future<bool> isFixed() async {
    try {
      return await VlcSystemVolume.isFixed();
    } catch (error) {
      if (kDebugMode) debugPrint('system volume fixed check failed: $error');
      return false;
    }
  }

  @override
  Future<void> setPlayerShown(bool shown) async {
    try {
      await VlcSystemVolume.setPlayerShown(shown);
    } catch (error) {
      if (kDebugMode) debugPrint('system volume player toggle failed: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _settling?.cancel();
    _subscription?.cancel();
    _subscription = null;
    unawaited(_changes.close());
  }
}
