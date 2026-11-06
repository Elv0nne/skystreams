/// Notices frames that stop coming while one is asked for. Every pump in a live test waits for a
/// frame, and on a Mac frames follow the display's refresh, which stops while the display sleeps
/// under a running app: a run sits idle until the display wakes (2026-10-06: two corpus runs, each
/// stalled to the second of the display's sleep). support.dart keeps the display awake; this says
/// so in the log when frames stop anyway.
class FrameWatch {
  FrameWatch(this._clock, {this.after = const Duration(seconds: 30)});

  final DateTime Function() _clock;

  /// How long a frame may be asked for without coming before [check] reports it.
  final Duration after;

  DateTime? _askedSince;
  bool _reported = false;

  /// A frame came. Returns the line to print when [check] had reported frames stopped.
  String? frame() {
    final since = _askedSince;
    final reported = _reported;
    _askedSince = null;
    _reported = false;
    if (!reported || since == null) return null;
    return 'CS3-FRAMES-BACK after ${_clock().difference(since).inSeconds} s';
  }

  /// Whether a frame is [asked] for now. Returns the line to print, once per stall, when one has been
  /// asked for [after] or longer and none has come.
  String? check({required bool asked}) {
    if (!asked) {
      _askedSince = null;
      return null;
    }
    final now = _clock();
    final since = _askedSince ??= now;
    if (_reported || now.difference(since) < after) return null;
    _reported = true;
    return 'CS3-NO-FRAMES for ${now.difference(since).inSeconds} s since ${_time(since)}: a frame was asked for '
        'and none came. On a Mac the display may be asleep, which stops a running app\'s frames until it wakes.';
  }

  static String _time(DateTime t) => t.toIso8601String().substring(11, 19);
}
