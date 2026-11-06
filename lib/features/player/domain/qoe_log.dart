/// What one playback session did, in the order it did it: the record the
/// QoE suite reads and the developer option writes to the app log.
///
/// Times are milliseconds since the player screen opened, from a monotonic
/// stopwatch, so a clock change mid-session can't bend them. Addresses are
/// reduced to their host: signed links carry tokens in the path and query, and
/// the app log is exported verbatim with bug reports.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Every kind of event the screen records.
enum QoeEventKind {
  open,
  buffer,
  engine,
  firstFrame,
  stall,
  stallEnd,
  seek,
  seekDone,
  track,
  reopen,
  failover,
  error,
  memory,
  end,

  /// Recovery waiting over the picture, and its end (spec 7.1).
  wait,
  waitEnd,

  /// What a recovery check of a source's server found.
  check,

  /// Recovery gave up: the failed screen.
  gaveUp,

  /// A torrent server's start: what it did to the buffer settings.
  torrent,
}

/// One event: what happened, when, and what it carries.
@immutable
class QoeEvent {
  const QoeEvent(this.kind, this.atMs, this.fields);

  final QoeEventKind kind;
  final int atMs;
  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => <String, Object?>{
    'event': kind.name,
    'atMs': atMs,
    ...fields,
  };
}

/// The log of one player screen.
class QoeLog {
  QoeLog({int Function()? nowMs, void Function(String line)? sink})
    : _sink = sink {
    if (nowMs != null) {
      _nowMs = nowMs;
    } else {
      final watch = Stopwatch()..start();
      _nowMs = () => watch.elapsedMilliseconds;
    }
    latest = this;
  }

  /// Whether events also go to the app log, as one `QOE {json}` line each.
  /// Set by the developer option, and read on every event.
  static bool writeToAppLog = false;

  /// The newest log, for the device suite: it runs in the app's process and
  /// reads the session the screen it opened recorded.
  @visibleForTesting
  static QoeLog? latest;

  /// How many events a session keeps. A long session drops its oldest; the
  /// suite's scenarios stay far below this.
  static const int capacity = 200;

  late final int Function() _nowMs;
  final void Function(String line)? _sink;
  final Queue<QoeEvent> _events = Queue<QoeEvent>();

  int? _engineAt;
  int? _waitAt;
  int _waits = 0;
  int _waitedMs = 0;
  int? _firstFrameAt;
  int? _stallAt;
  int? _seekAt;
  int _stalls = 0;
  int _stalledMs = 0;

  List<QoeEvent> get events => List<QoeEvent>.unmodifiable(_events);

  /// The host of [url], or empty when it has none.
  static String hostOf(String url) => Uri.tryParse(url)?.host ?? '';

  /// A media opening. [keptPicture] when the last picture stays on screen
  /// through it (spec 2, *The reopen*): only then is the field written.
  void open({
    required int sourceIndex,
    required String kind,
    required String url,
    required int startAtMs,
    required String reason,
    bool keptPicture = false,
  }) => _record(QoeEventKind.open, <String, Object?>{
    'sourceIndex': sourceIndex,
    'kind': kind,
    'host': hostOf(url),
    'startAtMs': startAtMs,
    'reason': reason,
    if (keptPicture) 'keptPicture': true,
  });

  /// The buffer rule's answer for the media about to open.
  void buffer(Map<String, Object?> plan) => _record(QoeEventKind.buffer, plan);

  void engine() {
    _engineAt = _nowMs();
    _record(QoeEventKind.engine, const <String, Object?>{}, at: _engineAt);
  }

  /// The first frame showed. [surfaceWaitMs] is how long the engine held
  /// playback back for its video surface, when it had to (Android).
  void firstFrame({int? surfaceWaitMs}) {
    final at = _nowMs();
    _firstFrameAt ??= at;
    final engineAt = _engineAt ?? 0;
    _record(QoeEventKind.firstFrame, <String, Object?>{
      'appMs': engineAt,
      'engineMs': at - engineAt,
      'surfaceWaitMs': ?surfaceWaitMs,
    }, at: at);
  }

  /// The clock stood still while playback was expected. [prebuffer] is
  /// libVLC's buffer fill at that moment, 0..1, where the engine reports one:
  /// the spinner never shows it, so this is where it is kept (spec 4).
  void stall(int positionMs, {double? prebuffer}) {
    _stallAt = _nowMs();
    _stalls += 1;
    _record(QoeEventKind.stall, <String, Object?>{
      'positionMs': positionMs,
      if (prebuffer != null) 'prebufferPct': (prebuffer * 100).round(),
    }, at: _stallAt);
  }

  void stallEnd() {
    final at = _nowMs();
    final since = _stallAt;
    _stallAt = null;
    final ms = since == null ? 0 : at - since;
    _stalledMs += ms;
    _record(QoeEventKind.stallEnd, <String, Object?>{'ms': ms}, at: at);
  }

  void seek({required int fromMs, required int toMs}) {
    _seekAt = _nowMs();
    _record(QoeEventKind.seek, <String, Object?>{
      'fromMs': fromMs,
      'toMs': toMs,
    }, at: _seekAt);
  }

  void seekDone() {
    final at = _nowMs();
    final since = _seekAt;
    _seekAt = null;
    _record(QoeEventKind.seekDone, <String, Object?>{
      'ms': since == null ? 0 : at - since,
    }, at: at);
  }

  void track({required String kind, required int id}) =>
      _record(QoeEventKind.track, <String, Object?>{'kind': kind, 'id': id});

  void reopen({
    required String reason,
    required int positionMs,
    bool keptPicture = false,
  }) => _record(QoeEventKind.reopen, <String, Object?>{
    'reason': reason,
    'positionMs': positionMs,
    if (keptPicture) 'keptPicture': true,
  });

  void failover({required int from, required int to, required String reason}) =>
      _record(QoeEventKind.failover, <String, Object?>{
        'from': from,
        'to': to,
        'reason': reason,
      });

  /// Something failed. [sign] is the recovery policy's name for how it was
  /// noticed, when it was.
  void error(String detail, {String? sign, Map<String, Object?>? torrent}) =>
      _record(QoeEventKind.error, <String, Object?>{
        'detail': detail,
        'sign': ?sign,
        'torrent': ?torrent,
      });

  /// Recovery is waiting over the picture: [label] is `reconnecting` or
  /// `waitingForNetwork`.
  void wait({required String label, required int positionMs}) {
    _waitAt ??= _nowMs();
    _waits += 1;
    _record(QoeEventKind.wait, <String, Object?>{
      'label': label,
      'positionMs': positionMs,
    }, at: _waitAt);
  }

  /// The wait is over. Nothing when none is open.
  void waitEnd() {
    final since = _waitAt;
    if (since == null) return;
    _waitAt = null;
    final at = _nowMs();
    _waitedMs += at - since;
    _record(QoeEventKind.waitEnd, <String, Object?>{'ms': at - since}, at: at);
  }

  /// What a recovery check found: [kind] is the check's class, with the
  /// server's [status] or the [fault] when there was no answer.
  void check({
    required int sourceIndex,
    required String kind,
    int? status,
    String? fault,
    required int ms,
  }) => _record(QoeEventKind.check, <String, Object?>{
    'sourceIndex': sourceIndex,
    'kind': kind,
    'status': ?status,
    'fault': ?fault,
    'ms': ms,
  });

  /// What the torrent server's start did to its buffer settings (the
  /// service's `TorrentSettings.toJson`), or `serverUp` when it was already
  /// running for an earlier torrent.
  void torrent(Map<String, Object?>? settings) => _record(
    QoeEventKind.torrent,
    settings ?? const <String, Object?>{'settings': 'serverUp'},
  );

  /// Recovery gave up, for [cause]: no source left, or the session cap.
  void gaveUp({required String cause}) =>
      _record(QoeEventKind.gaveUp, <String, Object?>{'cause': cause});

  void memory(int residentMb) =>
      _record(QoeEventKind.memory, <String, Object?>{'residentMb': residentMb});

  void end(String why) {
    final at = _nowMs();
    final openStall = _stallAt;
    final stalledMs = _stalledMs + (openStall == null ? 0 : at - openStall);
    final openWait = _waitAt;
    final first = _firstFrameAt;
    _record(QoeEventKind.end, <String, Object?>{
      'why': why,
      'playedMs': first == null ? 0 : at - first,
      'stalls': _stalls,
      'stalledMs': stalledMs,
      if (_waits > 0) 'waits': _waits,
      if (_waits > 0)
        'waitedMs': _waitedMs + (openWait == null ? 0 : at - openWait),
    }, at: at);
  }

  void _record(QoeEventKind kind, Map<String, Object?> fields, {int? at}) {
    final event = QoeEvent(kind, at ?? _nowMs(), fields);
    _events.addLast(event);
    while (_events.length > capacity) {
      _events.removeFirst();
    }
    final sink = _sink;
    if (writeToAppLog && sink != null) {
      sink('QOE ${jsonEncode(event.toJson())}');
    }
  }
}
