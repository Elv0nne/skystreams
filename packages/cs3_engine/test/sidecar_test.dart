import 'dart:io';

import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// The desktop engine's `java` process, played by a shell script that speaks the protocol: it
/// answers every request with its own process id, notes each in `requests.log` beside it, ends on
/// `exit`, and after `stubborn` outlives its input closing.
const _script = r'''
#!/bin/sh
stubborn=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$(dirname "$0")/requests.log"
  id=$(printf '%s' "$line" | sed -E 's/.*"id":([0-9]+).*/\1/')
  case "$line" in
    *'"method":"exit"'*) exit 3 ;;
    *'"method":"stubborn"'*) stubborn=1 ;;
  esac
  printf '{"id":%s,"result":{"pid":%s}}\n' "$id" "$$"
done
if [ "$stubborn" = 1 ]; then
  trap '' TERM
  while :; do sleep 1 > /dev/null; done
fi
''';

void main() {
  late Directory dir;
  late String java;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cs3_sidecar_');
    final file = File('${dir.path}/java')..writeAsStringSync(_script);
    Process.runSync('chmod', ['+x', file.path]);
    java = file.path;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<Cs3Engine> start() => Cs3Engine.start(dataDir: dir.path, java: java);

  Future<int> enginePid(Cs3Engine engine) async =>
      (await engine.hello())['pid'] as int;

  bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  // Dart collects any child of the app while it waits on one of its own, and libVLC waits forever
  // for a helper it starts before each connection (libproxy's `proxy`) when something else
  // collected it: the Linux player froze (2026-10-03). The engine must not be the app's child.
  test('on Linux, the engine is not the app\'s child', () async {
    final engine = await start();
    addTearDown(engine.dispose);
    final engineId = await enginePid(engine);
    final parent =
        (Process.runSync('ps', ['-o', 'ppid=', '-p', '$engineId']).stdout
                as String)
            .trim();
    expect(int.parse(parent), isNot(pid));
  }, skip: !Platform.isLinux);

  test('an engine that ends fails the call waiting on it, and stops', () async {
    final engine = await start();
    addTearDown(engine.dispose);
    await expectLater(
      engine.call('exit'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('engine exited'),
        ),
      ),
    );
    expect(engine.isRunning, isFalse);
  }, skip: Platform.isWindows);

  test('dispose ends the engine', () async {
    final engine = await start();
    final engineId = await enginePid(engine);
    await engine.dispose();
    expect(engine.isRunning, isFalse);
    // Gone, or on its way out of the process table.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (alive(engineId) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(alive(engineId), isFalse);
  }, skip: Platform.isWindows);

  test('a plugin is loaded with the address it was downloaded from', () async {
    final engine = await start();
    addTearDown(engine.dispose);
    await engine.loadPlugin('/plugins/a.cs3', url: 'https://repo.test/a.cs3');
    await engine.loadPlugin('/plugins/b.cs3');
    final requests = File('${dir.path}/requests.log').readAsLinesSync();
    expect(
      requests,
      contains(
        contains(
          '"method":"loadPlugin","params":{"path":"/plugins/a.cs3","url":"https://repo.test/a.cs3"}',
        ),
      ),
    );
    expect(
      requests,
      contains(
        contains('"method":"loadPlugin","params":{"path":"/plugins/b.cs3"}'),
      ),
    );
  }, skip: Platform.isWindows);

  test("the app's language reaches the engine", () async {
    final engine = await start();
    addTearDown(engine.dispose);
    await engine.setLanguage('pt-BR');
    expect(
      File('${dir.path}/requests.log').readAsLinesSync(),
      contains(contains('"method":"setLanguage","params":{"language":"pt-BR"}')),
    );
  }, skip: Platform.isWindows);

  test("a page's events reach the engine as webPage, fields and all", () async {
    final engine = await start();
    addTearDown(engine.dispose);
    await engine.webPage(7, 'finished', {'url': 'https://site.test/', 'title': 'Sign in'});
    expect(
      File('${dir.path}/requests.log').readAsLinesSync(),
      contains(
        contains(
          '"method":"webPage","params":{"url":"https://site.test/","title":"Sign in","rid":7,"type":"finished"}',
        ),
      ),
    );
  }, skip: Platform.isWindows);

  test(
    'dispose kills an engine that outlives its input',
    () async {
      final engine = await start();
      final engineId = await enginePid(engine);
      await engine.call('stubborn');
      await engine.dispose().timeout(const Duration(seconds: 10));
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (alive(engineId) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(alive(engineId), isFalse);
    },
    skip: Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
