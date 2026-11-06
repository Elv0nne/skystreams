import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skystream/core/extensions/services/plugin_storage_service.dart';

/// An install keeps the address of the repository it came from, so that only
/// that repository's listing can update the plugin later.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('sky_support');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    support.deleteSync(recursive: true);
  });

  /// A minimal `.sky`: a manifest and its script. [extra] adds keys to the
  /// manifest.
  String sky({Map<String, Object?> extra = const {}}) {
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'plugin.json',
          jsonEncode({
            'packageName': 'com.example.alpha',
            'name': 'Alpha',
            'version': 1,
            ...extra,
          }),
        ),
      )
      ..add(ArchiveFile.string('plugin.js', 'function init() {}'));
    final file = File('${support.path}/alpha.sky')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    return file.path;
  }

  test('keeps the address it was installed from', () async {
    final storage = PluginStorageService();

    final installed = await storage.installPlugin(
      sky(),
      'repo.a',
      repositoryUrl: 'https://a.test/repo.json',
    );

    expect(installed?.repositoryUrl, 'https://a.test/repo.json');
    final listed = await storage.listInstalledPlugins();
    expect(listed.single.repositoryUrl, 'https://a.test/repo.json');
    expect(listed.single.repositoryId, 'repo.a');
  });

  test('an install told no address keeps none', () async {
    final storage = PluginStorageService();

    await storage.installPlugin(sky(), 'repo.a');

    expect((await storage.listInstalledPlugins()).single.repositoryUrl, isNull);
  });

  // The address is the install's own record. A plugin's manifest is the
  // plugin's say, and would let it name the repository its updates come from.
  group('the address is never read from the plugin', () {
    /// A plugin folder written straight to disk, as an older install or a
    /// damaged one leaves it.
    Directory folder(Map<String, Object?> files) {
      final dir = Directory(
        '${support.path}/extensions/plugin/com.example.alpha',
      )..createSync(recursive: true);
      for (final MapEntry(key: name, value: content) in files.entries) {
        File('${dir.path}/$name').writeAsStringSync(jsonEncode(content));
      }
      File('${dir.path}/plugin.js').writeAsStringSync('function init() {}');
      return dir;
    }

    test('an archive naming its own address keeps none', () async {
      final storage = PluginStorageService();

      final installed = await storage.installPlugin(
        sky(extra: {'repositoryUrl': 'https://evil.test/repo.json'}),
        'repo.a',
      );

      expect(installed?.repositoryUrl, isNull);
      expect(
        (await storage.listInstalledPlugins()).single.repositoryUrl,
        isNull,
      );
    });

    test('an archive with an address that is not text still installs, with '
        'the address it was given', () async {
      final storage = PluginStorageService();

      final installed = await storage.installPlugin(
        sky(extra: {'repositoryUrl': 5}),
        'repo.a',
        repositoryUrl: 'https://a.test/repo.json',
      );

      expect(installed?.repositoryUrl, 'https://a.test/repo.json');
      expect(
        (await storage.listInstalledPlugins()).single.repositoryUrl,
        'https://a.test/repo.json',
      );
    });

    test('an install record whose address is not text is listed without '
        'one', () async {
      folder({
        'meta.json': {
          'packageName': 'com.example.alpha',
          'name': 'Alpha',
          'version': 1,
          'repositoryId': 'repo.a',
          'repositoryUrl': {'a': 1},
        },
      });

      final listed = await PluginStorageService().listInstalledPlugins();

      expect(listed.single.packageName, 'com.example.alpha');
      expect(listed.single.repositoryUrl, isNull);
    });

    test('a plugin found without an install record takes no address from its '
        'manifest, then or later', () async {
      folder({
        'plugin.json': {
          'packageName': 'com.example.alpha',
          'name': 'Alpha',
          'version': 1,
          'repositoryUrl': 'https://evil.test/repo.json',
        },
      });
      final storage = PluginStorageService();

      final first = await storage.listInstalledPlugins();
      // The second reads the install record the first wrote.
      final second = await storage.listInstalledPlugins();

      expect(first.single.repositoryUrl, isNull);
      expect(second.single.repositoryUrl, isNull);
    });
  });

  // The folder an install goes in, and the plugin it replaces, are named by
  // the archive itself: one listed as another plugin would overwrite that
  // plugin and take it over.
  group('an archive is the plugin it was listed as', () {
    /// Everything under the plugin root: each path, and a file's contents.
    Map<String, String> snapshot() {
      final root = Directory('${support.path}/extensions/plugin');
      return {
        for (final entity in root.listSync(recursive: true))
          p.relative(entity.path, from: root.path): entity is File
              ? entity.readAsStringSync()
              : '(folder)',
      };
    }

    test('one that names another plugin is refused, and nothing on disk '
        'changes', () async {
      final storage = PluginStorageService();
      await storage.installPlugin(
        sky(),
        'repo.c',
        repositoryUrl: 'https://c.test/repo.json',
      );
      final before = snapshot();

      await expectLater(
        storage.installPlugin(
          sky(extra: {'version': 2}),
          'repo.a',
          repositoryUrl: 'https://a.test/repo.json',
          packageName: 'com.example.xray',
        ),
        throwsA(isA<Exception>()),
      );

      expect(snapshot(), before);
    });

    test('one that names the plugin it was listed as installs', () async {
      final storage = PluginStorageService();

      final installed = await storage.installPlugin(
        sky(),
        'repo.a',
        repositoryUrl: 'https://a.test/repo.json',
        packageName: 'com.example.alpha',
      );

      expect(installed?.packageName, 'com.example.alpha');
      expect(
        (await storage.listInstalledPlugins()).single.repositoryUrl,
        'https://a.test/repo.json',
      );
    });
  });

  // An install from before the address was kept is given one, once, when the
  // repository it came from is known; one that has an address keeps it.
  group('an older install', () {
    File record() =>
        File('${support.path}/extensions/plugin/com.example.alpha/meta.json');

    test('is given the address it came from, its record otherwise as it '
        'was', () async {
      // As installs were written before addresses were kept: no key at all.
      record()
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'packageName': 'com.example.alpha',
            'name': 'Alpha',
            'version': 3,
            'repositoryId': 'repo.a',
            'installSha256': 'abc',
          }),
        );
      final storage = PluginStorageService();
      final older = (await storage.listInstalledPlugins()).single;

      final pinned = await storage.pinRepositoryUrl(
        older,
        'https://a.test/repo.json',
      );

      expect(pinned?.repositoryUrl, 'https://a.test/repo.json');
      final listed = (await storage.listInstalledPlugins()).single;
      expect(listed.repositoryUrl, 'https://a.test/repo.json');
      expect(listed.version, 3);
      expect(listed.repositoryId, 'repo.a');
      expect(
        jsonDecode(record().readAsStringSync()),
        containsPair('installSha256', 'abc'),
      );
    });

    test('that has an address keeps it', () async {
      final storage = PluginStorageService();
      await storage.installPlugin(
        sky(),
        'repo.a',
        repositoryUrl: 'https://b.test/repo.json',
      );
      final installed = (await storage.listInstalledPlugins()).single;

      final pinned = await storage.pinRepositoryUrl(
        installed,
        'https://a.test/repo.json',
      );

      expect(pinned, isNull);
      expect(
        (await storage.listInstalledPlugins()).single.repositoryUrl,
        'https://b.test/repo.json',
      );
    });
  });
}
