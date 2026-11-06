import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// On Linux, routes wakelock_plus through [OneInhibitorWakelock]. Called before anything keeps the screen awake:
/// wakelock_plus takes its platform instance on first use.
void installLinuxWakelock({@visibleForTesting bool? linux}) {
  if (!(linux ?? Platform.isLinux)) return;
  WakelockPlusPlatformInterface.instance = OneInhibitorWakelock(WakelockPlusPlatformInterface.instance);
}

/// wakelock_plus without its Linux leak. There, each enable opens a new portal inhibitor and keeps only the newest,
/// and a disable closes that one: an enable while one was held (the player as playback went on, a full-screen game
/// back from the background) left the first open, and the screen never slept again until SkyStream quit. Here calls
/// run one at a time, and one asking for what already holds does nothing. macOS and Windows already ignore a repeated
/// enable.
class OneInhibitorWakelock extends WakelockPlusPlatformInterface {
  OneInhibitorWakelock(this.inner);

  /// The platform's own implementation.
  final WakelockPlusPlatformInterface inner;

  Future<void> _last = Future.value();

  @override
  Future<void> toggle({required bool enable}) {
    final call = _last.then((_) async {
      if (await inner.enabled == enable) return;
      await inner.toggle(enable: enable);
    });
    // A call that failed reaches its caller, and doesn't hold up the next.
    _last = call.catchError((Object _) {});
    return call;
  }

  @override
  Future<bool> get enabled => _last.then((_) => inner.enabled);
}
