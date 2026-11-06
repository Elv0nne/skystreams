import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import 'vlc_player_value.dart';

/// How far the clock runs on past the engine's last report.
///
/// libVLC 3 reports its time at most every 250 ms, the desktop backends poll
/// it every 500 ms, and an adaptive stream moves it once a second. Past this
/// the engine is late rather than between reports - a stall it has not
/// announced yet - and lines running on over a frozen picture are worse than
/// lines that wait.
const Duration _kMaxRunOn = Duration(seconds: 1);

/// How far behind the clock a report can be and still be taken for a stale
/// or coarse one rather than for playback having gone back, in wall time:
/// the media it covers is this times the playback speed.
///
/// An adaptive stream's time is a staircase that runs up to a second behind
/// and wobbles back a few milliseconds more than thirty times a minute; the
/// event throttle and the threads in between add a little more. All of that
/// is wall time, so at 3x a report trails the clock by up to three seconds of
/// the media.
const Duration _kStaleBy = Duration(milliseconds: 1500);

/// How near the clock's run-on a report has to come to show the clock is not
/// ahead of playback, in wall time: the media it covers is this times the
/// playback speed. See [_kOffCourseFor].
///
/// An adaptive stream's steps land up to a quarter of a second either side
/// of one another, and a desktop poll can see a step up to half a second
/// late; measured on the recorded traces, nothing nearer than 250 ms keeps
/// every staircase on course.
const Duration _kOnCourseBy = Duration(milliseconds: 300);

/// How long every report that moved may trail the clock's run-on by more than
/// [_kOnCourseBy] before the clock takes the engine's word over its own run:
/// it has run ahead of playback - a stale report taken as fresh, a time that
/// went back with no seek, a freeze no report told it of - and its reading
/// holds there until playback catches up.
///
/// An adaptive stream steps up to where playback is about every 1.13 s, and a
/// desktop poll can see the step half a second late, so a shorter wait takes
/// a staircase for a clock running ahead.
const Duration _kOffCourseFor = Duration(seconds: 2);

/// Where playback is at this moment, read between the engine's reports.
///
/// [VlcPlayerValue.position] is the engine's last word, and the engine speaks
/// seldom: libVLC 3 updates its time at most every 250 ms and not at all while
/// paused, the desktop backends poll it twice a second, an adaptive stream's
/// time is a one-second staircase running up to a second behind, and VLCKit's
/// cached time does not move on a seek. Subtitle lines, or anything else drawn
/// against the picture, need the time in between. This clock runs on from the
/// freshest report at the playback speed while playing, and:
///
/// * never moves back, except where the controller says playback went back -
///   a seek, new media, the engine stopping or failing - or two reports in a
///   row agree that it did;
/// * jumps to a seek's target the moment it is asked for, as a scrubber does,
///   and waits there until the engine arrives;
/// * takes a report less than a second and a half of playing behind it - at
///   the playback speed - for a stale or coarse one and carries on, unless
///   every report for two seconds has trailed it by more than 300 ms of
///   playing: then it has run ahead of playback, and holds where it is until
///   playback catches up;
/// * counts only time spent playing, at the speed it was played at;
/// * runs on at most a second past the engine's last report, and holds there
///   until the engine catches up.
///
/// Listeners are told when the clock changes course - a report, a seek, a
/// pause - not as it runs: read [position] when it is needed, and ask
/// [timeUntil] when to read it next.
abstract interface class VlcPlaybackClock implements Listenable {
  /// Where playback is now.
  Duration get position;

  /// How long from now until [position] reads [target]: zero when it already
  /// has, and null when it will not get there without word from the engine -
  /// paused, waiting for a seek to land, or held a second past the last
  /// report.
  Duration? timeUntil(Duration target);
}

/// [VlcPlaybackClock] as the controller drives it: every native snapshot, and
/// the seeks and media changes that only the controller knows about.
@internal
class PlaybackClock extends ChangeNotifier implements VlcPlaybackClock {
  PlaybackClock() : _elapsed = _timeSource();

  final Duration Function() _elapsed;

  /// The lowest the clock may read until the next discontinuity: what has
  /// been shown already.
  Duration _floor = Duration.zero;

  /// The report the clock runs on from, and when it came.
  Duration _anchor = Duration.zero;
  Duration _anchorAt = Duration.zero;

  /// When the engine last showed it was alive - a report that moved, or the
  /// clock starting afresh. The run-on stops [_kMaxRunOn] after it.
  Duration _aliveAt = Duration.zero;

  /// Whether [_anchor] is the clock's own guess - after a start, a resume, a
  /// seek landing, a speed change or a stall - which the next report that
  /// moves replaces even from behind.
  bool _guessing = true;

  /// When a report that moved last came within [_kOnCourseBy] of where the
  /// clock had run on to, or the clock last took a report or started afresh.
  Duration _onCourseAt = Duration.zero;

  bool _running = false;
  double _speed = 1;

  /// Waiting at a seek's target for the engine to get there.
  bool _seeking = false;

  /// How many reports in a row have been more than [_kStaleBy] behind.
  int _behind = 0;

  /// The last snapshot, which is where a seek the controller stops waiting
  /// for leaves the clock.
  VlcPlayerValue? _last;

  @override
  Duration get position => _readingAt(_elapsed());

  @override
  Duration? timeUntil(Duration target) {
    final now = _elapsed();
    if (target <= _readingAt(now)) return Duration.zero;
    if (!_running) return null;
    final reachedAt = _anchorAt + (target - _anchor) * (1 / _speed);
    if (reachedAt > _aliveAt + _kMaxRunOn) return null;
    return reachedAt - now;
  }

  Duration _readingAt(Duration now) {
    var at = _anchor;
    if (_running) {
      final until = now < _aliveAt + _kMaxRunOn ? now : _aliveAt + _kMaxRunOn;
      final run = until - _anchorAt;
      if (run > Duration.zero) at += run * _speed;
    }
    return at < _floor ? _floor : at;
  }

  /// Takes a native snapshot. [seekSettled] says whether it ends the wait at
  /// a seek's target: the engine has arrived there, or never will.
  void report(VlcPlayerValue snapshot, {required bool seekSettled}) {
    final now = _elapsed();
    final course = _course;
    final position = snapshot.position;
    final moved = position != _last?.position;
    final playing = _isRunning(snapshot);
    _last = snapshot;
    if (_seeking) {
      // Still on its way: the target stands, whatever the engine says about
      // where it was.
      if (!seekSettled) return;
      _seeking = false;
      _startAt(position, now, playing: playing, speed: snapshot.playbackSpeed);
    } else if (_takenAsSaid(snapshot.state)) {
      _startAt(position, now, playing: false, speed: snapshot.playbackSpeed);
    } else {
      final reading = _readingAt(now);
      if (playing != _running || snapshot.playbackSpeed != _speed) {
        // A start, a pause, a resume or a new speed. Only time spent playing
        // counts, at the speed it was played at, so the clock starts afresh:
        // from where the engine says if that is further on, but as a guess,
        // since the position a state change carries is not a time update.
        final from = moved && position > reading ? position : reading;
        _startAt(from, now, playing: playing, speed: snapshot.playbackSpeed);
      } else if (moved) {
        if (playing) {
          _take(position, now);
        } else if (position > reading) {
          // Paused, and the engine has moved on: a step it took, or a report
          // fresher than the one the pause came with.
          _startAt(position, now, playing: false, speed: _speed);
        }
      }
    }
    if (_course != course) notifyListeners();
  }

  /// A report that moved, while playing.
  void _take(Duration position, Duration now) {
    final reading = _readingAt(now);
    if (reading - position > _kStaleBy * _speed) {
      // Further back than a stale or coarse report goes. Once may still be
      // stale - an adaptive stream sent one 6.9 s behind straight after a
      // seek - so it takes two in a row.
      _behind += 1;
      if (_behind >= 2) {
        _startAt(position, now, playing: true, speed: _speed);
      }
    } else {
      _behind = 0;
      final ranOut = now > _aliveAt + _kMaxRunOn;
      final runsTo = _anchor + (now - _anchorAt) * _speed;
      if (position >= runsTo - _kOnCourseBy * _speed) _onCourseAt = now;
      // The freshest report is the one that runs on furthest. One behind it
      // replaces it only when the clock was guessing, or has stood at the end
      // of its run-on: then it is the engine's word against none. Or when
      // every report has trailed the run-on for a while: then the run-on is
      // ahead of playback, and the engine's word is the better one.
      if (_guessing ||
          ranOut ||
          position >= runsTo ||
          now - _onCourseAt > _kOffCourseFor) {
        _floor = reading;
        _anchor = position;
        _anchorAt = now;
        _onCourseAt = now;
        _guessing = false;
      }
    }
    _aliveAt = now;
  }

  /// A seek was asked for: the clock goes to [target] at once and waits
  /// there until a snapshot settles it.
  void seek(Duration target) {
    _seeking = true;
    _startAt(target, _elapsed(), playing: false, speed: _speed);
    notifyListeners();
  }

  /// The controller has stopped waiting for a seek - the engine took it, will
  /// not, or the media went away - so the clock takes the engine's last word,
  /// speed included: a change of speed during the wait reached only [_last].
  void endSeek() {
    if (!_seeking) return;
    _seeking = false;
    final last = _last;
    _startAt(
      last?.position ?? _anchor,
      _elapsed(),
      playing: last != null && _isRunning(last),
      speed: last?.playbackSpeed ?? _speed,
    );
    notifyListeners();
  }

  /// New media, which starts at [position]: nothing the engine said about the
  /// last one applies.
  void restart(Duration position) {
    _seeking = false;
    _last = null;
    _startAt(position, _elapsed(), playing: false, speed: _speed);
    notifyListeners();
  }

  /// Starts the clock afresh at [position], which may be behind it: the
  /// shown position goes there too.
  void _startAt(
    Duration position,
    Duration now, {
    required bool playing,
    required double speed,
  }) {
    _floor = position;
    _anchor = position;
    _anchorAt = now;
    _aliveAt = now;
    _onCourseAt = now;
    _guessing = true;
    _behind = 0;
    _running = playing && !_seeking;
    _speed = speed;
  }

  /// Everything a reading or [timeUntil] depends on, to tell listeners only
  /// when one of them changes.
  Object get _course =>
      (_floor, _anchor, _anchorAt, _aliveAt, _running, _speed, _seeking);

  static bool _isRunning(VlcPlayerValue value) =>
      value.isPlaying && value.playbackSpeed > 0;

  /// The states in which the engine's position is the whole story: it has
  /// stopped or failed, and nothing runs on from there.
  ///
  /// Opening is not one: VLCKit reports an elementary stream appearing on a
  /// paused player as opening, with its cached time, which a seek it never
  /// reported has left behind.
  static bool _takenAsSaid(VlcPlaybackState state) =>
      state == VlcPlaybackState.stopped ||
      state == VlcPlaybackState.idle ||
      state == VlcPlaybackState.error;
}

/// Time since an arbitrary start, for the clock's run-on.
///
/// A [Stopwatch] in an app, so a change to the wall clock never moves a
/// subtitle. A fake [clock] in the zone the controller is built in - as a
/// widget test's body has - takes its place, so the test's pumps drive this
/// clock too.
Duration Function() _timeSource() {
  final zoneClock = clock;
  final stopwatch = identical(zoneClock, const Clock())
      ? Stopwatch()
      : zoneClock.stopwatch();
  stopwatch.start();
  return () => stopwatch.elapsed;
}
