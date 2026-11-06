/// A plugin archive is the plugin its repository listed, or it is not
/// installed.
///
/// The folder an install goes in, and the address it is pinned to, came from
/// the archive's own `plugin.json`. A repository the user installed one
/// plugin from could list an update whose archive names another plugin -
/// one installed from somewhere else - overwrite it, and pin it to itself,
/// all on the launch-time update nobody watches.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/extensions/models/extension_plugin.dart';
import 'package:skystream/core/extensions/models/extension_repository.dart';
import 'package:skystream/core/extensions/providers.dart';
import 'package:skystream/core/extensions/services/plugin_storage_service.dart';
import 'package:skystream/core/extensions/services/repository_service.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/extensions/providers/extensions_controller.dart';

const String _a = 'https://a.test/repo.json';
const String _c = 'https://c.test/repo.json';
const String _xray = 'com.example.xray';
const String _yankee = 'com.example.yankee';

late Directory _support;

/// A `.sky` whose manifest names [packageName], running [js].
String _sky(
  String file, {
  required String packageName,
  required int version,
  required String js,
}) {
  final archive = Archive()
    ..add(
      ArchiveFile.string(
        'plugin.json',
        jsonEncode({
          'packageName': packageName,
          'name': packageName,
          'version': version,
        }),
      ),
    )
    ..add(ArchiveFile.string('plugin.js', js));
  final out = File('${_support.path}/$file.sky')
    ..writeAsBytesSync(ZipEncoder().encode(archive));
  return out.path;
}

/// Repositories by address - the id each declares and what it lists - and
/// the archives their listings point at.
class _Web extends RepositoryService {
  _Web(this.listings, this.files) : super(Dio());

  final Map<String, (String, List<ExtensionPlugin>)> listings;
  final Map<String, String> files;

  @override
  Future<ExtensionRepository?> fetchRepository(String url) async {
    final listing = listings[url];
    if (listing == null) return null;
    return ExtensionRepository(
      name: url,
      url: url,
      pluginLists: <String>['$url#plugins'],
      explicitId: listing.$1,
    );
  }

  @override
  Future<List<ExtensionPlugin>> getRepoPlugins(
    ExtensionRepository repo,
  ) async => [
    for (final plugin in listings[repo.url]?.$2 ?? const <ExtensionPlugin>[])
      plugin.copyWith(repositoryUrl: repo.url),
  ];

  @override
  Future<File?> downloadPlugin(String url) async {
    final source = files[url];
    if (source == null) return null;
    final download = File(
      '${Directory.systemTemp.createTempSync('sky_dl').path}/dl.sky',
    );
    await File(source).copy(download.path);
    return download;
  }
}

class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository() : super(StorageService());

  @override
  bool getDevLoadAssets() => false;
}

class _NoopExtensionManager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => const <SkyStreamProvider>[];

  @override
  Future<void> reloadPlugin(ExtensionPlugin plugin) async {}
}

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

  /// Yankee installed from C and Xray from A, both pinned; A then lists
  /// Xray v2, whose archive says it is Yankee. Returns the storage and a
  /// controller over it.
  Future<(PluginStorageService, ProviderContainer)> setUpTakeover() async {
    final storage = PluginStorageService();
    await storage.installPlugin(
      _sky('y1', packageName: _yankee, version: 1, js: '// C yankee v1'),
      'repo.c',
      repositoryUrl: _c,
    );
    await storage.installPlugin(
      _sky('x1', packageName: _xray, version: 1, js: '// A xray v1'),
      'repo.a',
      repositoryUrl: _a,
    );

    final web = _Web(
      {
        _a: (
          'repo.a',
          [
            ExtensionPlugin(
              packageName: _xray,
              name: 'Xray',
              repositoryId: 'repo.a',
              sourceUrl: 'https://a.test/xray-v2.sky',
              version: 2,
            ),
          ],
        ),
        _c: (
          'repo.c',
          [
            ExtensionPlugin(
              packageName: _yankee,
              name: 'Yankee',
              repositoryId: 'repo.c',
              sourceUrl: 'https://c.test/yankee-v1.sky',
              version: 1,
            ),
          ],
        ),
      },
      {
        'https://a.test/xray-v2.sky': _sky(
          'x2',
          packageName: _yankee,
          version: 2,
          js: '// A code',
        ),
      },
    );

    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: <String>[_a, _c],
    });
    final container = ProviderContainer(
      overrides: [
        repositoryServiceProvider.overrideWithValue(web),
        pluginStorageServiceProvider.overrideWithValue(storage),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
        extensionManagerProvider.overrideWith(_NoopExtensionManager.new),
      ],
    );
    addTearDown(container.dispose);
    return (storage, container);
  }

  Future<(ExtensionPlugin, String)> onDisk(
    PluginStorageService storage,
    String packageName,
  ) async {
    final plugin = (await storage.listInstalledPlugins()).singleWhere(
      (p) => p.packageName == packageName,
    );
    return (
      plugin,
      await File(await storage.getPluginJsPath(plugin)).readAsString(),
    );
  }

  test('a launch-time update whose archive names another plugin installs '
      'nothing', () async {
    final (storage, container) = await setUpTakeover();

    final report = await container
        .read(extensionsControllerProvider.notifier)
        .autoUpdate();

    final (yankee, yankeeJs) = await onDisk(storage, _yankee);
    expect(yankeeJs, '// C yankee v1', reason: 'A replaced C\'s plugin');
    expect(yankee.repositoryUrl, _c, reason: 'A took C\'s plugin over');
    expect(yankee.version, 1);
    final (xray, xrayJs) = await onDisk(storage, _xray);
    expect(xrayJs, '// A xray v1');
    expect(xray.version, 1);
    expect(report.updated, isEmpty);
    expect(
      container.read(extensionsControllerProvider).installingPlugins,
      isEmpty,
      reason: 'the plugin that was being installed is stuck installing',
    );
  });

  test('an install the user asked for fails like any other', () async {
    final (storage, container) = await setUpTakeover();
    final controller = container.read(extensionsControllerProvider.notifier);
    await controller.ensureInitialized();
    final listed = container
        .read(extensionsControllerProvider)
        .availablePlugins[_a]!
        .single;

    await controller.installPlugin(listed);

    final state = container.read(extensionsControllerProvider);
    expect(state, isA<ExtensionsError>());
    expect(state.installingPlugins, isEmpty);
    final (_, yankeeJs) = await onDisk(storage, _yankee);
    expect(yankeeJs, '// C yankee v1');
  });
}
