/// SkyStream's own test extension (packages/cs3_engine/test_extension, built by
/// packages/cs3_engine/tool/build_test_extension.sh), installed straight into CloudStream's folder: the
/// app installs extensions only from HTTPS repositories, and the tests serve this one from the computer
/// running them. Pass its URL with `--dart-define=CS3_TEST_EXTENSION=http://10.0.2.2:8765/SkyStreamTest.cs3`
/// (an Android emulator) or `http://127.0.0.1:8765/SkyStreamTest.cs3` (desktop, simulators).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_models.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';

import 'support.dart';

const testExtensionUrl = String.fromEnvironment('CS3_TEST_EXTENSION');

const testExtensionInfo = CsPluginInfo(
  internalName: 'SkyStreamTest',
  name: 'SkyStream Test',
  url: testExtensionUrl,
  repositoryUrl: 'https://skystream.invalid/test/repo.json',
  version: 1,
  tvTypes: ['Movie'],
);

CsInstalledPlugin? _installed(ProviderContainer container) => container
    .read(cloudStreamRepositoryProvider)
    .installed
    .where((p) => p.info.internalName == testExtensionInfo.internalName)
    .firstOrNull;

Future<List<int>> _download(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    if (response.statusCode != 200) throw StateError('$url answered ${response.statusCode}');
    return [for (final chunk in await response.toList()) ...chunk];
  } finally {
    client.close();
  }
}

/// Puts the test extension in CloudStream's folder and installed list, loads it, and waits until it
/// has said it has a settings screen.
Future<CsInstalledPlugin> installTestExtension(WidgetTester tester, ProviderContainer container) async {
  if (testExtensionUrl.isEmpty) throw StateError('run with --dart-define=CS3_TEST_EXTENSION=<the .cs3 URL>');
  final host = container.read(cloudStreamEngineHostProvider);
  await tester.runAsync(() async {
    final bytes = await _download(testExtensionUrl);
    final root = (await CloudStreamPaths.root()).path;
    final dir = await Directory('${(await CloudStreamPaths.plugins()).path}/test').create(recursive: true);
    final file = File('${dir.path}/SkyStreamTest.cs3');
    await host.unload(file.path, uninstalling: false);
    if (await file.exists()) await file.delete();
    await file.writeAsBytes(bytes, flush: true);
    // Loaded first, so its record holds what an install's does. One without providers would be a
    // utility plugin's (MegaRepo's), which the app's launch-time pass unloads and runs again.
    final answer = await host.ensureLoaded(file.path, pluginUrl: testExtensionUrl);
    final list = File('$root/installed.json');
    final entries = await list.exists() ? (jsonDecode(await list.readAsString()) as List) : <Object?>[];
    entries.removeWhere((e) => e is Map && (e['info'] as Map?)?['internalName'] == testExtensionInfo.internalName);
    entries.add(
      CsInstalledPlugin(
        info: testExtensionInfo,
        filePath: file.path,
        providers: [
          for (final p in (answer['providers'] as List?) ?? const [])
            if (p is Map) CsProviderInfo.fromJson(Map<String, dynamic>.from(p)),
        ],
        extractors: (answer['extractors'] as num?)?.toInt() ?? 0,
        hasSettings: answer['hasSettings'] as bool?,
      ).toJson(root),
    );
    await list.writeAsString(jsonEncode(entries), flush: true);
    await container.read(cloudStreamRepositoryProvider.notifier).load();
  });
  await pumpUntil(
    tester,
    () => _installed(container)?.hasSettings == true,
    what: 'the test extension said it has settings',
  );
  return _installed(container)!;
}

/// The windows of the last `ui` event among [events].
List<UiWindow> lastWindows(List<Map<String, dynamic>> events) {
  final ui = events.lastWhere((e) => e['event'] == 'ui');
  return [for (final w in ui['windows'] as List) UiWindow.fromJson(Map<String, dynamic>.from(w as Map))];
}

/// The first node under [node] that [test] accepts.
UiNode? findNode(UiNode node, bool Function(UiNode) test) {
  if (test(node)) return node;
  for (final child in node.children) {
    final found = findNode(child, test);
    if (found != null) return found;
  }
  return null;
}
