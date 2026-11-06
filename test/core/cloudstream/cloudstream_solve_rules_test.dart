import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';

/// Which engine calls in flight have a person waiting on a bot check. Every
/// call may start one (the owner, 2026-10-03).
void main() {
  test('a title opening or its links has the person waiting', () {
    expect(personWaitingFor(['load']), isTrue);
    expect(personWaitingFor(['loadLinks']), isTrue);
    expect(personWaitingFor(['mainPage', 'loadLinks']), isTrue);
  });

  test('a search, home rows or nothing at all asks nobody', () {
    expect(personWaitingFor(['search']), isFalse);
    expect(personWaitingFor(['mainPage']), isFalse);
    expect(personWaitingFor(const []), isFalse);
  });
}
