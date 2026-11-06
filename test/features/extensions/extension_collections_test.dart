/// Repositories and plugins that appear after the user set things up.
///
/// A collection - a repository that lists other repositories instead of
/// plugins, as the "universe" shortcode does - used to be read once, when it
/// was added, and never again: a repository published into it afterwards
/// never reached anyone who already had it. Every launch now reads each
/// collection the user added and adds what it newly lists, and a toast says
/// so. A repository the user removed stays removed, and a collection whose
/// repositories the user has removed, every one, is no longer followed.
///
/// Plugins that appear in a repository the user has are announced too, under
/// the repository's name. Announced, not installed: which plugins to run is
/// the user's call. Nothing is announced on the first launch that looks,
/// which is only learning what is already there.
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
import 'package:skystream/core/models/extension_update_report.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/extensions/providers/extensions_controller.dart';

/// What the user typed to add the collection. This fake web reads it as an
/// address, so it is also the key the collection is stored under. (The real
/// service finds a code's short link, which the collection is kept as - see
/// shortcode_repository_test.dart.)
const String _universe = 'universe';
const String _mini = 'https://mini.test/collection.json';
const String _a = 'https://a.test/repo.json';
const String _b = 'https://b.test/repo.json';
const String _c = 'https://c.test/repo.json';

ExtensionPlugin _plugin(String name) => ExtensionPlugin(
  packageName: 'com.example.${name.toLowerCase()}',
  name: name,
  repositoryId: 'com.example',
  sourceUrl: 'https://example.test/${name.toLowerCase()}.sky',
  version: 1,
);

/// Every repository and collection there is, as the app would find them.
/// Tests republish entries between launches to model upstream edits.
class _Web extends RepositoryService {
  _Web() : super(Dio());

  final Map<String, ExtensionRepository> _published =
      <String, ExtensionRepository>{};
  final Map<String, List<ExtensionPlugin>> _plugins =
      <String, List<ExtensionPlugin>>{};

  /// URLs that do not answer, as a host that is down does.
  final Set<String> down = <String>{};

  /// URLs whose manifest fails validation, as one mid-edit does.
  final Set<String> broken = <String>{};

  final List<String> fetchCalls = <String>[];
  final List<String> downloadCalls = <String>[];

  void repo(String url, String name, List<ExtensionPlugin> plugins) {
    _published[url] = ExtensionRepository(
      name: name,
      url: url,
      pluginLists: <String>['$url#plugins'],
      explicitId: 'repo.${name.toLowerCase().replaceAll(' ', '')}',
    );
    _plugins[url] = plugins;
  }

  void collection(String url, String name, List<String> listed) {
    _published[url] = ExtensionRepository(
      name: name,
      url: url,
      pluginLists: const <String>[],
      includedRepos: listed,
      explicitId: 'collection.${name.toLowerCase()}',
    );
  }

  @override
  Future<ExtensionRepository?> fetchRepository(String url) async {
    fetchCalls.add(url);
    if (broken.contains(url)) {
      throw Exception('Invalid repository format: Missing name');
    }
    if (down.contains(url)) return null;
    return _published[url];
  }

  @override
  Future<List<ExtensionPlugin>> getRepoPlugins(
    ExtensionRepository repo,
  ) async => List<ExtensionPlugin>.of(_plugins[repo.url] ?? const []);

  @override
  Future<File?> downloadPlugin(String url) async {
    downloadCalls.add(url);
    return null;
  }
}

class _Disk extends PluginStorageService {
  _Disk(this._installed);

  final List<ExtensionPlugin> _installed;

  @override
  Future<List<ExtensionPlugin>> listInstalledPlugins() async =>
      List<ExtensionPlugin>.of(_installed);
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

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// One run of the app: a fresh controller over the preferences the last run
  /// left behind.
  ProviderContainer app(
    _Web web, {
    List<ExtensionPlugin> installed = const <ExtensionPlugin>[],
  }) {
    final container = ProviderContainer(
      overrides: [
        repositoryServiceProvider.overrideWithValue(web),
        pluginStorageServiceProvider.overrideWithValue(_Disk(installed)),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
        extensionManagerProvider.overrideWith(_NoopExtensionManager.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// A cold start's background pass, as `main.dart` runs it.
  Future<(ProviderContainer, ExtensionUpdateReport)> launch(
    _Web web, {
    List<ExtensionPlugin> installed = const <ExtensionPlugin>[],
  }) async {
    final container = app(web, installed: installed);
    final report = await container
        .read(extensionsControllerProvider.notifier)
        .autoUpdate();
    return (container, report);
  }

  Future<List<String>> savedRepositories() async =>
      (await SharedPreferences.getInstance()).getStringList(
        ExtensionsController.repoUrlsKey,
      ) ??
      const <String>[];

  group('a collection', () {
    test('is read on every launch, and what it newly lists is added', () async {
      final web = _Web()
        ..collection(_universe, 'Universe', <String>[_a, _b])
        ..repo(_a, 'Repo A', <ExtensionPlugin>[_plugin('Alpha')])
        ..repo(_b, 'Repo B', <ExtensionPlugin>[_plugin('Bravo')]);
      await app(web)
          .read(extensionsControllerProvider.notifier)
          .addRepository(_universe);
      expect(await savedRepositories(), <String>[_a, _b]);

      // Upstream, someone publishes a new repository into the collection.
      web
        ..collection(_universe, 'Universe', <String>[_a, _b, _c])
        ..repo(_c, 'Repo C', <ExtensionPlugin>[_plugin('Charlie')]);
      final (container, report) = await launch(web);

      expect(report.newRepositories, <String, List<String>>{
        'Universe': <String>['Repo C'],
      });
      expect(await savedRepositories(), <String>[_a, _b, _c]);
      final state = container.read(extensionsControllerProvider);
      expect(state.repositories.map((r) => r.url), <String>[_a, _b, _c]);
      expect(state.availablePlugins[_c]?.single.name, 'Charlie');
      // Its arrival is the news; its plugins are offered, not installed, and
      // not announced a second time as new plugins.
      expect(report.newPlugins, isEmpty);
      expect(web.downloadCalls, isEmpty);

      // Said once.
      final (_, next) = await launch(web);
      expect(next.isEmpty, isTrue);
    });

    test('does not bring back a repository the user removed', () async {
      final web = _Web()
        ..collection(_universe, 'Universe', <String>[_a, _b])
        ..repo(_a, 'Repo A', const <ExtensionPlugin>[])
        ..repo(_b, 'Repo B', const <ExtensionPlugin>[]);
      final session = app(web).read(extensionsControllerProvider.notifier);
      await session.addRepository(_universe);
      await session.removeRepository(_b);

      web.fetchCalls.clear();
      final (_, report) = await launch(web);

      expect(report.newRepositories, isEmpty);
      expect(await savedRepositories(), <String>[_a]);
      expect(web.fetchCalls, isNot(contains(_b)));
    });

    test('added again brings back what the user had removed from it', () async {
      final web = _Web()
        ..collection(_universe, 'Universe', <String>[_a, _b])
        ..repo(_a, 'Repo A', const <ExtensionPlugin>[])
        ..repo(_b, 'Repo B', const <ExtensionPlugin>[]);
      final session = app(web).read(extensionsControllerProvider.notifier);
      await session.addRepository(_universe);
      await session.removeRepository(_b);

      // Asking for the whole collection is asking for all of it.
      await session.addRepository(_universe);

      expect(await savedRepositories(), <String>[_a, _b]);
    });

    test(
      'is left once the user has removed every repository it brought',
      () async {
        final web = _Web()
          ..collection(_universe, 'Universe', <String>[_a, _b])
          ..repo(_a, 'Repo A', const <ExtensionPlugin>[])
          ..repo(_b, 'Repo B', const <ExtensionPlugin>[]);
        final session = app(web).read(extensionsControllerProvider.notifier);
        await session.addRepository(_universe);
        await session.removeRepository(_a);
        await session.removeRepository(_b);

        web
          ..collection(_universe, 'Universe', <String>[_a, _b, _c])
          ..repo(_c, 'Repo C', const <ExtensionPlugin>[]);
        web.fetchCalls.clear();
        final (_, report) = await launch(web);

        expect(report.isEmpty, isTrue);
        expect(await savedRepositories(), isEmpty);
        expect(
          web.fetchCalls,
          isEmpty,
          reason: 'a collection the user had left was read again',
        );
      },
    );

    test(
      'keeps being followed while any of its repositories is kept',
      () async {
        final web = _Web()
          ..collection(_universe, 'Universe', <String>[_a, _b])
          ..repo(_a, 'Repo A', const <ExtensionPlugin>[])
          ..repo(_b, 'Repo B', const <ExtensionPlugin>[]);
        final session = app(web).read(extensionsControllerProvider.notifier);
        await session.addRepository(_universe);
        await session.removeRepository(_a);

        web
          ..collection(_universe, 'Universe', <String>[_a, _b, _c])
          ..repo(_c, 'Repo C', const <ExtensionPlugin>[]);
        final (_, report) = await launch(web);

        expect(report.newRepositories, <String, List<String>>{
          'Universe': <String>['Repo C'],
        });
        expect(await savedRepositories(), <String>[_b, _c]);
      },
    );

    test(
      'that does not answer changes nothing, and is read again next launch',
      () async {
        final web = _Web()
          ..collection(_universe, 'Universe', <String>[_a])
          ..repo(_a, 'Repo A', const <ExtensionPlugin>[]);
        await app(web)
            .read(extensionsControllerProvider.notifier)
            .addRepository(_universe);

        web.down.add(_universe);
        final (offline, quiet) = await launch(web);
        expect(quiet.isEmpty, isTrue);
        expect(
          offline.read(extensionsControllerProvider),
          isNot(isA<ExtensionsError>()),
        );
        expect(await savedRepositories(), <String>[_a]);

        web
          ..down.remove(_universe)
          ..collection(_universe, 'Universe', <String>[_a, _c])
          ..repo(_c, 'Repo C', const <ExtensionPlugin>[]);
        final (_, report) = await launch(web);
        expect(report.newRepositories, <String, List<String>>{
          'Universe': <String>['Repo C'],
        });
      },
    );

    test('listing a repository that will not load announces nothing, breaks '
        'nothing, and tries it again next launch', () async {
      final web = _Web()
        ..collection(_universe, 'Universe', <String>[_a])
        ..repo(_a, 'Repo A', const <ExtensionPlugin>[]);
      await app(web)
          .read(extensionsControllerProvider.notifier)
          .addRepository(_universe);

      web
        ..collection(_universe, 'Universe', <String>[_a, _c])
        ..broken.add(_c);
      final (container, quiet) = await launch(web);
      expect(quiet.newRepositories, isEmpty);
      expect(
        container.read(extensionsControllerProvider),
        isNot(isA<ExtensionsError>()),
        reason: 'a background pass raised the Extensions error dialog',
      );
      expect(await savedRepositories(), <String>[_a]);

      web
        ..broken.remove(_c)
        ..repo(_c, 'Repo C', const <ExtensionPlugin>[]);
      final (_, report) = await launch(web);
      expect(report.newRepositories, <String, List<String>>{
        'Universe': <String>['Repo C'],
      });
    });

    test('inside a collection is followed as well', () async {
      final web = _Web()
        ..collection(_universe, 'Universe', <String>[_a, _mini])
        ..collection(_mini, 'Mini', <String>[_b])
        ..repo(_a, 'Repo A', const <ExtensionPlugin>[])
        ..repo(_b, 'Repo B', const <ExtensionPlugin>[]);
      await app(web)
          .read(extensionsControllerProvider.notifier)
          .addRepository(_universe);
      expect(await savedRepositories(), <String>[_a, _b]);

      web
        ..collection(_mini, 'Mini', <String>[_b, _c])
        ..repo(_c, 'Repo C', const <ExtensionPlugin>[]);
      final (_, report) = await launch(web);

      expect(report.newRepositories, <String, List<String>>{
        'Mini': <String>['Repo C'],
      });
      expect(await savedRepositories(), <String>[_a, _b, _c]);
    });
  });

  group('a plugin a repository lists for the first time', () {
    setUp(
      () => SharedPreferences.setMockInitialValues(<String, Object>{
        ExtensionsController.repoUrlsKey: <String>[_a],
      }),
    );

    test('is announced under the repository\'s name, once', () async {
      final web = _Web()
        ..repo(_a, 'Repo A', <ExtensionPlugin>[
          _plugin('Alpha'),
          _plugin('Bravo'),
        ]);
      // The first launch to look is learning what is already there.
      final (_, first) = await launch(web);
      expect(first.newPlugins, isEmpty);

      web.repo(_a, 'Repo A', <ExtensionPlugin>[
        _plugin('Alpha'),
        _plugin('Bravo'),
        _plugin('Charlie'),
      ]);
      final (_, second) = await launch(web);
      expect(second.newPlugins, <String, List<String>>{
        'Repo A': <String>['Charlie'],
      });
      expect(web.downloadCalls, isEmpty, reason: 'announced, not installed');

      final (_, third) = await launch(web);
      expect(third.newPlugins, isEmpty);
    });

    test('is not news when it is already installed', () async {
      final web = _Web()
        ..repo(_a, 'Repo A', <ExtensionPlugin>[_plugin('Alpha')]);
      await launch(web);

      web.repo(_a, 'Repo A', <ExtensionPlugin>[
        _plugin('Alpha'),
        _plugin('Bravo'),
      ]);
      final (_, report) = await launch(
        web,
        installed: <ExtensionPlugin>[_plugin('Bravo')],
      );

      expect(report.newPlugins, isEmpty);
    });

    test('is not news again after missing from one launch', () async {
      // A plugin list that fails to download leaves its plugins out of that
      // launch's listing; when it comes back they are not new.
      final web = _Web()
        ..repo(_a, 'Repo A', <ExtensionPlugin>[
          _plugin('Alpha'),
          _plugin('Bravo'),
        ]);
      await launch(web);

      web.repo(_a, 'Repo A', <ExtensionPlugin>[_plugin('Alpha')]);
      final (_, gap) = await launch(web);
      expect(gap.newPlugins, isEmpty);

      web.repo(_a, 'Repo A', <ExtensionPlugin>[
        _plugin('Alpha'),
        _plugin('Bravo'),
      ]);
      final (_, back) = await launch(web);
      expect(back.newPlugins, isEmpty);
    });

    test('is not news in a repository the user has just added', () async {
      final web = _Web()
        ..repo(_a, 'Repo A', <ExtensionPlugin>[_plugin('Alpha')])
        ..repo(_b, 'Repo B', <ExtensionPlugin>[_plugin('Bravo')]);
      await launch(web);

      await app(web)
          .read(extensionsControllerProvider.notifier)
          .addRepository(_b);
      final (_, report) = await launch(web);

      expect(report.newPlugins, isEmpty);
    });
  });
}
