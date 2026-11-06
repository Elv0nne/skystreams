import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';

/// The checks an app run met: one per site, with its state, when that began,
/// and the extensions that met it.
void main() {
  late DateTime now;
  late SiteChecks checks;

  setUp(() {
    now = DateTime(2026, 10, 3, 9);
    checks = SiteChecks(clock: () => now);
  });

  test('a site that keeps asking still wants a person; an outdated browser '
      'or a refusing site does not', () {
    final checks = SiteChecks();
    checks
      ..met('a.com')
      ..update('a.com', CheckState.keepsAsking);
    expect(checks['a.com']!.wantsPerson, isTrue);
    for (final state in [CheckState.outdated, CheckState.ineffective]) {
      checks.update('a.com', state);
      expect(checks['a.com']!.wantsPerson, isFalse, reason: state.name);
    }
  });

  test('a site met for the first time is being checked', () {
    checks.met('a.com', source: 'js:a');
    final check = checks['a.com']!;
    expect(check.state, CheckState.checking);
    expect(check.sources, {'js:a'});
    expect(check.metAt, now);
    expect(check.since, now);
  });

  test('meeting it again adds the extension, and keeps the state', () {
    checks
      ..met('a.com', source: 'js:a')
      ..update('a.com', CheckState.needsYou);
    now = now.add(const Duration(seconds: 5));
    checks.met('a.com', source: 'cs3:b');
    final check = checks['a.com']!;
    expect(check.state, CheckState.needsYou);
    expect(check.sources, {'js:a', 'cs3:b'});
    expect(check.metAt, now);
  });

  test('a state is timed from when it began', () {
    checks.met('a.com');
    now = now.add(const Duration(seconds: 12));
    checks.update('a.com', CheckState.cleared);
    expect(checks['a.com']!.since, now);
  });

  test('a screen sees the checks met since its work began, from its '
      'extensions', () {
    checks.met('old.com', source: 'js:a');
    now = now.add(const Duration(minutes: 1));
    final began = now;
    checks
      ..met('a.com', source: 'js:a')
      ..met('b.com', source: 'js:b');
    expect(checks.since(began).map((c) => c.site), ['a.com', 'b.com']);
    expect(checks.since(began, sources: {'js:b'}).map((c) => c.site), [
      'b.com',
    ]);
  });

  test('the latest check one extension met', () {
    final began = now;
    checks.met('a.com', source: 'js:a');
    now = now.add(const Duration(seconds: 1));
    checks.met('b.com', source: 'js:a');
    expect(checks.latestFor('js:a', since: began)?.site, 'b.com');
    expect(checks.latestFor('js:z', since: began), isNull);
    expect(checks.latestFor(null, since: began), isNull);
  });

  test('what the person can do, and what is under way', () {
    checks.met('a.com');
    expect(checks['a.com']!.pending, isTrue);
    for (final state in [CheckState.needsYou, CheckState.stillNotCleared]) {
      checks.update('a.com', state);
      expect(checks['a.com']!.wantsPerson, isTrue, reason: state.name);
    }
    checks.update('a.com', CheckState.blocked);
    expect(checks['a.com']!.wantsPerson, isFalse);
    expect(checks['a.com']!.pending, isFalse);
  });

  test('a moved site keeps where it moved from; a sent-away browser, '
      'where it went', () {
    checks.met('new.org', movedFrom: 'old.com');
    checks.update('new.org', CheckState.sentElsewhere, elsewhere: 'x.net');
    expect(checks['new.org']!.movedFrom, 'old.com');
    expect(checks['new.org']!.elsewhere, 'x.net');
  });

  test('who met a check: its own tag, and for a check filed under any '
      'CloudStream extension, every CloudStream extension', () {
    checks
      ..met('a.com', source: 'js:a')
      ..met('b.com', source: 'cs3');
    expect(checks['a.com']!.metBy('js:a'), isTrue);
    expect(checks['a.com']!.metBy('js:b'), isFalse);
    expect(checks['b.com']!.metBy('cs3:k/A'), isTrue);
    expect(checks['b.com']!.metBy('js:a'), isFalse);
    expect(checks['b.com']!.metBy(null), isFalse);
  });

  test('every change is announced', () async {
    var changes = 0;
    final sub = checks.changes.listen((_) => changes++);
    checks
      ..met('a.com')
      ..update('a.com', CheckState.cleared);
    await pumpEventQueue();
    expect(changes, 2);
    await sub.cancel();
  });
}
