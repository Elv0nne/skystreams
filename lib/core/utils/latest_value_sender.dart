import 'package:flutter/foundation.dart';

/// Sends values to the platform one call at a time, newest first.
///
/// A finger on a rail or a held key asks for a new level many times a second.
/// Each is a platform call, and calls that come faster than the platform
/// answers would queue up behind each other, so the level would trail the
/// finger and go on changing after it stopped. Here one call is in flight, a
/// value sent meanwhile waits and replaces any value already waiting, and the
/// last value always lands. Values go in the order sent, so a value meaning
/// "reset" can ride the same queue and never be overtaken by an older one.
class LatestValueSender<T> {
  LatestValueSender(this._send, {this.onIdle});

  final Future<void> Function(T value) _send;

  /// Called each time the queue drains: the last call has completed and nothing
  /// waits.
  final VoidCallback? onIdle;

  bool _busy = false;
  bool _waiting = false;
  late T _next;

  /// Whether a call is in flight.
  bool get busy => _busy;

  /// Sends [value] now if nothing is in flight, else once the call in flight
  /// completes, in place of any value already waiting.
  void send(T value) {
    _next = value;
    _waiting = true;
    if (!_busy) _drain();
  }

  Future<void> _drain() async {
    _busy = true;
    while (_waiting) {
      _waiting = false;
      try {
        await _send(_next);
      } catch (error) {
        // A refused call is the platform's to report; the next value still
        // goes.
        if (kDebugMode) debugPrint('LatestValueSender: call failed: $error');
      }
    }
    _busy = false;
    onIdle?.call();
  }
}
