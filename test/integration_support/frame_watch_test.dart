import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/cloudstream/frame_watch.dart';

void main() {
  late DateTime now;
  DateTime clock() => now;
  setUp(() => now = DateTime(2026, 10, 6, 16, 22, 35));

  test('a frame asked for and missing for 30 s is reported once, and so is its return', () {
    final watch = FrameWatch(clock);
    expect(watch.check(asked: true), isNull);
    now = now.add(const Duration(seconds: 29));
    expect(watch.check(asked: true), isNull);
    now = now.add(const Duration(seconds: 2));
    expect(watch.check(asked: true), allOf(startsWith('CS3-NO-FRAMES '), contains('31 s'), contains('16:22:35')));
    now = now.add(const Duration(minutes: 5));
    expect(watch.check(asked: true), isNull);
    now = DateTime(2026, 10, 6, 16, 49, 53);
    expect(watch.frame(), 'CS3-FRAMES-BACK after 1638 s');
    expect(watch.frame(), isNull);
  });

  test('time with no frame asked for is no stall, nor is a frame that comes', () {
    final watch = FrameWatch(clock);
    for (var i = 0; i < 60; i++) {
      now = now.add(const Duration(seconds: 5));
      expect(watch.check(asked: false), isNull);
    }
    expect(watch.check(asked: true), isNull);
    now = now.add(const Duration(seconds: 1));
    expect(watch.frame(), isNull);
    now = now.add(const Duration(seconds: 40));
    expect(watch.check(asked: true), isNull);
  });
}
