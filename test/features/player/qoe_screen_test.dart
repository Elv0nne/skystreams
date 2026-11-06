import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/qoe_log.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  List<QoeEventKind> kinds() =>
      QoeLog.latest!.events.map((e) => e.kind).toList();

  testWidgets(
    'a session is recorded from the open to the viewer leaving',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(tester);
      await sendFirstFrame(tester);

      expect(
        kinds(),
        containsAllInOrder(<QoeEventKind>[
          QoeEventKind.open,
          QoeEventKind.engine,
          QoeEventKind.firstFrame,
        ]),
      );
      final open = QoeLog.latest!.events.firstWhere(
        (e) => e.kind == QoeEventKind.open,
      );
      expect(open.fields['host'], 'example.com');
      expect(open.fields['kind'], 'file');
      expect(open.fields['reason'], 'first');

      await tester.pumpWidget(const SizedBox());

      expect(QoeLog.latest!.events.last.kind, QoeEventKind.end);
      expect(QoeLog.latest!.events.last.fields['why'], 'left');
    },
  );

  testWidgets(
    'an engine error is recorded, and the session ends as failed',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(tester);
      await sendEvent(tester, snapshot(state: 'error'));
      await settle(tester);

      expect(kinds(), contains(QoeEventKind.error));

      await tester.pumpWidget(const SizedBox());

      expect(QoeLog.latest!.events.last.fields['why'], 'failed');
    },
  );

  testWidgets(
    'the buffer plan is recorded before the engine starts',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(tester);
      await sendFirstFrame(tester);

      expect(
        kinds(),
        containsAllInOrder(<QoeEventKind>[
          QoeEventKind.open,
          QoeEventKind.buffer,
          QoeEventKind.engine,
        ]),
      );
      final buffer = QoeLog.latest!.events.firstWhere(
        (e) => e.kind == QoeEventKind.buffer,
      );
      expect(buffer.fields, containsPair('media', 'httpFile'));
      expect(buffer.fields, containsPair('ringMb', 172));
      expect(buffer.fields, containsPair('capMb', 256));
      expect(buffer.fields, containsPair('totalMb', 4096));
      expect(buffer.fields, containsPair('metered', false));

      await tester.pumpWidget(const SizedBox());
    },
  );

  // Spec 1.8: the metered state is read once as the screen opens and kept
  // current by connectivity events; an open reads the kept answer.
  testWidgets(
    'the network is asked once per screen, and a change reaches the next open',
    variant: texturePlatform,
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var asked = 0;
      messenger.setMockMethodCallHandler(connectivityChannel, (call) async {
        if (call.method == 'check') asked++;
        return <String>['wifi'];
      });
      late MockStreamHandlerEventSink network;
      messenger.setMockStreamHandler(
        connectivityStatus,
        MockStreamHandler.inline(
          onListen: (arguments, sink) {
            network = sink;
          },
        ),
      );

      await pumpPlayer(tester);
      await sendFirstFrame(tester);
      network.success(<String>['mobile']);
      await tester.pump();
      // The source drops, and the same-source retry opens it again.
      await sendEvent(tester, snapshot(state: 'error'));
      await settle(tester);

      expect(asked, 1);
      final buffers = [
        for (final e in QoeLog.latest!.events)
          if (e.kind == QoeEventKind.buffer) e.fields,
      ];
      expect(buffers.map((b) => b['metered']), [false, true]);
      expect(
        buffers.last['ringMb'],
        58,
        reason: '60 s at 8 Mbit/s, on mobile data',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
