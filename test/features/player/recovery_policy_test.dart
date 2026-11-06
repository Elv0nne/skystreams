import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/recovery_policy.dart';
import 'package:skystream/features/player/domain/source_check.dart';
import 'package:skystream/features/player/domain/stream_resolver.dart'
    show ProbeOutcome;

/// The time every policy in this file reads. Moved by hand: a jump is one
/// assignment, and nothing waits for real.
DateTime _now = DateTime.utc(2026, 10, 15, 20);

void _pass(Duration d) => _now = _now.add(d);

/// A test on the clock [_pass] moves.
void _test(String description, void Function() body) {
  test(description, () {
    _now = DateTime.utc(2026, 10, 15, 20);
    withClock(Clock(() => _now), body);
  });
}

const _answers = CheckResult(
  kind: CheckClass.answers,
  outcome: ProbeOutcome.healthy,
  status: 206,
);
const _noAnswer = CheckResult(
  kind: CheckClass.network,
  outcome: ProbeOutcome.unhealthy,
  fault: NetworkFault.refused,
);
CheckResult _gone(int status) => CheckResult(
  kind: CheckClass.gone,
  outcome: ProbeOutcome.unhealthy,
  status: status,
);
CheckResult _busy([Duration? retryAfter]) => CheckResult(
  kind: CheckClass.busy,
  outcome: ProbeOutcome.unhealthy,
  status: 503,
  retryAfter: retryAfter,
);

/// A policy over one candidate per entry of [hosts], playing [source], which
/// has shown a picture.
RecoveryPolicy _playing(
  List<String> hosts, {
  int source = 0,
  bool live = false,
  bool resuming = true,
  List<bool>? checkable,
}) => RecoveryPolicy(resuming: () => resuming)
  ..candidatesChanged([
    for (var i = 0; i < hosts.length; i++)
      RecoveryCandidate(authority: hosts[i], checkable: checkable?[i] ?? true),
  ])
  ..opened(source: source, live: live)
  ..pictured();

/// As [_playing], with [source] opened but showing nothing yet.
RecoveryPolicy _opening(List<String> hosts, {int source = 0}) =>
    RecoveryPolicy()
      ..candidatesChanged([
        for (final host in hosts) RecoveryCandidate(authority: host),
      ])
      ..opened(source: source, live: false);

RecoveryStep _fail(
  RecoveryPolicy policy, [
  FailureSign sign = FailureSign.engineError,
]) => policy.failed(sign, detail: 'playback error');

/// Moves the clock to [policy]'s next due time and asks it.
RecoveryStep _wake(RecoveryPolicy policy) {
  final due = policy.nextDue;
  expect(due, isNotNull, reason: 'nothing is scheduled');
  if (due!.isAfter(_now)) _now = due;
  return policy.due();
}

/// Healthy playback for [d], one report a second.
void _play(RecoveryPolicy policy, Duration d) {
  policy.moved();
  for (var t = Duration.zero; t < d; t += const Duration(seconds: 1)) {
    _pass(const Duration(seconds: 1));
    policy.moved();
  }
}

/// One failure of the source playing, its check answered, its reopen
/// scheduled and run, and the reopened attempt opened: returns the wait
/// before the reopen.
Duration _failAnsweredReopened(RecoveryPolicy policy, {int source = 0}) {
  expect(_fail(policy), _checks(source));
  expect(policy.checked(source, _answers), _carry);
  final wait = policy.nextDue!.difference(_now);
  expect(_wake(policy), _reopens(source));
  policy.opened(source: source, live: false);
  return wait;
}

Matcher _checks(int source) =>
    isA<RunCheck>().having((s) => s.source, 'source', source);
Matcher _reopens(int source, {bool keepPicture = true, bool live = false}) =>
    isA<ReopenSource>()
        .having((s) => s.source, 'source', source)
        .having((s) => s.keepPicture, 'keepPicture', keepPicture)
        .having((s) => s.live, 'live', live);
Matcher _failsOverTo(int source, {bool revert = false}) => isA<FailOverTo>()
    .having((s) => s.source, 'source', source)
    .having((s) => s.revert, 'revert', revert)
    .having((s) => s.detail, 'detail', 'playback error');
Matcher _waits(RecoveryLabel label) =>
    isA<WaitHere>().having((s) => s.label, 'label', label);
Matcher _givesUp(GiveUpCause cause) => isA<GiveUp>()
    .having((s) => s.cause, 'cause', cause)
    .having((s) => s.detail, 'detail', 'playback error');
const _carry = TypeMatcher<Carry>();

void main() {
  group('played, the server answers', () {
    _test('a failure of a source that has played is checked first', () {
      final policy = _playing(['a.test']);

      expect(_fail(policy), _checks(0));
      expect(policy.phase, RecoveryPhase.checking);
      expect(policy.label, RecoveryLabel.reconnecting);
    });

    _test(
      'an answer reopens the same source 1 s later, keeping the picture',
      () {
        final policy = _playing(['a.test']);
        _fail(policy);

        expect(policy.checked(0, _answers), _carry);
        expect(policy.phase, RecoveryPhase.scheduled);
        expect(policy.nextDue, _now.add(const Duration(seconds: 1)));
        _pass(const Duration(milliseconds: 999));
        expect(policy.due(), _carry);
        _pass(const Duration(milliseconds: 1));
        expect(policy.due(), _reopens(0));
        expect(policy.phase, RecoveryPhase.watching);
        expect(policy.reopens, 1);
      },
    );

    _test('four failures that answer reopen at 1, 2, 4 and 8 s and the fifth '
        'fails over', () {
      final policy = _playing(['a.test', 'b.test']);

      final waits = [for (var i = 0; i < 4; i++) _failAnsweredReopened(policy)];
      expect(waits, const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
      ]);
      expect(_fail(policy), _checks(0));
      expect(policy.checked(0, _answers), _failsOverTo(1));
      expect(policy.isFailed(0), isTrue);
    });

    _test('a reopen for a missing picture does not keep it', () {
      final policy = _playing(['a.test']);

      expect(_fail(policy, FailureSign.noPicture), _checks(0));
      policy.checked(0, _answers);
      expect(_wake(policy), _reopens(0, keepPicture: false));
    });

    _test('the failover walks past tried and dead sources, and past ones that '
        'cannot seek when resuming', () {
      final policy = _playing(['a.test', 'b.test', 'c.test', 'd.test'])
        ..probed(1, ProbeOutcome.unhealthy)
        ..probed(2, ProbeOutcome.unseekable);
      for (var i = 0; i < 4; i++) {
        _failAnsweredReopened(policy);
      }
      _fail(policy);
      expect(policy.checked(0, _answers), _failsOverTo(3));

      policy
        ..opened(source: 3, live: false)
        ..pictured();
      for (var i = 0; i < 4; i++) {
        _failAnsweredReopened(policy, source: 3);
      }
      _fail(policy);
      expect(policy.checked(3, _answers), _failsOverTo(2));
    });

    _test('with no source left it gives up with the failure\'s reason', () {
      final policy = _playing(['a.test']);
      for (var i = 0; i < 4; i++) {
        _failAnsweredReopened(policy);
      }
      _fail(policy);

      expect(policy.checked(0, _answers), _givesUp(GiveUpCause.noSourceLeft));
      expect(policy.phase, RecoveryPhase.gaveUp);
      expect(_fail(policy), _carry);
    });
  });

  group('played, no answer', () {
    _test('no answer waits, uses no attempt, and says Reconnecting…', () {
      final policy = _playing(['a.test']);
      _fail(policy);

      expect(policy.checked(0, _noAnswer), _waits(RecoveryLabel.reconnecting));
      expect(policy.phase, RecoveryPhase.waiting);
      expect(policy.label, RecoveryLabel.reconnecting);
      expect(policy.reopens, 0);
    });

    _test('it checks every 2 s for five minutes, then every 10 s', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);
      final waitBegan = _now;

      var checks = 0;
      while (_now.difference(waitBegan) < const Duration(minutes: 5)) {
        expect(policy.nextDue!.difference(_now), const Duration(seconds: 2));
        expect(_wake(policy), _checks(0));
        policy.checked(0, _noAnswer);
        checks++;
      }
      expect(checks, 150);
      expect(policy.nextDue!.difference(_now), const Duration(seconds: 10));
    });

    _test('a check still out when the next is due is not doubled', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);
      expect(_wake(policy), _checks(0));

      _pass(const Duration(seconds: 5));
      expect(policy.nextDue, isNull);
      expect(policy.due(), _carry);
    });

    _test('an answer after a wait reopens at once', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);
      _wake(policy);

      expect(policy.checked(0, _answers), _reopens(0));
    });

    _test(
      'a ten-minute wait still reopens the same source, attempts intact',
      () {
        final policy = _playing(['a.test']);
        _fail(policy);
        policy.checked(0, _noAnswer);
        while (_now.difference(DateTime.utc(2026, 10, 15, 20)) <
            const Duration(minutes: 10)) {
          _wake(policy);
          policy.checked(0, _noAnswer);
        }
        _wake(policy);
        expect(policy.checked(0, _answers), _reopens(0));
        policy.opened(source: 0, live: false);

        // The four reopens are all still there.
        for (var i = 0; i < 4; i++) {
          _failAnsweredReopened(policy);
        }
      },
    );

    _test('the clock running on under a missing or starved picture ends '
        'nothing', () {
      for (final sign in [FailureSign.noPicture, FailureSign.videoStarved]) {
        final policy = _playing(['a.test']);
        _fail(policy, sign);
        policy.checked(0, _noAnswer);

        policy.moved();
        expect(policy.phase, RecoveryPhase.waiting, reason: sign.name);
      }
    });

    _test('playback moving again ends a stall\'s wait with no reopen', () {
      final policy = _playing(['a.test']);
      _fail(policy, FailureSign.stalled);
      policy.checked(0, _noAnswer);

      policy.moved();
      expect(policy.phase, RecoveryPhase.watching);
      expect(policy.label, RecoveryLabel.none);
      expect(policy.nextDue, isNull);
      // A later failure of the same attempt is handled again.
      expect(_fail(policy), _checks(0));
    });
  });

  group('the network or the host', () {
    _test('no answer for 30 s while another host answers fails over to it', () {
      final policy = _playing(['a.test', 'b.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);

      expect(policy.due(), _checks(1));
      expect(policy.checked(1, _answers), _carry);
      final began = _now;
      while (_now.difference(began) < const Duration(seconds: 28)) {
        final step = _wake(policy);
        if (step is RunCheck && step.source == 1) {
          policy.checked(1, _answers);
        } else {
          expect(step, _checks(0));
          expect(policy.checked(0, _noAnswer), _carry);
        }
      }
      RecoveryStep last = const Carry();
      while (last is! FailOverTo) {
        final step = _wake(policy);
        last = policy.checked(
          (step as RunCheck).source,
          step.source == 1 ? _answers : _noAnswer,
        );
      }
      expect(last, _failsOverTo(1));
      expect(
        _now.difference(began),
        lessThanOrEqualTo(const Duration(seconds: 32)),
      );
    });

    _test('an answer within 30 s keeps the source', () {
      final policy = _playing(['a.test', 'b.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);
      policy.due();
      policy.checked(1, _answers);
      for (var i = 0; i < 9; i++) {
        _wake(policy);
        policy.checked(0, _noAnswer);
      }

      _wake(policy);
      expect(policy.checked(0, _answers), _reopens(0));
    });

    _test('when the other host does not answer either, it keeps waiting', () {
      final policy = _playing(['a.test', 'b.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);
      while (_now.difference(DateTime.utc(2026, 10, 15, 20)) <
          const Duration(seconds: 60)) {
        final step = _wake(policy) as RunCheck;
        expect(policy.checked(step.source, _noAnswer), _carry);
      }
      expect(policy.phase, RecoveryPhase.waiting);
    });

    _test(
      'a source with no other host to compare waits without failing over',
      () {
        final policy = _playing(['a.test']);
        _fail(policy);
        policy.checked(0, _noAnswer);
        for (var i = 0; i < 100; i++) {
          _wake(policy);
          expect(policy.checked(0, _noAnswer), _carry);
        }
        expect(policy.phase, RecoveryPhase.waiting);
      },
    );

    _test('a candidate on the same host and port is no witness', () {
      final policy = _playing(['a.test:80', 'a.test:80', 'b.test:8080']);
      _fail(policy);
      policy.checked(0, _noAnswer);

      expect(policy.due(), _checks(2));
    });
  });

  group('the device offline', () {
    _test('going offline while nothing is wrong changes nothing', () {
      final policy = _playing(['a.test']);

      expect(policy.connectivity(online: false), _carry);
      expect(policy.label, RecoveryLabel.none);
      expect(policy.nextDue, isNull);
    });

    _test('a failure while offline waits, says Waiting for network…, and '
        'checks nothing but the fallback', () {
      final policy = _playing(['a.test'])..connectivity(online: false);

      expect(_fail(policy), _waits(RecoveryLabel.waitingForNetwork));
      expect(policy.label, RecoveryLabel.waitingForNetwork);
      expect(policy.nextDue!.difference(_now), const Duration(seconds: 10));
    });

    _test('going offline during a wait switches the label and stops the 2 s '
        'checks', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);

      expect(
        policy.connectivity(online: false),
        _waits(RecoveryLabel.waitingForNetwork),
      );
      expect(policy.nextDue!.difference(_now), const Duration(seconds: 10));
    });

    _test('the network coming back checks at once, and an answer reopens at '
        'once', () {
      final policy = _playing(['a.test'])..connectivity(online: false);
      _fail(policy);

      expect(policy.connectivity(online: true), _checks(0));
      expect(policy.label, RecoveryLabel.reconnecting);
      expect(policy.checked(0, _answers), _reopens(0));
    });

    _test('while offline a fallback check runs every 10 s, and its answer '
        'reopens', () {
      final policy = _playing(['a.test'])..connectivity(online: false);
      _fail(policy);

      expect(_wake(policy), _checks(0));
      expect(policy.checked(0, _noAnswer), _carry);
      expect(policy.nextDue!.difference(_now), const Duration(seconds: 10));
      expect(_wake(policy), _checks(0));
      expect(policy.checked(0, _answers), _reopens(0));
    });

    _test('online and offline in quick succession check once', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);
      policy.connectivity(online: false);

      expect(policy.connectivity(online: true), _checks(0));
      expect(
        policy.connectivity(online: false),
        _waits(RecoveryLabel.waitingForNetwork),
      );
      expect(policy.connectivity(online: true), _carry);
    });

    _test('two minutes offline use no source and no attempt', () {
      final policy = _playing(['a.test', 'b.test'])
        ..connectivity(online: false);
      _fail(policy);
      while (_now.difference(DateTime.utc(2026, 10, 15, 20)) <
          const Duration(minutes: 2)) {
        _wake(policy);
        policy.checked(0, _noAnswer);
      }

      expect(policy.connectivity(online: true), _checks(0));
      expect(policy.checked(0, _answers), _reopens(0));
      expect(policy.isFailed(1), isFalse);
      policy.opened(source: 0, live: false);
      for (var i = 0; i < 4; i++) {
        _failAnsweredReopened(policy);
      }
    });
  });

  group('gone', () {
    _test('403, 404 and 410 fail over at once and mark the source failed', () {
      for (final status in [403, 404, 410]) {
        final policy = _playing(['a.test', 'b.test']);
        _fail(policy);
        expect(policy.checked(0, _gone(status)), _failsOverTo(1));
        expect(policy.isFailed(0), isTrue);
      }
    });

    _test('gone with nowhere to go gives up', () {
      final policy = _playing(['a.test']);
      _fail(policy);

      expect(policy.checked(0, _gone(404)), _givesUp(GiveUpCause.noSourceLeft));
    });
  });

  group('busy', () {
    _test('busy checks again at 1, 2, 4 and 8 s, then fails over', () {
      final policy = _playing(['a.test', 'b.test']);
      _fail(policy);
      final waits = <Duration>[];
      for (var i = 0; i < 4; i++) {
        expect(policy.checked(0, _busy()), _carry);
        waits.add(policy.nextDue!.difference(_now));
        expect(_wake(policy), _checks(0));
      }

      expect(waits, const [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
      ]);
      expect(policy.checked(0, _busy()), _failsOverTo(1));
    });

    _test('a Retry-After longer than the schedule is waited out', () {
      final policy = _playing(['a.test']);
      _fail(policy);

      policy.checked(0, _busy(const Duration(seconds: 6)));
      expect(policy.nextDue!.difference(_now), const Duration(seconds: 6));
    });

    _test('a Retry-After shorter than the schedule is not', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.checked(0, _busy());
      _wake(policy);

      policy.checked(0, _busy(const Duration(seconds: 1)));
      expect(policy.nextDue!.difference(_now), const Duration(seconds: 2));
    });

    _test('a Retry-After past 30 s fails over at once', () {
      final policy = _playing(['a.test', 'b.test']);
      _fail(policy);

      expect(
        policy.checked(0, _busy(const Duration(seconds: 31))),
        _failsOverTo(1),
      );
    });

    _test('an answer after busy reopens at once', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.checked(0, _busy());
      _wake(policy);

      expect(policy.checked(0, _answers), _reopens(0));
    });
  });

  group('never played', () {
    _test('a source that never played and answers fails over at once', () {
      final policy = _opening(['a.test', 'b.test']);

      expect(_fail(policy), _checks(0));
      expect(policy.label, RecoveryLabel.none);
      expect(policy.checked(0, _answers), _failsOverTo(1));
    });

    _test('no answer while another host answers fails over at once', () {
      final policy = _opening(['a.test', 'b.test']);
      _fail(policy);

      expect(policy.checked(0, _noAnswer), _checks(1));
      expect(policy.checked(1, _answers), _failsOverTo(1));
    });

    _test('no answer waits while the device is offline', () {
      final policy = _opening(['a.test', 'b.test'])
        ..connectivity(online: false);

      expect(_fail(policy), _waits(RecoveryLabel.waitingForNetwork));
      for (var i = 0; i < 12; i++) {
        _wake(policy);
        expect(policy.checked(0, _noAnswer), _carry);
      }
      expect(policy.isFailed(0), isFalse);
    });

    _test('with no witness it waits 30 s, then gives up with one source', () {
      final policy = _opening(['a.test']);
      _fail(policy);
      expect(policy.checked(0, _noAnswer), _carry);
      final began = _now;

      RecoveryStep last = const Carry();
      while (last is Carry) {
        _wake(policy);
        last = policy.checked(0, _noAnswer);
      }
      expect(last, _givesUp(GiveUpCause.noSourceLeft));
      expect(_now.difference(began), const Duration(seconds: 30));
    });

    _test('with a witness that does not answer either it waits 30 s, then '
        'fails over', () {
      final policy = _opening(['a.test', 'b.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);
      policy.checked(1, _noAnswer);

      RecoveryStep last = const Carry();
      while (last is! FailOverTo) {
        final step = _wake(policy) as RunCheck;
        last = policy.checked(step.source, _noAnswer);
      }
      expect(last, _failsOverTo(1));
    });

    _test('one that never played and answers after a network wait opens '
        'again, behind the start-up view', () {
      // A film opened while offline: the network coming back says nothing
      // against the source (rows 2 and 4; P1 Part 3 review, finding 2).
      final policy = _opening(['a.test'])..connectivity(online: false);

      expect(_fail(policy), _waits(RecoveryLabel.waitingForNetwork));
      expect(policy.connectivity(online: true), _checks(0));
      expect(policy.checked(0, _answers), _reopens(0, keepPicture: false));
    });

    _test('so does one whose own server answers inside the 30 s wait', () {
      final policy = _opening(['a.test']);
      _fail(policy);
      expect(policy.checked(0, _noAnswer), _carry);

      expect(_wake(policy), _checks(0));
      expect(policy.checked(0, _answers), _reopens(0, keepPicture: false));
    });

    _test('a reopen of a source that has played is not a source that never '
        'played (Android, 2026-10-14)', () {
      final policy = _playing(['a.test'])
        // The step-down's reopen, failing during the outage before its
        // first picture.
        ..opened(source: 0, live: false);

      expect(_fail(policy), _checks(0));
      expect(policy.checked(0, _noAnswer), _waits(RecoveryLabel.reconnecting));
      expect(policy.isFailed(0), isFalse);
    });
  });

  group('live', () {
    _test('a live failure that answers reconnects 2 s later, keeping the '
        'picture', () {
      final policy = _playing(['a.test'], live: true);
      _fail(policy, FailureSign.falseEnd);
      policy.checked(0, _answers);

      expect(policy.nextDue!.difference(_now), const Duration(seconds: 2));
      expect(_wake(policy), _reopens(0, live: true));
    });

    _test('five reconnects without 30 s of playback fail over without '
        'another', () {
      final policy = _playing(['a.test', 'b.test'], live: true);
      for (var i = 0; i < 5; i++) {
        _fail(policy, FailureSign.falseEnd);
        policy.checked(0, _answers);
        expect(_wake(policy), _reopens(0, live: true));
        policy.opened(source: 0, live: true);
      }

      _fail(policy, FailureSign.falseEnd);
      expect(policy.checked(0, _answers), _failsOverTo(1));
    });

    _test('a live wait uses no reconnect', () {
      final policy = _playing(['a.test', 'b.test'], live: true);
      _fail(policy);
      policy.checked(0, _noAnswer);
      for (var i = 0; i < 20; i++) {
        _wake(policy);
        policy.checked(0, _noAnswer);
      }
      _wake(policy);
      expect(policy.checked(0, _answers), _reopens(0, live: true));
      policy.opened(source: 0, live: true);

      for (var i = 0; i < 4; i++) {
        _fail(policy);
        policy.checked(0, _answers);
        expect(_wake(policy), _reopens(0, live: true));
        policy.opened(source: 0, live: true);
      }
    });

    _test(
      'a live error, a live stall and a live false end share the budget',
      () {
        final policy = _playing(['a.test', 'b.test'], live: true);
        for (final sign in [
          FailureSign.engineError,
          FailureSign.stalled,
          FailureSign.falseEnd,
          FailureSign.engineError,
          FailureSign.stalled,
        ]) {
          _fail(policy, sign);
          policy.checked(0, _answers);
          _wake(policy);
          policy.opened(source: 0, live: true);
        }

        _fail(policy, FailureSign.falseEnd);
        expect(policy.checked(0, _answers), _failsOverTo(1));
      },
    );

    _test('30 s of live playback refill the reconnects', () {
      final policy = _playing(['a.test', 'b.test'], live: true);
      for (var i = 0; i < 5; i++) {
        _fail(policy, FailureSign.falseEnd);
        policy.checked(0, _answers);
        _wake(policy);
        policy.opened(source: 0, live: true);
      }
      _play(policy, const Duration(seconds: 30));

      _fail(policy, FailureSign.falseEnd);
      policy.checked(0, _answers);
      expect(_wake(policy), _reopens(0, live: true));
    });
  });

  group('budgets and the cap', () {
    _test('30 s of playback refill the attempts and the walk', () {
      final policy = _playing(['a.test', 'b.test']);
      for (var i = 0; i < 4; i++) {
        _failAnsweredReopened(policy);
      }
      _play(policy, const Duration(seconds: 30));

      expect(_failAnsweredReopened(policy), const Duration(seconds: 1));
    });

    _test('stalled or paused time is not healthy', () {
      final policy = _playing(['a.test', 'b.test']);
      for (var i = 0; i < 4; i++) {
        _failAnsweredReopened(policy);
      }
      // Moves 2 s apart for 40 s count 2 s each: 20 reports, 40 s healthy.
      // Moves 20 s apart count 2 s each too: 10 of them are 20 s.
      policy.moved();
      for (var i = 0; i < 10; i++) {
        _pass(const Duration(seconds: 20));
        policy.moved();
      }

      _fail(policy);
      expect(policy.checked(0, _answers), _failsOverTo(1));
    });

    _test(
      'a clock jump while playing adds at most one step of healthy time',
      () {
        final policy = _playing(['a.test', 'b.test']);
        for (var i = 0; i < 4; i++) {
          _failAnsweredReopened(policy);
        }
        policy.moved();
        _pass(const Duration(minutes: 10));
        policy.moved();

        _fail(policy);
        expect(policy.checked(0, _answers), _failsOverTo(1));
      },
    );

    _test(
      'the twenty-first reopen gives up, and the failed screen keeps Retry',
      () {
        final policy = _playing(['a.test']);
        for (var i = 0; i < 20; i++) {
          _failAnsweredReopened(policy);
          // Healthy playback refills the attempts, never the cap.
          _play(policy, const Duration(seconds: 30));
        }
        expect(policy.reopens, 20);

        _fail(policy);
        policy.checked(0, _answers);
        expect(_wake(policy), _givesUp(GiveUpCause.sessionCap));

        policy
          ..reset()
          ..opened(source: 0, live: false)
          ..pictured();
        expect(_failAnsweredReopened(policy), const Duration(seconds: 1));
      },
    );

    _test('picks, Quality picks, step-downs and the software retry do not '
        'count toward the cap', () {
      final policy = _playing(['a.test']);
      for (var i = 0; i < 40; i++) {
        policy.opened(source: 0, live: false);
      }

      expect(policy.reopens, 0);
    });

    _test('a new resolve restores the attempts and the cap', () {
      final policy = _playing(['a.test']);
      for (var i = 0; i < 4; i++) {
        _failAnsweredReopened(policy);
      }
      policy
        ..candidatesChanged(const [RecoveryCandidate(authority: 'a.test')])
        ..opened(source: 0, live: false)
        ..pictured();

      expect(policy.reopens, 0);
      expect(_failAnsweredReopened(policy), const Duration(seconds: 1));
    });
  });

  group('the background', () {
    _test('no check runs in the background, however long it lasts', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);

      expect(policy.foreground(visible: false), _carry);
      expect(policy.nextDue, isNull);
      _pass(const Duration(hours: 1));
      expect(policy.due(), _carry);
    });

    _test('coming back runs a check at once', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.checked(0, _noAnswer);
      policy.foreground(visible: false);

      expect(policy.foreground(visible: true), _checks(0));
    });

    _test('a failure in the background waits for the return', () {
      final policy = _playing(['a.test'])..foreground(visible: false);

      expect(_fail(policy), _carry);
      expect(policy.nextDue, isNull);
      expect(policy.foreground(visible: true), _checks(0));
    });
  });

  group('bookkeeping', () {
    _test('a stop right after an error is one failure', () {
      final policy = _playing(['a.test']);

      expect(_fail(policy), _checks(0));
      expect(_fail(policy, FailureSign.stoppedUnasked), _carry);
    });

    _test('a trial pick that fails goes back to the interrupted source, with '
        'no check', () {
      final policy = _playing(['a.test', 'b.test'])
        ..opened(source: 1, live: false, revertTo: 0);

      expect(_fail(policy), _failsOverTo(0, revert: true));
      expect(policy.isFailed(1), isTrue);
    });

    _test('a trial pick that played 30 s is a source like any other', () {
      final policy = _playing(['a.test', 'b.test'])
        ..opened(source: 1, live: false, revertTo: 0)
        ..pictured();
      _play(policy, const Duration(seconds: 30));

      expect(_fail(policy), _checks(1));
    });

    _test('an unplayable source fails over with no check', () {
      final policy = _opening(['a.test', 'b.test']);

      expect(_fail(policy, FailureSign.unplayable), _failsOverTo(1));
    });

    _test('torrents and local files skip the check and keep the ladder, with '
        'the back-off', () {
      final policy = _playing(
        ['localhost:8090', 'b.test'],
        checkable: [false, true],
      );

      expect(_fail(policy), _carry);
      expect(policy.nextDue!.difference(_now), const Duration(seconds: 1));
      expect(_wake(policy), _reopens(0));
    });

    _test('an unreachable source with no picture moves to a proven one', () {
      final policy = _opening(['a.test', 'b.test'])
        ..probed(1, ProbeOutcome.healthy);

      expect(
        _fail(policy, FailureSign.unreachableWhileOpening),
        _failsOverTo(1),
      );
    });

    _test('an unreachable source carries on with nowhere proven to go, and a '
        'source on screen is never abandoned', () {
      final opening = _opening(['a.test', 'b.test']);
      expect(_fail(opening, FailureSign.unreachableWhileOpening), _carry);
      // The ignored report does not use the attempt's one failure.
      expect(_fail(opening), _checks(0));

      final playing = _playing(['a.test', 'b.test'])
        ..probed(1, ProbeOutcome.healthy);
      expect(_fail(playing, FailureSign.unreachableWhileOpening), _carry);
    });

    _test('nextDue is the earliest scheduled check or reopen, and null when '
        'nothing is', () {
      final policy = _playing(['a.test', 'b.test']);
      expect(policy.nextDue, isNull);
      _fail(policy);
      expect(policy.nextDue, isNull);
      policy.checked(0, _noAnswer);

      // The source in 2 s, the witness at once.
      expect(policy.nextDue, _now);
      expect(policy.due(), _checks(1));
      expect(policy.nextDue, _now.add(const Duration(seconds: 2)));
    });

    _test('a check answered for an earlier resolve or attempt is dropped', () {
      final policy = _playing(['a.test']);
      _fail(policy);
      policy.opened(source: 0, live: false);

      expect(policy.checked(0, _answers), _carry);
      expect(policy.phase, RecoveryPhase.watching);
    });
  });
}
