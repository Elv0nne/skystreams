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

/// Where a plugin's updates may come from: the repository it was installed
/// from, and nowhere else.
///
/// Updates used to be matched by the plugin's name across every repository
/// the user follows - including the ones a collection adds on its own - so
/// any of them could replace another's plugin with code of its own, and the
/// launch-time update would install it.
const String _a = 'https://a.test/repo.json';
const String _b = 'https://b.test/repo.json';
const String _alpha = 'com.example.alpha';

ExtensionPlugin _listed(String repoId, int version) => ExtensionPlugin(
  packageName: _alpha,
  name: 'Alpha',
  repositoryId: repoId,
  sourceUrl: 'https://cdn.test/$repoId/alpha-v$version.sky',
  version: version,
);

ExtensionPlugin _installed({String? from, String repoId = 'repo.a'}) =>
    ExtensionPlugin(
      packageName: _alpha,
      name: 'Alpha',
      repositoryId: repoId,
      repositoryUrl: from,
      sourceUrl: 'https://cdn.test/$repoId/alpha-v1.sky',
      version: 1,
    );

/// Another plugin, [name], as a repository lists it or, with [from], as it
/// is installed.
ExtensionPlugin _plugin(
  String name,
  String repoId,
  int version, {
  String? from,
}) => ExtensionPlugin(
  packageName: 'com.example.${name.toLowerCase()}',
  name: name,
  repositoryId: repoId,
  repositoryUrl: from,
  sourceUrl: 'https://cdn.test/$repoId/${name.toLowerCase()}-v$version.sky',
  version: version,
);

/// Repositories by address: the id each one declares, and what it lists.
class _Web extends RepositoryService {
  _Web(this.repos) : super(Dio());

  final Map<String, (String id, List<ExtensionPlugin> plugins)> repos;

  @override
  Future<ExtensionRepository?> fetchRepository(String url) async {
    final repo = repos[url];
    if (repo == null) return null;
    return ExtensionRepository(
      name: url,
      url: url,
      pluginLists: <String>['$url#plugins'],
      explicitId: repo.$1,
    );
  }

  /// As the real service does, each listed plugin carries the address of the
  /// repository that listed it.
  @override
  Future<List<ExtensionPlugin>> getRepoPlugins(
    ExtensionRepository repo,
  ) async => [
    for (final plugin in repos[repo.url]?.$2 ?? const <ExtensionPlugin>[])
      plugin.copyWith(repositoryUrl: repo.url),
  ];

  @override
  Future<File?> downloadPlugin(String url) async {
    final file = File(
      '${Directory.systemTemp.createTempSync('sky_plugin').path}/plugin.sky',
    );
    await file.writeAsString(url);
    return file;
  }
}

class _Disk extends PluginStorageService {
  _Disk(this.installed);

  final List<ExtensionPlugin> installed;

  /// The address each install was told it came from.
  final List<String?> installedFrom = <String?>[];

  /// The address each older install was to be pinned to, by package name.
  /// None is written, so the update check is left to match it by id.
  final Map<String, String> pinRequests = <String, String>{};

  @override
  Future<List<ExtensionPlugin>> listInstalledPlugins() async =>
      List<ExtensionPlugin>.of(installed);

  @override
  Future<ExtensionPlugin?> pinRepositoryUrl(
    ExtensionPlugin plugin,
    String repositoryUrl,
  ) async {
    pinRequests[plugin.packageName] = repositoryUrl;
    return null;
  }

  @override
  Future<ExtensionPlugin?> installPlugin(
    String filePath,
    String? explicitRepoId, {
    String? repositoryUrl,
    String? packageName,
  }) async {
    installedFrom.add(repositoryUrl);
    return null;
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

  late _Disk disk;

  /// A launch with [installed] - and [alsoInstalled] - on disk and both
  /// repositories followed; returns what the update check offers, by package
  /// name.
  Future<(ProviderContainer, Map<String, ExtensionPlugin>)> check(
    Map<String, (String, List<ExtensionPlugin>)> repos, {
    required ExtensionPlugin installed,
    List<ExtensionPlugin> alsoInstalled = const <ExtensionPlugin>[],
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: <String>[_a, _b],
    });
    disk = _Disk(<ExtensionPlugin>[installed, ...alsoInstalled]);
    final container = ProviderContainer(
      overrides: [
        repositoryServiceProvider.overrideWithValue(_Web(repos)),
        pluginStorageServiceProvider.overrideWithValue(disk),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
        extensionManagerProvider.overrideWith(_NoopExtensionManager.new),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(extensionsControllerProvider.notifier);
    await controller.ensureInitialized();
    await controller.checkForUpdates();
    return (
      container,
      container.read(extensionsControllerProvider).availableUpdates,
    );
  }

  test('a plugin is updated only from the repository it came from', () async {
    final (_, updates) = await check({
      _a: ('repo.a', [_listed('repo.a', 1)]),
      _b: ('repo.b', [_listed('repo.b', 9)]),
    }, installed: _installed(from: _a));

    expect(updates, isEmpty);
  });

  test('another repository taking the same id changes nothing', () async {
    final (_, updates) = await check({
      _a: ('repo.a', [_listed('repo.a', 1)]),
      _b: ('repo.a', [_listed('repo.a', 9)]),
    }, installed: _installed(from: _a));

    expect(updates, isEmpty);
  });

  test('the newest version its own repository lists is the update', () async {
    final (_, updates) = await check({
      _a: ('repo.a', [_listed('repo.a', 3), _listed('repo.a', 2)]),
      _b: ('repo.b', [_listed('repo.b', 9)]),
    }, installed: _installed(from: _a));

    expect(updates[_alpha]?.version, 3);
    expect(updates[_alpha]?.repositoryUrl, _a);
  });

  test('an install from before the address was kept is matched by its '
      "repository's id", () async {
    final (_, updates) = await check({
      _a: ('repo.a', [_listed('repo.a', 2)]),
      _b: ('repo.b', [_listed('repo.b', 9)]),
    }, installed: _installed());

    expect(updates[_alpha]?.version, 2);
    expect(updates[_alpha]?.repositoryUrl, _a);
  });

  test(
    'an older install is not updated when two repositories claim its id',
    () async {
      final (_, updates) = await check({
        _a: ('repo.a', [_listed('repo.a', 2)]),
        _b: ('repo.a', [_listed('repo.a', 9)]),
      }, installed: _installed());

      expect(updates, isEmpty);
    },
  );

  // An id is whatever a repository says it is. Counting only the
  // repositories that list the plugin let one claiming another's id update
  // that one's plugins whenever the real one failed to load or stopped
  // listing them.
  group('an install from before the address was kept', () {
    test('is not updated by a repository taking its id while its own is '
        'missing', () async {
      final (_, updates) = await check({
        _b: ('repo.a', [_listed('repo.a', 9)]),
      }, installed: _installed());

      expect(updates, isEmpty);
    });

    test('is not updated by a repository taking its id when its own no longer '
        'lists it', () async {
      final (_, updates) = await check({
        _a: ('repo.a', const <ExtensionPlugin>[]),
        _b: ('repo.a', [_listed('repo.a', 9)]),
      }, installed: _installed());

      expect(updates, isEmpty);
    });

    test('is not updated at all on a launch where a saved repository did not '
        'load', () async {
      // The one missing may be a second claimant to the id.
      final (_, updates) = await check({
        _a: ('repo.a', [_listed('repo.a', 2)]),
      }, installed: _installed());

      expect(updates, isEmpty);
    });

    test('installed from a file is not updated by a repository declaring a '
        'file install\'s id as its own', () async {
      // "Local" is what an install with no repository id reads back as.
      final (_, updates) = await check({
        _a: ('Local', [_listed('Local', 9)]),
        _b: ('repo.b', const <ExtensionPlugin>[]),
      }, installed: _installed(repoId: 'Local'));

      expect(updates, isEmpty);
      expect(disk.pinRequests, isEmpty);
    });

    test('leaves an install that kept its address to update as ever', () async {
      final (_, updates) = await check({
        _a: ('repo.a', [_listed('repo.a', 2)]),
      }, installed: _installed(from: _a));

      expect(updates[_alpha]?.version, 2);
    });
  });

  // Repositories list many plugins: a pinned install's update is its own
  // entry in its own repository's listing, not whatever is newest there.
  group('with several plugins to a repository', () {
    test('another plugin listed at a higher version is no update', () async {
      final (_, updates) = await check({
        _a: ('repo.a', [_listed('repo.a', 1), _plugin('Bravo', 'repo.a', 7)]),
        _b: ('repo.b', const <ExtensionPlugin>[]),
      }, installed: _installed(from: _a));

      expect(updates, isEmpty);
    });

    test('the newest of its own entries is the update', () async {
      final (_, updates) = await check({
        _a: (
          'repo.a',
          [
            _plugin('Bravo', 'repo.a', 7),
            _listed('repo.a', 3),
            _plugin('Charlie', 'repo.a', 5),
          ],
        ),
        _b: ('repo.b', const <ExtensionPlugin>[]),
      }, installed: _installed(from: _a));

      expect(updates.keys, <String>[_alpha]);
      expect(updates[_alpha]?.packageName, _alpha);
      expect(updates[_alpha]?.version, 3);
    });

    test('each install takes its update from its own repository', () async {
      final (_, updates) = await check(
        {
          _a: (
            'repo.a',
            [
              _listed('repo.a', 2),
              _plugin('Bravo', 'repo.a', 2),
              _plugin('Charlie', 'repo.a', 9),
            ],
          ),
          _b: (
            'repo.b',
            [_listed('repo.b', 9), _plugin('Charlie', 'repo.b', 3)],
          ),
        },
        installed: _installed(from: _a),
        alsoInstalled: [
          _plugin('Bravo', 'repo.a', 2, from: _a),
          _plugin('Charlie', 'repo.b', 1, from: _b),
        ],
      );

      expect(
        {
          for (final MapEntry(key: name, value: update) in updates.entries)
            name: (update.version, update.repositoryUrl),
        },
        {_alpha: (2, _a), 'com.example.charlie': (3, _b)},
      );
    });
  });

  // One repository's address spelled two ways - typed, from a share link,
  // as a server echoes it - is one repository. Another scheme, port, path,
  // query or fragment is another address.
  group('two addresses are one repository', () {
    const same = <(String, String)>[
      ('HTTPS://a.test/repo.json', 'https://a.test/repo.json'),
      ('https://A.Test/repo.json', 'https://a.test/repo.json'),
      ('https://a.test:443/repo.json', 'https://a.test/repo.json'),
      ('http://a.test:80/repo.json', 'http://a.test/repo.json'),
      ('https://a.test/%7Erepo.json', 'https://a.test/~repo.json'),
      ('https://a.test/r%c3%a9po.json', 'https://a.test/r%C3%A9po.json'),
      ('https://a.test/repo/', 'https://a.test/repo'),
      (' https://a.test/repo.json ', 'https://a.test/repo.json'),
    ];
    const different = <(String, String)>[
      ('http://a.test/repo.json', 'https://a.test/repo.json'),
      ('https://a.test:8443/repo.json', 'https://a.test/repo.json'),
      ('https://a.test/Repo.json', 'https://a.test/repo.json'),
      ('https://a.test/repo.json?v=2', 'https://a.test/repo.json'),
      ('https://a.test/repo.json?v=2', 'https://a.test/repo.json?v=3'),
      ('https://a.test/repo.json#main', 'https://a.test/repo.json'),
      ('https://b.test/repo.json', 'https://a.test/repo.json'),
    ];

    test('when only the spelling differs', () {
      for (final (one, other) in same) {
        expect(
          ExtensionsController.sameAddress(one, other),
          isTrue,
          reason: '$one | $other',
        );
        expect(
          ExtensionsController.sameAddress(other, one),
          isTrue,
          reason: '$other | $one',
        );
      }
    });

    test('not when the address differs', () {
      for (final (one, other) in different) {
        expect(
          ExtensionsController.sameAddress(one, other),
          isFalse,
          reason: '$one | $other',
        );
        expect(
          ExtensionsController.sameAddress(other, one),
          isFalse,
          reason: '$other | $one',
        );
      }
    });

    test('so a pin spelled another way still finds its updates', () async {
      final (_, updates) = await check({
        _a: ('repo.a', [_listed('repo.a', 2)]),
        _b: ('repo.b', const <ExtensionPlugin>[]),
      }, installed: _installed(from: 'HTTPS://A.TEST:443/repo.json/'));

      expect(updates[_alpha]?.version, 2);
    });
  });

  test('an update records the address it came from', () async {
    final (container, _) = await check({
      _a: ('repo.a', [_listed('repo.a', 2)]),
      _b: ('repo.b', const <ExtensionPlugin>[]),
    }, installed: _installed());

    await container
        .read(extensionsControllerProvider.notifier)
        .installAvailableUpdates();

    expect(disk.installedFrom, <String?>[_a]);
  });
}
