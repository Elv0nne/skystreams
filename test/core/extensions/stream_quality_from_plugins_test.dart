// A plugin's `quality` reaches SkyStream: from a `new StreamResult(...)`,
// which the engine's class used to drop, and from an extractor link passed
// on as it is - CloudStream's Unknown (400) included, which is no quality.
//
// Runs a real plugin on the real worker, the way the bridge attribution
// tests do.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/engine/js_bytecode_compiler.dart';
import 'package:skystream/core/extensions/engine/js_engine.dart';
import 'package:skystream/core/extensions/engine/js_engine_worker.dart';
import 'package:skystream/core/extensions/providers/js_based_provider.dart';
import 'package:skystream/core/services/local_proxy_service.dart';
import 'package:skystream/core/storage/extension_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';

class _MemoryExtensionRepository extends ExtensionRepository {
  _MemoryExtensionRepository() : super(StorageService());

  final Map<String, String?> data = <String, String?>{};

  @override
  String? getExtensionData(String key) => data[key];

  @override
  Future<void> setExtensionData(String key, String? value) async {
    data[key] = value;
  }
}

/// A real [JsWorkerRunner] wired to a real [JsEngineService].
class _LiveEngine {
  _LiveEngine(ExtensionRepository repo) {
    _fromWorker.listen((Object? m) => engine.handleWorkerMessage(m));
    _runner = JsWorkerRunner(_fromWorker.sendPort);
    _toWorker.listen(_runner.handle);
    engine = JsEngineService.withWorkerPort(repo, Dio(), _toWorker.sendPort);
  }

  final ReceivePort _fromWorker = ReceivePort();
  final ReceivePort _toWorker = ReceivePort();
  late final JsWorkerRunner _runner;
  late final JsEngineService engine;

  void dispose() {
    _runner.handle(<String, Object?>{'dp': 1});
    engine.dispose();
    _fromWorker.close();
    _toWorker.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _LiveEngine live;
  late Directory dir;

  setUp(() async {
    live = _LiveEngine(_MemoryExtensionRepository());
    dir = await Directory.systemTemp.createTemp('ss_stream_quality');
  });

  tearDown(() async {
    live.dispose();
    await LocalProxyService.instance.shutdown();
    await JsBytecodeCompiler.settle();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test(
    "a plugin's quality reaches SkyStream, whichever way it is written",
    () async {
      final raw = jsonEncode([
        {
          'name': 'M3U8',
          'source': 'M3u8Helper',
          'url': 'https://cdn.test/1080.m3u8',
          'quality': 1080,
          'type': 'm3u8',
        },
        {
          'name': 'Auto',
          'source': 'M3u8Helper',
          'url': 'https://cdn.test/master2.m3u8',
          'quality': 400,
          'type': 'm3u8',
        },
      ]);
      final file = File('${dir.path}/plugin.js')
        ..writeAsStringSync('''
function loadStreams(url, cb) {
  cb({ success: true, data: [
    new StreamResult({ url: 'https://cdn.test/master.m3u8', source: 'Server 1', quality: 'Auto' }),
    new StreamResult({ url: 'https://cdn.test/720.m3u8', source: 'Server 2', quality: '720p' }),
  ].concat($raw) });
}
''');
      final provider = JsBasedProvider(
        live.engine,
        file.path,
        packageName: 'com.test.quality',
        namespace: 'com_test_quality__streams',
      );

      final streams = await provider.loadStreams(
        'https://site.example/watch/1',
      );

      expect([for (final s in streams) s.quality], [0, 720, 1080, null]);
    },
  );
}
