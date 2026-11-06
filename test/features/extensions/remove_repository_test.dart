/// Removing a repository takes its installed plugins with it.
///
/// The confirmation has always said so - "This will remove the repository
/// and uninstall ALL its plugins" - but removing only dropped the repository
/// from the list, and every plugin installed from it stayed installed and
/// kept running.
///
/// "Its" plugins are the ones installed from it: an install records the
/// repository's id beside the plugin. A plugin installed from another
/// repository stays even when the removed one lists it too, and so does
/// everything installed from a repository that is still in the list under
/// another address, as a raw GitHub link and its jsDelivr mirror would be.
library;

import 'dart:io';

import 'package:dio/dio.dart';
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

const String _zoro = 'https://zoro.test/repo.json';
const String _zoroMirror = 'https://cdn.test/zoro/repo.json';
const String _stars = 'https://stars.test/repo.json';

ExtensionPlugin _plugin(String name, String repositoryId, {int version = 1}) =>
    ExtensionPlugin(
      packageName: 'com.example.${name.toLowerCase()}',
      name: name,
      repositoryId: repositoryId,
      sourceUrl: 'https://example.test/${name.toLowerCase()}-v$version.sky',
      version: version,
    );

class _Web extends RepositoryService {
  _Web(this._ids, this._listings) : super(Dio());

  /// Repository URL to the id its manifest declares.
  final Map<String, String> _ids;
  final Map<String, List<ExtensionPlugin>> _listings;

  @override
  Future<ExtensionRepository?> fetchRepository(String url) async =>
      ExtensionRepository(
        name: _ids[url]!,
        url: url,
        pluginLists: <String>['$url#plugins'],
        explicitId: _ids[url],
      );

  @override
  Future<List<ExtensionPlugin>> getRepoPlugins(
    ExtensionRepository repo,
  ) async => _listings[repo.url] ?? const <ExtensionPlugin>[];
}

class _Disk extends PluginStorageService {
  _Disk(this.installed, {this.undeletable = const <String>{}});

  List<ExtensionPlugin> installed;

  /// Package names whose delete throws, as a locked file would.
  final Set<String> undeletable;
  final List<String> deleted = <String>[];

  @override
  Future<List<ExtensionPlugin>> listInstalledPlugins() async =>
      List<ExtensionPlugin>.of(installed);

  @override
  Future<void> deletePlugin(ExtensionPlugin plugin) async {
    if (undeletable.contains(plugin.packageName)) {
      throw const FileSystemException('Permission denied');
    }
    deleted.add(plugin.packageName);
    installed = <ExtensionPlugin>[
      for (final p in installed)
        if (p.packageName != plugin.packageName) p,
    ];
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

  final alpha = _plugin('Alpha', 'com.zoro');
  final bravo = _plugin('Bravo', 'com.zoro');
  final charlie = _plugin('Charlie', 'com.stars');

  Future<ProviderContainer> open({
    required List<String> saved,
    required Map<String, String> ids,
    required _Disk disk,
    Map<String, List<ExtensionPlugin>> listings =
        const <String, List<ExtensionPlugin>>{},
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: saved,
    });
    final container = ProviderContainer(
      overrides: [
        repositoryServiceProvider.overrideWithValue(_Web(ids, listings)),
        pluginStorageServiceProvider.overrideWithValue(disk),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
        extensionManagerProvider.overrideWith(_NoopExtensionManager.new),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(extensionsControllerProvider.notifier)
        .ensureInitialized();
    return container;
  }

  List<String> installedNames(ProviderContainer container) => <String>[
    for (final plugin
        in container.read(extensionsControllerProvider).installedPlugins)
      plugin.name,
  ];

  test('takes the plugins installed from it, and only those', () async {
    final disk = _Disk(<ExtensionPlugin>[alpha, bravo, charlie]);
    final container = await open(
      saved: <String>[_zoro, _stars],
      ids: <String, String>{_zoro: 'com.zoro', _stars: 'com.stars'},
      disk: disk,
      // Zoro lists Charlie too, but Charlie came from Stars.
      listings: <String, List<ExtensionPlugin>>{
        _zoro: <ExtensionPlugin>[alpha, bravo, _plugin('Charlie', 'com.zoro')],
      },
    );

    await container
        .read(extensionsControllerProvider.notifier)
        .removeRepository(_zoro);

    expect(disk.deleted, <String>['com.example.alpha', 'com.example.bravo']);
    expect(installedNames(container), <String>['Charlie']);
    final state = container.read(extensionsControllerProvider);
    expect(state.repositories.map((r) => r.url), <String>[_stars]);
    expect(state, isNot(isA<ExtensionsError>()));
  });

  test('drops the updates it was offering for them', () async {
    final disk = _Disk(<ExtensionPlugin>[alpha, charlie]);
    final container = await open(
      saved: <String>[_zoro, _stars],
      ids: <String, String>{_zoro: 'com.zoro', _stars: 'com.stars'},
      disk: disk,
      listings: <String, List<ExtensionPlugin>>{
        _zoro: <ExtensionPlugin>[_plugin('Alpha', 'com.zoro', version: 2)],
        _stars: <ExtensionPlugin>[_plugin('Charlie', 'com.stars', version: 2)],
      },
    );
    final controller = container.read(extensionsControllerProvider.notifier);
    await controller.checkForUpdates();
    expect(
      container.read(extensionsControllerProvider).availableUpdates.keys,
      unorderedEquals(<String>['com.example.alpha', 'com.example.charlie']),
    );

    await controller.removeRepository(_zoro);

    expect(
      container.read(extensionsControllerProvider).availableUpdates.keys,
      <String>['com.example.charlie'],
    );
  });

  test(
    'keeps them while the same repository is listed at another address',
    () async {
      final disk = _Disk(<ExtensionPlugin>[alpha, bravo]);
      final container = await open(
        saved: <String>[_zoro, _zoroMirror],
        ids: <String, String>{_zoro: 'com.zoro', _zoroMirror: 'com.zoro'},
        disk: disk,
      );

      await container
          .read(extensionsControllerProvider.notifier)
          .removeRepository(_zoro);

      expect(disk.deleted, isEmpty);
      expect(installedNames(container), <String>['Alpha', 'Bravo']);
    },
  );

  // "Local" is what an install with no repository id - one from a file -
  // reads back as. It names no repository, so one declaring it as its own
  // has no plugins to take with it.
  test('takes nothing by an id that names no repository', () async {
    final fromFile = _plugin('Delta', 'Local');
    final disk = _Disk(<ExtensionPlugin>[fromFile, charlie]);
    final container = await open(
      saved: <String>[_zoro, _stars],
      ids: <String, String>{_zoro: 'Local', _stars: 'com.stars'},
      disk: disk,
    );

    await container
        .read(extensionsControllerProvider.notifier)
        .removeRepository(_zoro);

    expect(disk.deleted, isEmpty);
    expect(installedNames(container), <String>['Delta', 'Charlie']);
  });

  test('one plugin that will not delete does not keep the rest', () async {
    final disk = _Disk(
      <ExtensionPlugin>[alpha, bravo],
      undeletable: <String>{'com.example.alpha'},
    );
    final container = await open(
      saved: <String>[_zoro],
      ids: <String, String>{_zoro: 'com.zoro'},
      disk: disk,
    );

    await container
        .read(extensionsControllerProvider.notifier)
        .removeRepository(_zoro);

    expect(disk.deleted, <String>['com.example.bravo']);
    // Still on disk, so still listed: the user can see it and uninstall it.
    expect(installedNames(container), <String>['Alpha']);
    final state = container.read(extensionsControllerProvider);
    expect(state.repositories, isEmpty);
    expect(
      (await SharedPreferences.getInstance()).getStringList(
        ExtensionsController.repoUrlsKey,
      ),
      isEmpty,
    );
  });
}
