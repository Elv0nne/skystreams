import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/utils/latest_value_sender.dart';

/// A finger on a rail or a held key asks for a new level many times a second,
/// and each one is a platform call: one goes at a time, and only the newest
/// waits.
void main() {
  late List<int> sent;
  late List<Completer<void>> calls;
  late int idle;
  late LatestValueSender<int> sender;

  setUp(() {
    sent = [];
    calls = [];
    idle = 0;
    sender = LatestValueSender<int>((value) {
      sent.add(value);
      final call = Completer<void>();
      calls.add(call);
      return call.future;
    }, onIdle: () => idle++);
  });

  test('the first value goes at once', () {
    sender.send(1);
    expect(sent, [1]);
    expect(sender.busy, isTrue);
  });

  test('values sent while one is in flight leave only the newest, sent when '
      'it completes', () async {
    sender.send(1);
    sender.send(2);
    sender.send(3);
    sender.send(4);
    expect(sent, [1]);
    calls.last.complete();
    await pumpEventQueue();
    expect(sent, [1, 4]);
    calls.last.complete();
    await pumpEventQueue();
    expect(sent, [1, 4]);
    expect(sender.busy, isFalse);
  });

  test("a call that fails doesn't stop the next", () async {
    sender.send(1);
    sender.send(2);
    calls.last.completeError(StateError('refused'));
    await pumpEventQueue();
    expect(sent, [1, 2]);
    calls.last.complete();
    await pumpEventQueue();
    expect(sender.busy, isFalse);
  });

  test('onIdle comes once the queue has drained, not between calls', () async {
    sender.send(1);
    sender.send(2);
    calls.last.complete();
    await pumpEventQueue();
    expect(idle, 0);
    calls.last.complete();
    await pumpEventQueue();
    expect(idle, 1);
    sender.send(3);
    calls.last.complete();
    await pumpEventQueue();
    expect(idle, 2);
  });
}
