/// What a launch does to the user's plugins.
///
/// The latest plugins are what the app's core job - finding something to
/// play - runs on, so every launch brings them up to date, on any connection,
/// however recently the last launch did. It happens in two steps. The check
/// *finds* updates and records them in `availableUpdates`; the launch then
/// installs what it found, one plugin at a time, and names the ones that went
/// in. A plugin that will not install is left offered on the Extensions
/// screen, and does not hold the others back.
///
/// For a while the check ran at most every six hours, never on a metered
/// connection, and installed nothing without the user going to the Extensions
/// screen for it. That left users on stale scrapers, and is gone.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/extensions/models/extension_plugin.dart';
import 'package:skystream/core/extensions/models/extension_repository.dart';
import 'package:skystream/core/extensions/providers.dart';
import 'package:skystream/core/extensions/services/plugin_storage_service.dart';
import 'package:skystream/core/extensions/services/repository_service.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/extensions/providers/extensions_controller.dart';

const String _repoUrl = 'https://example.test/repo.json';
const String _packageName = 'com.example.superstream';

ExtensionPlugin _plugin(
  int version, {
  String packageName = _packageName,
  String name = 'SuperStream',
}) => ExtensionPlugin(
  packageName: packageName,
  name: name,
  repositoryId: 'com.example',
  sourceUrl: 'https://example.test/$packageName-v$version.sky',
  version: version,
);

/// Records every network verb the controller reaches for, and can be made slow
/// so overlapping calls are observable.
class _FakeRepositoryService extends RepositoryService {
  _FakeRepositoryService({
    this.online = const <ExtensionPlugin>[],
    this.fetchDelay = Duration.zero,
    this.brokenDownloads = const <String>{},
  }) : super(Dio());

  final List<ExtensionPlugin> online;
  final Duration fetchDelay;

  /// Source URLs whose download throws, as a dead mirror does.
  final Set<String> brokenDownloads;

  final List<String> fetchCalls = <String>[];
  final List<String> downloadCalls = <String>[];

  /// How many `fetchRepository` calls were ever in flight at the same moment.
  int peakConcurrency = 0;
  int _inFlight = 0;

  @override
  Future<ExtensionRepository?> fetchRepository(String url) async {
    fetchCalls.add(url);
    _inFlight++;
    peakConcurrency = _inFlight > peakConcurrency ? _inFlight : peakConcurrency;
    try {
      if (fetchDelay > Duration.zero) await Future<void>.delayed(fetchDelay);
      return ExtensionRepository(
        name: 'Example',
        url: url,
        pluginLists: const <String>[],
        explicitId: 'com.example',
      );
    } finally {
      _inFlight--;
    }
  }

  @override
  Future<List<ExtensionPlugin>> getRepoPlugins(
    ExtensionRepository repo,
  ) async => online;

  /// A real file, so the ablation's install path runs to completion instead of
  /// bailing out early and looking like the fix.
  /// A real file, so the install path runs to completion. It carries the URL
  /// it came from, which is how the fake store knows what it is installing.
  @override
  Future<File?> downloadPlugin(String url) async {
    downloadCalls.add(url);
    if (brokenDownloads.contains(url)) {
      throw const SocketException('Connection reset by peer');
    }
    final file = File(
      '${Directory.systemTemp.createTempSync('sky_plugin').path}/plugin.sky',
    );
    await file.writeAsString(url);
    return file;
  }
}

class _FakePluginStorageService extends PluginStorageService {
  _FakePluginStorageService(this._installed, this._online);

  List<ExtensionPlugin> _installed;
  final List<ExtensionPlugin> _online;
  final List<String> installCalls = <String>[];

  @override
  Future<List<ExtensionPlugin>> listInstalledPlugins() async =>
      List<ExtensionPlugin>.of(_installed);

  @override
  Future<ExtensionPlugin?> installPlugin(
    String filePath,
    String? explicitRepoId, {
    String? repositoryUrl,
    String? packageName,
  }) async {
    installCalls.add(filePath);
    final url = await File(filePath).readAsString();
    final plugin = _online.firstWhere((p) => p.sourceUrl == url);
    // What a real install does: the newer plugin replaces the older one on
    // disk, so the next listing reports it.
    _installed = <ExtensionPlugin>[
      for (final p in _installed)
        if (p.packageName != plugin.packageName) p,
      plugin,
    ];
    return plugin;
  }
}

class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository() : super(StorageService());

  @override
  bool getDevLoadAssets() => false;
}

/// The JS engine is not under test here, and constructing the real one spawns
/// an isolate. The ablation runs through `reloadPlugin`, so it has to exist.
class _NoopExtensionManager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => const <SkyStreamProvider>[];

  @override
  Future<void> reloadPlugin(ExtensionPlugin plugin) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRepositoryService repos;
  late _FakePluginStorageService plugins;

  ProviderContainer boot({
    List<ExtensionPlugin> installed = const <ExtensionPlugin>[],
    List<ExtensionPlugin> online = const <ExtensionPlugin>[],
    Map<String, Object> prefs = const <String, Object>{},
    Duration fetchDelay = Duration.zero,
    Set<String> brokenDownloads = const <String>{},
  }) {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: <String>[_repoUrl],
      ...prefs,
    });
    repos = _FakeRepositoryService(
      online: online,
      fetchDelay: fetchDelay,
      brokenDownloads: brokenDownloads,
    );
    plugins = _FakePluginStorageService(installed, online);

    final container = ProviderContainer(
      overrides: [
        repositoryServiceProvider.overrideWithValue(repos),
        pluginStorageServiceProvider.overrideWithValue(plugins),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
        extensionManagerProvider.overrideWith(_NoopExtensionManager.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('the check only finds updates; installing is its own step', () async {
    final container = boot(
      installed: <ExtensionPlugin>[_plugin(1)],
      online: <ExtensionPlugin>[_plugin(2)],
    );

    final controller = container.read(extensionsControllerProvider.notifier);
    await controller.ensureInitialized();
    final pending = await controller.checkForUpdates();

    // Found, and nothing downloaded yet: the install is a separate step, so a
    // caller can check without installing.
    expect(repos.downloadCalls, isEmpty);
    expect(plugins.installCalls, isEmpty);

    final state = container.read(extensionsControllerProvider);
    expect(state.installedPlugins.single.version, 1);
    expect(state.availableUpdates[_packageName]?.version, 2);
    expect(pending, <String>['SuperStream']);
  });

  test('what the check found is installed, and named', () async {
    final container = boot(
      installed: <ExtensionPlugin>[_plugin(1)],
      online: <ExtensionPlugin>[_plugin(2)],
    );
    final report = await container
        .read(extensionsControllerProvider.notifier)
        .autoUpdate();

    expect(report.updated, <String>['SuperStream']);
    expect(repos.downloadCalls, <String>[_plugin(2).sourceUrl]);
    final state = container.read(extensionsControllerProvider);
    expect(state.installedPlugins.single.version, 2);
    expect(state.availableUpdates, isEmpty);
  });

  test(
    'a plugin that will not install stays offered and holds nobody back',
    () async {
      final broken = _plugin(2, packageName: 'com.example.a', name: 'Alpha');
      final fine = _plugin(2, packageName: 'com.example.b', name: 'Bravo');
      final container = boot(
        installed: <ExtensionPlugin>[
          _plugin(1, packageName: 'com.example.a', name: 'Alpha'),
          _plugin(1, packageName: 'com.example.b', name: 'Bravo'),
        ],
        online: <ExtensionPlugin>[broken, fine],
        brokenDownloads: <String>{broken.sourceUrl},
      );
      final report = await container
          .read(extensionsControllerProvider.notifier)
          .autoUpdate();

      expect(report.updated, <String>['Bravo']);
      final state = container.read(extensionsControllerProvider);
      expect(
        state,
        isNot(isA<ExtensionsError>()),
        reason: 'a background update raised the Extensions error dialog',
      );
      expect(state.availableUpdates.keys, <String>['com.example.a']);
      expect(state.installingPlugins, isEmpty);
    },
  );

  test('nothing newer means nothing offered', () async {
    final container = boot(
      installed: <ExtensionPlugin>[_plugin(2)],
      online: <ExtensionPlugin>[_plugin(2)],
    );

    final report = await container
        .read(extensionsControllerProvider.notifier)
        .autoUpdate();

    expect(report.updated, isEmpty);
    expect(
      container.read(extensionsControllerProvider).availableUpdates,
      isEmpty,
    );
    expect(repos.downloadCalls, isEmpty);
  });

  test('a launch straight after another still checks', () async {
    // What an install that last checked a minute ago carries in its
    // preferences, under the key the six-hour gate used to read.
    final justNow = DateTime.now().subtract(const Duration(minutes: 1));
    final container = boot(
      installed: <ExtensionPlugin>[_plugin(1)],
      online: <ExtensionPlugin>[_plugin(2)],
      prefs: <String, Object>{
        'extensions_last_update_check': justNow.millisecondsSinceEpoch,
      },
    );

    final report = await container
        .read(extensionsControllerProvider.notifier)
        .autoUpdate();
    expect(report.updated, <String>['SuperStream']);
    expect(repos.fetchCalls, <String>[_repoUrl]);

    // Nothing records the time of a check any more; there is nothing left to
    // read it.
    final store = await SharedPreferences.getInstance();
    expect(
      store.getInt('extensions_last_update_check'),
      justNow.millisecondsSinceEpoch,
    );
  });

  test('no repositories means no work at all', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = boot(prefs: <String, Object>{});
    // boot() seeds one URL; clear it to model a fresh install.
    await (await SharedPreferences.getInstance()).remove(
      ExtensionsController.repoUrlsKey,
    );

    final report = await container
        .read(extensionsControllerProvider.notifier)
        .autoUpdate();
    expect(report.isEmpty, isTrue);
    expect(repos.fetchCalls, isEmpty);
  });

  test(
    'repositories are fetched concurrently, not one after another',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ExtensionsController.repoUrlsKey: <String>[
          'https://a.test/r.json',
          'https://b.test/r.json',
          'https://c.test/r.json',
        ],
      });
      repos = _FakeRepositoryService(
        fetchDelay: const Duration(milliseconds: 50),
      );
      plugins = _FakePluginStorageService(
        const <ExtensionPlugin>[],
        const <ExtensionPlugin>[],
      );
      final container = ProviderContainer(
        overrides: [
          repositoryServiceProvider.overrideWithValue(repos),
          pluginStorageServiceProvider.overrideWithValue(plugins),
          settingsRepositoryProvider.overrideWithValue(
            _FakeSettingsRepository(),
          ),
          extensionManagerProvider.overrideWith(_NoopExtensionManager.new),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(extensionsControllerProvider.notifier)
          .ensureInitialized();

      expect(
        repos.peakConcurrency,
        3,
        reason: 'three repositories still cost three round trips end to end',
      );
      // Order is the persisted order, not the order the network answered in.
      expect(
        container
            .read(extensionsControllerProvider)
            .repositories
            .map((ExtensionRepository r) => r.url),
        <String>[
          'https://a.test/r.json',
          'https://b.test/r.json',
          'https://c.test/r.json',
        ],
      );
    },
  );
}
