/// When to tell a provider how far the viewer has got.
///
/// The same rules CloudStream's player applies before it calls
/// `WatchProgressListener.onWatchProgress`: a site that credits real watch time wants an update every
/// ~15 s while the episode plays, one right away for a new episode, and one as soon as the episode is
/// nearly over - the last one must not wait out the interval, or an episode watched to the end can
/// stop short of the share of it the site wants for its points.
class WatchProgressReporter {
  WatchProgressReporter({
    this.interval = const Duration(seconds: 15),
    this.nearEndFraction = 0.95,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration interval;
  final double nearEndFraction;
  final DateTime Function() _clock;

  String? _lastData;
  DateTime? _lastAt;
  String? _nearEndSentFor;

  /// Whether to report now. Calling it with `true` counts as having reported: [data] identifies the
  /// episode, [position] and [duration] are where playback is.
  bool shouldReport(String data, Duration position, Duration duration) {
    if (duration <= Duration.zero) return false;
    final now = _clock();
    final isNew = _lastData != data;
    if (isNew) _nearEndSentFor = null;

    final isNearEnd =
        position.inMilliseconds / duration.inMilliseconds >= nearEndFraction &&
        _nearEndSentFor != data;
    final due = _lastAt == null || now.difference(_lastAt!) >= interval;
    if (!isNew && !isNearEnd && !due) return false;

    _lastData = data;
    _lastAt = now;
    if (isNearEnd) _nearEndSentFor = data;
    return true;
  }

  /// A new playback session (another episode, or the same one reopened).
  void reset() {
    _lastData = null;
    _lastAt = null;
    _nearEndSentFor = null;
  }
}
