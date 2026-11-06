import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/providers/device_memory.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  testWidgets(
    "a reopen doesn't wait on a memory read of its own",
    variant: texturePlatform,
    (tester) async {
      // Each read takes a second, as a busy phone emulator's platform thread
      // can make it (1-141 ms measured, P1 Part 2): read at every open, it
      // came before every reopen's setSource.
      var reads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(deviceMemoryChannel, (call) async {
            reads += 1;
            await Future<void>.delayed(const Duration(seconds: 1));
            return harnessMemory;
          });
      await pumpPlayer(
        tester,
        preloadedStreams: const <StreamResult>[
          StreamResult(url: 'https://cdn.test/a.mp4', source: 'A'),
          StreamResult(url: 'https://cdn.test/b.mp4', source: 'B'),
        ],
      );
      await tester.pump(const Duration(seconds: 3));
      final opened = engine.callsTo('setSource').length;
      expect(opened, 1);

      // Source A ends before its first frame: the next source opens.
      await sendEvent(tester, snapshot(state: 'error'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        engine.callsTo('setSource').length,
        greaterThan(opened),
        reason: 'the reading started after the last plan is ready',
      );
      expect(reads, greaterThanOrEqualTo(2));
      // The reading this reopen started for the open after it.
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
