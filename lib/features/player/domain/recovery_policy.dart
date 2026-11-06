/// The recovery policy: what to do when playback fails, and when (spec 2,
/// *What happens next*).
///
/// Pure. It reads the time from `package:clock`, so a test moves it, and it
/// owns no timers. The screen tells it facts (a resolve's candidates, a probe,
/// an open, a picture, progress) and events (a failure with the sign that
/// noticed it, a check's answer, connectivity, the app's visibility, and the
/// time it asked to be woken at). It answers each event with one
/// [RecoveryStep], and [RecoveryPolicy.nextDue] says when it next wants
/// [RecoveryPolicy.due].
///
/// Where a reopen starts is not its business: the screen knows where playback
/// is going (`pendingSeekTarget ?? last played position`, spec 2, *The
/// reopen*).
library;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show immutable;

import 'playback_recovery.dart' show firstReachableIndex, nextFailoverIndex;
import 'source_check.dart';
import 'stream_resolver.dart' show ProbeOutcome;

/// How a failure was noticed (spec 2, *Detection*).
enum FailureSign {
  /// libVLC said error.
  engineError,

  /// libVLC said ended more than 2 s short of the length, or with no length.
  falseEnd,

  /// Paused, and nobody asked.
  pausedUnasked,

  /// Stopped, and nobody asked.
  stoppedUnasked,

  /// The stall ladder's recover rung.
  stalled,

  /// The clock ran on with no new picture decoded (adaptive media).
  videoStarved,

  /// No picture reached the screen while the clock ran (`VideoHealth.absent`):
  /// there is no picture to keep.
  noPicture,

  /// The first-frame verdict gave the attempt up.
  neverStarted,

  /// The check while opening found the source unreachable, before its first
  /// picture.
  unreachableWhileOpening,

  /// DRM, no playable address, a torrent that could not be prepared: today's
  /// rules, a failover with no check.
  unplayable,
}

/// What the screen shows over the picture while recovery is under way.
enum RecoveryLabel { none, reconnecting, waitingForNetwork }

/// Where recovery is.
enum RecoveryPhase {
  /// Nothing is wrong, or a reopen recovery asked for is opening.
  watching,

  /// The failed source's check is out.
  checking,

  /// No answer, or no network: waiting, and checking on a schedule.
  waiting,

  /// A reopen, a failover or a busy server's next check is due at a time.
  scheduled,

  /// Recovery gave up: the failed screen, until a reset or a new resolve.
  gaveUp,
}

/// Why recovery gave up.
enum GiveUpCause { noSourceLeft, sessionCap }

/// One candidate, as recovery sees it.
@immutable
class RecoveryCandidate {
  const RecoveryCandidate({required this.authority, this.checkable = true});

  /// `Uri.authority`, host and port: the "host" of the network-or-host rule.
  /// Two ports are two hosts.
  final String authority;

  /// False for torrents and local files, which no check can reach.
  final bool checkable;
}

/// What the screen does next.
sealed class RecoveryStep {
  const RecoveryStep();
}

/// Nothing now; [RecoveryPolicy.nextDue] says when to ask again.
final class Carry extends RecoveryStep {
  const Carry();
}

/// Check [source]'s server, and report with [RecoveryPolicy.checked].
final class RunCheck extends RecoveryStep {
  const RunCheck(this.source);

  final int source;
}

/// Open [source] again, at the screen's target, with the start-up view kept
/// down. [keepPicture] is false when the failure was the picture itself.
final class ReopenSource extends RecoveryStep {
  const ReopenSource(
    this.source, {
    required this.live,
    required this.keepPicture,
  });

  final int source;

  /// A live reconnect, which opens at the live start.
  final bool live;

  final bool keepPicture;
}

/// Open [source] instead, with the start-up view naming it (spec 2, *Decisions
/// taken* 6). [detail] is why the last one was given up. [revert] when it goes
/// back to the source a trial pick interrupted.
final class FailOverTo extends RecoveryStep {
  const FailOverTo(this.source, {required this.detail, this.revert = false});

  final int source;
  final String detail;
  final bool revert;
}

/// Wait over the picture, saying [label]. A dead source is parked meanwhile
/// (the screen's business).
final class WaitHere extends RecoveryStep {
  const WaitHere(this.label);

  final RecoveryLabel label;
}

/// Give up: the failed screen, with [detail]. It still offers Retry.
final class GiveUp extends RecoveryStep {
  const GiveUp(this.cause, {required this.detail});

  final GiveUpCause cause;
  final String detail;
}

/// The spec's numbers (section 2), in one place.
@immutable
class RecoveryLimits {
  const RecoveryLimits({
    this.backoff = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ],
    this.liveReconnects = 5,
    this.liveReconnectDelay = const Duration(seconds: 2),
    this.healthyPlayback = const Duration(seconds: 30),
    this.healthyStepCap = const Duration(seconds: 2),
    this.sessionReopens = 20,
    this.fastChecks = const Duration(seconds: 2),
    this.fastChecksFor = const Duration(minutes: 5),
    this.slowChecks = const Duration(seconds: 10),
    this.hostDownAfter = const Duration(seconds: 30),
    this.witnessEvery = const Duration(seconds: 10),
    this.retryAfterCap = const Duration(seconds: 30),
    this.neverPlayedWait = const Duration(seconds: 30),
    this.offlineChecks = const Duration(seconds: 10),
  });

  /// "Reopen the same source, 1, 2, 4 and 8 s apart. Then fail over." A busy
  /// server's schedule too.
  final List<Duration> backoff;

  /// "Today's 5 reconnects, 2 s apart".
  final int liveReconnects;
  final Duration liveReconnectDelay;

  /// "the attempt budget resets after 30 s of healthy playback".
  final Duration healthyPlayback;

  /// The most one report of progress adds to healthy playback: a stall, a
  /// pause or a clock jump between two reports counts no more than this.
  final Duration healthyStepCap;

  /// "A session cap of 20 reopens".
  final int sessionReopens;

  /// "Check again every 2 s for five minutes, then every 10 s."
  final Duration fastChecks;
  final Duration fastChecksFor;
  final Duration slowChecks;

  /// "The same for 30 s, while another source's host answers: fail over."
  final Duration hostDownAfter;

  /// How often the other host is checked during a wait.
  final Duration witnessEvery;

  /// The longest `Retry-After` honoured; a longer one fails over at once (the
  /// plan's decision 7).
  final Duration retryAfterCap;

  /// How long a source that never played waits on what looks like our
  /// network (the plan's decision 6).
  final Duration neverPlayedWait;

  /// How often a wait checks while the device says it is offline, in case a
  /// connectivity event is missed (the plan's decision 9).
  final Duration offlineChecks;
}

/// Decides what recovery does, one step at a time.
class RecoveryPolicy {
  RecoveryPolicy({
    this.limits = const RecoveryLimits(),
    bool Function()? resuming,
  }) : _resuming = resuming ?? _fromTheStart;

  static bool _fromTheStart() => false;

  final RecoveryLimits limits;

  /// Whether a reopen picks playback up past its start: a failover then walks
  /// sources whose servers ignore byte ranges after the rest.
  final bool Function() _resuming;

  // The resolve: each candidate's host, what the race found, the sources that
  // showed a picture, the ones that failed for good, and the failover walk.
  List<RecoveryCandidate> _candidates = const <RecoveryCandidate>[];
  final Map<int, ProbeOutcome> _probes = <int, ProbeOutcome>{};
  final Set<int> _played = <int>{};
  final Set<int> _failed = <int>{};
  final Set<int> _tried = <int>{};

  /// Same-source reopens and busy checks since the last healthy stretch.
  int _retries = 0;
  int _liveReconnects = 0;

  /// Reopens and failovers recovery has asked for, toward the session cap.
  int _reopens = 0;

  /// The source a trial pick interrupted, until the pick has played healthily.
  int? _revertTo;

  bool _online = true;
  bool _visible = true;

  // The attempt.
  int _current = -1;
  bool _live = false;
  bool _attemptPictured = false;
  bool _failureHandled = false;
  Duration _healthy = Duration.zero;
  DateTime? _lastMoveAt;

  RecoveryPhase _phase = RecoveryPhase.watching;
  _Recovery? _recovery;

  RecoveryPhase get phase => _phase;

  /// The source the last attempt opened.
  int get current => _current;

  /// Reopens and failovers recovery has asked for since the last reset.
  int get reopens => _reopens;

  bool hasPlayed(int source) => _played.contains(source);

  bool isFailed(int source) => _failed.contains(source);

  /// What the screen says over the picture: "Waiting for network…" while the
  /// device is offline, "Reconnecting…" while a source that played recovers,
  /// and nothing for one that never played - the start-up view says that.
  RecoveryLabel get label {
    if (_recovery == null) return RecoveryLabel.none;
    if (!_online && _checkable(_current)) {
      return RecoveryLabel.waitingForNetwork;
    }
    return _played.contains(_current)
        ? RecoveryLabel.reconnecting
        : RecoveryLabel.none;
  }

  /// When [due] next has something to do, or null when nothing is scheduled.
  /// A check still out is never due again until it answers.
  DateTime? get nextDue {
    final recovery = _recovery;
    if (recovery == null || recovery.heldWhileHidden || !_visible) return null;
    var soonest = recovery.scheduledAt;
    DateTime? sooner(DateTime? a, DateTime? b) =>
        a == null ? b : (b == null || a.isBefore(b) ? a : b);
    if (_phase == RecoveryPhase.waiting) {
      if (!recovery.inFlight.containsKey(_current)) {
        soonest = sooner(soonest, recovery.nextCheckAt);
      }
      final witness = _online ? _witness() : null;
      if (witness != null && !recovery.inFlight.containsKey(witness)) {
        soonest = sooner(soonest, recovery.nextWitnessAt);
      }
    }
    return soonest;
  }

  /// A new resolve: everything learned about the last one goes.
  void candidatesChanged(List<RecoveryCandidate> candidates) {
    _candidates = List<RecoveryCandidate>.unmodifiable(candidates);
    _probes.clear();
    _played.clear();
    _failed.clear();
    _current = -1;
    reset();
  }

  /// What the race's probe found for [source].
  void probed(int source, ProbeOutcome outcome) => _probes[source] = outcome;

  /// An attempt began on [source]. [revertTo] is the source a trial pick
  /// interrupted. An open ends any recovery: the step that asked for it has
  /// been acted on, or the viewer chose something else.
  void opened({required int source, required bool live, int? revertTo}) {
    if (source != _current) {
      // Another source gets the whole schedule: the budgets are a source's.
      _retries = 0;
      _liveReconnects = 0;
    }
    _current = source;
    _live = live;
    _tried.add(source);
    if (revertTo != null) _revertTo = revertTo;
    _attemptPictured = false;
    _failureHandled = false;
    _healthy = Duration.zero;
    _lastMoveAt = null;
    _endRecovery();
  }

  /// The attempt showed its first picture: its source has played, for every
  /// decision from here (row 7 asks it of the source, not the attempt).
  void pictured() {
    if (_current < 0) return;
    _attemptPictured = true;
    _played.add(_current);
  }

  /// The position advanced.
  void moved() {
    final now = clock.now();
    final last = _lastMoveAt;
    _lastMoveAt = now;
    final recovery = _recovery;
    if (recovery != null) {
      // libVLC rode a stall out by itself: nothing to reopen, and the attempt
      // can fail again. Under a missing or starved picture the sound carries
      // the clock on, so movement says nothing there.
      if (recovery.sign == FailureSign.stalled) {
        _endRecovery();
        _failureHandled = false;
      }
      return;
    }
    if (last == null) return;
    final step = now.difference(last);
    if (step <= Duration.zero) return;
    _healthy += step < limits.healthyStepCap ? step : limits.healthyStepCap;
    if (_healthy < limits.healthyPlayback) return;
    // A real stretch of playback has earned the budgets back. Not the first
    // picture: a source that plays three seconds after every reopen would
    // otherwise refill them for ever and never fail over.
    _retries = 0;
    _liveReconnects = 0;
    _revertTo = null;
    _tried
      ..clear()
      ..add(_current);
  }

  /// Retry, a new episode, a hand pick not on trial, a torrent file pick: the
  /// budgets, the walk and the session cap start again.
  void reset() {
    _retries = 0;
    _liveReconnects = 0;
    _reopens = 0;
    _revertTo = null;
    _tried.clear();
    _failureHandled = false;
    _endRecovery();
  }

  /// The attempt failed, noticed by [sign]; [detail] is the message the
  /// viewer sees if it comes to a failover or the failed screen.
  RecoveryStep failed(FailureSign sign, {required String detail}) {
    if (_failureHandled || _phase == RecoveryPhase.gaveUp || _current < 0) {
      // One failure per attempt: Android's stop after its error, a stall
      // reported over an error already handled.
      return const Carry();
    }
    _failureHandled = true;
    final recovery = _recovery = _Recovery(sign, detail);
    if (!_visible) {
      // Off screen nothing is checked or reopened (spec 2, *Background*).
      recovery.heldWhileHidden = true;
      _phase = RecoveryPhase.waiting;
      return const Carry();
    }
    return _classify(recovery);
  }

  /// What the check of [source] found.
  RecoveryStep checked(int source, CheckResult result) {
    final recovery = _recovery;
    final began = recovery?.inFlight.remove(source);
    if (recovery == null || began == null) return const Carry();
    final now = clock.now();
    if (source != _current) return _witnessAnswered(recovery, result, now);
    if (recovery.heldWhileHidden || !_visible) {
      // Answered after the app went away: checked again on its return.
      recovery.heldWhileHidden = true;
      return const Carry();
    }
    switch (result.kind) {
      case CheckClass.answers:
        // An answer proves the network, whatever the last event said.
        _online = true;
        return _answered(recovery);
      case CheckClass.network:
        if (!_online) {
          recovery.nextCheckAt = now.add(limits.offlineChecks);
          return const Carry();
        }
        return _noAnswer(recovery, began, now);
      case CheckClass.gone:
        return _failOver(recovery.detail);
      case CheckClass.busy:
        return _busy(recovery, result.retryAfter);
    }
  }

  /// The device's network, as connectivity reports it.
  RecoveryStep connectivity({required bool online}) {
    if (online == _online) return const Carry();
    _online = online;
    final recovery = _recovery;
    if (recovery == null || recovery.heldWhileHidden || !_visible) {
      return const Carry();
    }
    if (!_checkable(_current)) return const Carry();
    if (!online) return _waitForNetwork(recovery);
    // "Check at once when connectivity changes."
    recovery.noAnswerSince = null;
    recovery.ourNetworkSince = null;
    return _check(recovery, _current);
  }

  /// Whether the app is on screen. Picture-in-picture is on screen.
  RecoveryStep foreground({required bool visible}) {
    if (visible == _visible) return const Carry();
    _visible = visible;
    final recovery = _recovery;
    if (!visible || recovery == null) return const Carry();
    // "One runs as soon as it returns", whatever was scheduled while away.
    recovery
      ..heldWhileHidden = false
      ..scheduled = null
      ..scheduledAt = null;
    return _classify(recovery);
  }

  /// The screen's wake-up, at or after [nextDue].
  RecoveryStep due() {
    final recovery = _recovery;
    if (recovery == null || recovery.heldWhileHidden || !_visible) {
      return const Carry();
    }
    final now = clock.now();
    final at = recovery.scheduledAt;
    if (at != null && !now.isBefore(at)) {
      final step = recovery.scheduled!;
      recovery
        ..scheduled = null
        ..scheduledAt = null;
      if (step is RunCheck) return _check(recovery, step.source);
      return _issue(step, recovery.detail);
    }
    if (_phase != RecoveryPhase.waiting) return const Carry();
    final next = recovery.nextCheckAt;
    if (next != null && !now.isBefore(next)) {
      recovery.nextCheckAt = null;
      return _check(recovery, _current);
    }
    final witness = _online ? _witness() : null;
    final witnessAt = recovery.nextWitnessAt;
    if (witness != null && witnessAt != null && !now.isBefore(witnessAt)) {
      recovery.nextWitnessAt = null;
      return _check(recovery, witness);
    }
    return const Carry();
  }

  RecoveryStep _classify(_Recovery recovery) {
    if (recovery.sign == FailureSign.unreachableWhileOpening) {
      return _abandonUnreachable(recovery);
    }
    final revert = _revertTo;
    // A pick that will not play must cost the viewer nothing: back to the
    // session it interrupted rather than down the failover ladder.
    if (revert != null) return _revert(revert, recovery.detail);
    if (recovery.sign == FailureSign.unplayable) {
      return _failOver(recovery.detail);
    }
    if (!_checkable(_current)) return _ladderWithoutCheck(recovery);
    if (!_online) return _waitForNetwork(recovery);
    return _check(recovery, _current);
  }

  RecoveryStep _check(_Recovery recovery, int source) {
    if (recovery.inFlight.containsKey(source)) return const Carry();
    recovery.inFlight[source] = clock.now();
    if (source == _current) {
      recovery
        ..scheduled = null
        ..scheduledAt = null;
      if (_phase != RecoveryPhase.waiting) _phase = RecoveryPhase.checking;
    }
    return RunCheck(source);
  }

  /// The failed source's server answered.
  RecoveryStep _answered(_Recovery recovery) {
    if (!_played.contains(_current)) {
      // One that never played and answers is a dead candidate, not our
      // network: on to the next at once (row 7). One that answered after a
      // wait looked like our network, and the network is back: it opens again,
      // at once and behind the start-up view - there is no picture to keep
      // (rows 2 and 4). The session cap counts it.
      if (!recovery.waited) return _failOver(recovery.detail);
      return _reopenAfter(
        recovery,
        Duration.zero,
        live: _live,
        keepPicture: false,
      );
    }
    final keepPicture = recovery.sign != FailureSign.noPicture;
    if (recovery.waited) {
      // After a wait the reopen goes at once and uses no attempt: the wait
      // was the server's or the network's, not the source's (rows 2 and 4).
      // The session cap still counts it.
      return _reopenAfter(
        recovery,
        Duration.zero,
        live: _live,
        keepPicture: keepPicture,
      );
    }
    if (_live) {
      if (_liveReconnects >= limits.liveReconnects) {
        return _failOver(recovery.detail);
      }
      _liveReconnects += 1;
      return _reopenAfter(
        recovery,
        limits.liveReconnectDelay,
        live: true,
        keepPicture: keepPicture,
      );
    }
    if (_retries >= limits.backoff.length) return _failOver(recovery.detail);
    final wait = limits.backoff[_retries];
    _retries += 1;
    return _reopenAfter(recovery, wait, live: false, keepPicture: keepPicture);
  }

  /// The failed source's server didn't answer: a source that played waits,
  /// using no attempt, checking on the spec's schedule (row 2), and fails
  /// over only when another host answers through 30 s of this one's silence
  /// (row 3).
  RecoveryStep _noAnswer(_Recovery recovery, DateTime began, DateTime now) {
    recovery.waited = true;
    if (!_played.contains(_current)) return _neverPlayedNoAnswer(recovery, now);
    final since = recovery.noAnswerSince ??= now;
    final hostDown = _hostDown(recovery, now);
    if (hostDown != null) return hostDown;
    recovery.nextCheckAt = began.add(
      now.difference(since) < limits.fastChecksFor
          ? limits.fastChecks
          : limits.slowChecks,
    );
    if (_phase == RecoveryPhase.waiting) return const Carry();
    _phase = RecoveryPhase.waiting;
    if (_witness() != null) recovery.nextWitnessAt = now;
    return const WaitHere(RecoveryLabel.reconnecting);
  }

  /// A source that never played got no answer: another host answering means
  /// this one is down; with none to ask, or none answering, it looks like our
  /// network, and is waited on for a while (row 7, decision 6).
  RecoveryStep _neverPlayedNoAnswer(_Recovery recovery, DateTime now) {
    final witness = _witness();
    if (witness != null && recovery.witnessAnsweredAt != null) {
      return _hostIsDown(witness, recovery.detail);
    }
    _phase = RecoveryPhase.waiting;
    if (witness != null && !recovery.witnessChecked) {
      return _check(recovery, witness);
    }
    final since = recovery.ourNetworkSince ??= now;
    if (now.difference(since) >= limits.neverPlayedWait) {
      return _failOver(recovery.detail);
    }
    recovery.nextCheckAt = now.add(limits.fastChecks);
    if (witness != null) {
      recovery.nextWitnessAt ??= now.add(limits.witnessEvery);
    }
    return const Carry();
  }

  RecoveryStep _witnessAnswered(
    _Recovery recovery,
    CheckResult result,
    DateTime now,
  ) {
    recovery.witnessChecked = true;
    if (result.kind == CheckClass.answers) recovery.witnessAnsweredAt = now;
    recovery.nextWitnessAt = now.add(limits.witnessEvery);
    if (recovery.heldWhileHidden || !_visible) return const Carry();
    if (!_played.contains(_current)) return _neverPlayedNoAnswer(recovery, now);
    return _hostDown(recovery, now) ?? const Carry();
  }

  /// 30 s of no answer from this host while the other answered within them.
  RecoveryStep? _hostDown(_Recovery recovery, DateTime now) {
    final witness = _witness();
    final since = recovery.noAnswerSince;
    final answered = recovery.witnessAnsweredAt;
    if (witness == null || since == null || answered == null) return null;
    if (now.difference(since) < limits.hostDownAfter) return null;
    if (now.difference(answered) > limits.hostDownAfter) return null;
    return _hostIsDown(witness, recovery.detail);
  }

  RecoveryStep _hostIsDown(int witness, String detail) {
    _failed.add(_current);
    return _issue(FailOverTo(witness, detail: detail), detail);
  }

  RecoveryStep _busy(_Recovery recovery, Duration? retryAfter) {
    if (!_played.contains(_current)) return _failOver(recovery.detail);
    if (retryAfter != null && retryAfter > limits.retryAfterCap) {
      return _failOver(recovery.detail);
    }
    if (_retries >= limits.backoff.length) return _failOver(recovery.detail);
    var wait = limits.backoff[_retries];
    if (retryAfter != null && retryAfter > wait) wait = retryAfter;
    _retries += 1;
    // The answer after a busy one reopens at once.
    recovery.waited = true;
    _schedule(recovery, RunCheck(_current), wait);
    return const Carry();
  }

  RecoveryStep _waitForNetwork(_Recovery recovery) {
    recovery
      ..waited = true
      ..scheduled = null
      ..scheduledAt = null
      ..noAnswerSince = null
      ..ourNetworkSince = null
      ..nextWitnessAt = null
      ..nextCheckAt = clock.now().add(limits.offlineChecks);
    _phase = RecoveryPhase.waiting;
    return const WaitHere(RecoveryLabel.waitingForNetwork);
  }

  /// Torrents and local files: no check can reach them, so the ladder runs as
  /// today, with the spec's back-off between its reopens.
  RecoveryStep _ladderWithoutCheck(_Recovery recovery) {
    if (!_played.contains(_current) || _retries >= limits.backoff.length) {
      return _failOver(recovery.detail);
    }
    final wait = limits.backoff[_retries];
    _retries += 1;
    return _reopenAfter(
      recovery,
      wait,
      live: _live,
      keepPicture: recovery.sign != FailureSign.noPicture,
    );
  }

  /// The check while opening found the source unreachable. Only before the
  /// attempt's first picture - one on screen was reached, whatever the check
  /// says - and only when there is somewhere proven to go: the probe is wrong
  /// about slow hosts, and its word alone must not end the only hope left.
  RecoveryStep _abandonUnreachable(_Recovery recovery) {
    final revert = _revertTo;
    final proven = _attemptPictured
        ? null
        : revert ??
              firstReachableIndex(
                total: _candidates.length,
                probes: _probes,
                failed: _failed,
                except: _current,
              );
    if (proven == null) {
      _endRecovery();
      _failureHandled = false;
      return const Carry();
    }
    if (revert != null) return _revert(revert, recovery.detail);
    _failed.add(_current);
    return _issue(FailOverTo(proven, detail: recovery.detail), recovery.detail);
  }

  RecoveryStep _revert(int to, String detail) {
    _revertTo = null;
    _failed.add(_current);
    return _issue(FailOverTo(to, detail: detail, revert: true), detail);
  }

  RecoveryStep _reopenAfter(
    _Recovery recovery,
    Duration wait, {
    required bool live,
    required bool keepPicture,
  }) {
    final step = ReopenSource(_current, live: live, keepPicture: keepPicture);
    if (wait <= Duration.zero) return _issue(step, recovery.detail);
    _schedule(recovery, step, wait);
    return const Carry();
  }

  void _schedule(_Recovery recovery, RecoveryStep step, Duration wait) {
    recovery
      ..scheduled = step
      ..scheduledAt = clock.now().add(wait);
    _phase = RecoveryPhase.scheduled;
  }

  RecoveryStep _failOver(String detail) {
    _failed.add(_current);
    final next = nextFailoverIndex(
      from: _current,
      total: _candidates.length,
      tried: <int>{..._tried, ..._failed},
      // Known dead before anything opened them: walked last, not dropped -
      // the probe is wrong about slow hosts.
      unreachable: <int>{
        for (final entry in _probes.entries)
          if (entry.value == ProbeOutcome.unhealthy ||
              entry.value == ProbeOutcome.notVideo)
            entry.key,
      },
      // Picking up mid-film: a source that cannot seek would start it again
      // from the top.
      cannotSeek: _resuming()
          ? <int>{
              for (final entry in _probes.entries)
                if (entry.value == ProbeOutcome.unseekable) entry.key,
            }
          : const <int>{},
    );
    if (next == null) return _giveUp(GiveUpCause.noSourceLeft, detail);
    return _issue(FailOverTo(next, detail: detail), detail);
  }

  /// Hands out a reopen or a failover, against the session cap. The screen
  /// opens what this asks for and says so with [opened]; until then nothing
  /// more is scheduled.
  RecoveryStep _issue(RecoveryStep step, String detail) {
    if (_reopens >= limits.sessionReopens) {
      return _giveUp(GiveUpCause.sessionCap, detail);
    }
    _reopens += 1;
    _endRecovery();
    return step;
  }

  RecoveryStep _giveUp(GiveUpCause cause, String detail) {
    _recovery = null;
    _phase = RecoveryPhase.gaveUp;
    return GiveUp(cause, detail: detail);
  }

  void _endRecovery() {
    _recovery = null;
    _phase = RecoveryPhase.watching;
  }

  bool _checkable(int source) =>
      source >= 0 &&
      source < _candidates.length &&
      _candidates[source].checkable;

  /// Another candidate on another host and port that a check can reach and
  /// that hasn't failed: the next in the ring, or null when there is none.
  int? _witness() {
    final total = _candidates.length;
    if (_current < 0 || _current >= total) return null;
    final host = _candidates[_current].authority;
    for (var step = 1; step < total; step++) {
      final index = (_current + step) % total;
      final candidate = _candidates[index];
      if (candidate.checkable &&
          candidate.authority.isNotEmpty &&
          candidate.authority != host &&
          !_failed.contains(index)) {
        return index;
      }
    }
    return null;
  }
}

/// One recovery, from a failure until an open or a give-up ends it.
class _Recovery {
  _Recovery(this.sign, this.detail);

  final FailureSign sign;
  final String detail;

  /// Checks out, by source, and when each began.
  final Map<int, DateTime> inFlight = <int, DateTime>{};

  /// A step due at a time: a back-off's reopen, a busy server's next check.
  RecoveryStep? scheduled;
  DateTime? scheduledAt;

  /// When the waiting source and the other host are next checked.
  DateTime? nextCheckAt;
  DateTime? nextWitnessAt;

  /// When the failed source first got no answer, and when the other host last
  /// answered.
  DateTime? noAnswerSince;
  DateTime? witnessAnsweredAt;
  bool witnessChecked = false;

  /// When a source that never played began waiting on what looks like our
  /// network.
  DateTime? ourNetworkSince;

  /// Recovery has waited: the reopen after the next answer goes at once.
  bool waited = false;

  /// Reported while the app was away, and handled on its return.
  bool heldWhileHidden = false;
}
