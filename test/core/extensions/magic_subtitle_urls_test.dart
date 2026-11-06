// A plugin's subtitles get the address treatment its stream gets.
//
// NetMirror hands every subtitle back as MAGIC_PROXY_v2 - base64 of the real
// address, which is an HLS subtitle playlist, and the headers it needs - and
// only the stream's address used to be decoded. The subtitle reached the
// player as a string with no scheme and was dropped before it could show.
//
// Runs a real plugin on the real worker, the way the bridge attribution tests
// do.

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

String _magicV2(Map<String, Object?> config) =>
    'MAGIC_PROXY_v2${base64Encode(utf8.encode(jsonEncode(config)))}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _LiveEngine live;
  late Directory dir;

  setUp(() async {
    live = _LiveEngine(_MemoryExtensionRepository());
    dir = await Directory.systemTemp.createTemp('ss_magic_subtitles');
  });

  tearDown(() async {
    live.dispose();
    await LocalProxyService.instance.shutdown();
    await JsBytecodeCompiler.settle();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('a MAGIC_PROXY subtitle is routed through the local proxy', () async {
    final subtitle = _magicV2({
      'url': 'https://subs.example/en/index.m3u8',
      'headers': {'Referer': 'https://site.example/'},
    });
    final stream = jsonEncode({
      'success': true,
      'data': [
        {
          'url': 'https://video.example/master.m3u8',
          'source': 'Test',
          'headers': {'Referer': 'https://site.example/'},
          'subtitles': [
            {'url': subtitle, 'label': 'English', 'lang': 'en'},
            {'url': 'https://plain.example/fr.vtt', 'label': 'French'},
          ],
        },
      ],
    });
    final file = File('${dir.path}/plugin.js')
      ..writeAsStringSync('function loadStreams(url, cb) { cb($stream); }');
    final provider = JsBasedProvider(
      live.engine,
      file.path,
      packageName: 'com.test.magic',
      namespace: 'com_test_magic__subs',
    );

    final streams = await provider.loadStreams('https://site.example/watch/1');

    final subtitles = streams.single.subtitles!;
    final proxied = Uri.parse(subtitles[0].url);
    expect(proxied.host, '127.0.0.1');
    expect(proxied.port, LocalProxyService.instance.port);
    expect(proxied.path, '/proxy');
    expect(
      proxied.queryParameters['url'],
      'https://subs.example/en/index.m3u8',
    );
    final headers = jsonDecode(
      utf8.decode(base64Url.decode(proxied.queryParameters['h']!)),
    );
    expect(headers, {'Referer': 'https://site.example/'});
    expect(subtitles[0].label, 'English');
    expect(subtitles[0].lang, 'en');

    // An ordinary address is left exactly as the plugin gave it.
    expect(subtitles[1].url, 'https://plain.example/fr.vtt');
    expect(subtitles[1].label, 'French');
  });
}
