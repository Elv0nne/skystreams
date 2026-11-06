/// A plugin is loaded as one bundled with the app only when it is one.
///
/// `LocalAssets` is the repository id the app gives the plugins it ships in
/// its own assets, which load from there and need no integrity check. A
/// repository can declare that id for itself, and the plugins installed from
/// it carry it; their code is in their install folder like any other, and is
/// checked like any other.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skystream/core/extensions/models/extension_plugin.dart';
import 'package:skystream/core/extensions/services/plugin_storage_service.dart';

late Directory _support;

ExtensionPlugin _tagged(String sourceUrl) => ExtensionPlugin(
  packageName: 'com.example.tagged',
  name: 'Tagged',
  repositoryId: 'LocalAssets',
  sourceUrl: sourceUrl,
  version: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _support = Directory.systemTemp.createTempSync('sky_support');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => _support.path,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    _support.deleteSync(recursive: true);
  });

  test('a plugin the app ships loads from its assets, unchecked', () async {
    final storage = PluginStorageService();
    final bundled = _tagged('assets/plugins/tagged.js');

    expect(await storage.getPluginJsPath(bundled), 'assets/plugins/tagged.js');
    expect(await storage.verifyIntegrity(bundled), isTrue);
  });

  test('an installed plugin tagged as one the app ships loads from its '
      'install folder, and is checked', () async {
    final storage = PluginStorageService();
    final installed = _tagged('https://repo.test/tagged.sky');

    final path = await storage.getPluginJsPath(installed);
    expect(path, endsWith(p.join('com.example.tagged', 'plugin.js')));

    // Its code changed since it was installed.
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('// changed');
    File(p.join(p.dirname(path), 'meta.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'packageName': 'com.example.tagged',
        'installSha256': '0' * 64,
      }),
    );
    expect(await storage.verifyIntegrity(installed), isFalse);
  });
}
