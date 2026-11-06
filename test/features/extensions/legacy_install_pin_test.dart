/// An install from before installs kept the address of their repository is
/// given that address once: on a launch where every saved repository loaded,
/// when exactly one of them declares the install's repository id.
///
/// Matched by that id on every launch instead, the install could be updated
/// by whichever repository declared the id later - a collection can add one
/// on its own - once the real one was gone.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
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
import 'package:skystream/features/extensions/screens/extensions_screen.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const String _a = 'https://a.test/repo.json';
const String _b = 'https://b.test/repo.json';
const String _alpha = 'com.example.alpha';

/// Alpha at [version], as the repository with id [repoId] lists it.
ExtensionPlugin _listed(String repoId, int version) => ExtensionPlugin(
  packageName: _alpha,
  name: 'Alpha',
  repositoryId: repoId,
  sourceUrl: 'https://cdn.test/$repoId/alpha-v$version.sky',
  version: version,
);

/// Repositories by address: the name and id each declares, and what it lists.
class _Web extends RepositoryService {
  _Web(this.repos) : super(Dio());

  final Map<String, (String name, String id, List<ExtensionPlugin> plugins)>
  repos;

  @override
  Future<ExtensionRepository?> fetchRepository(String url) async {
    final repo = repos[url];
    if (repo == null) return null;
    return ExtensionRepository(
      name: repo.$1,
      url: url,
      pluginLists: <String>['$url#plugins'],
      explicitId: repo.$2,
    );
  }

  @override
  Future<List<ExtensionPlugin>> getRepoPlugins(
    ExtensionRepository repo,
  ) async => [
    for (final plugin in repos[repo.url]?.$3 ?? const <ExtensionPlugin>[])
      plugin.copyWith(repositoryUrl: repo.url),
  ];

  @override
  Future<File?> downloadPlugin(String url) async => null;
}

class _FakeSettingsRepository extends SettingsRepository {
  _FakeSettingsRepository() : super(StorageService());

  @override
  bool getDevLoadAssets() => false;
}

class _Manager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => const <SkyStreamProvider>[];

  @override
  Future<void> reloadPlugin(ExtensionPlugin plugin) async {}

  @override
  List<PluginSubProvider> getProvidersForPlugin(ExtensionPlugin plugin) => [];

  @override
  Future<List<PluginSettingDefinition>> getSettingsForPlugin(
    ExtensionPlugin plugin,
  ) async => [];
}

/// Installs kept in memory, pinned the way the real store pins them.
class _Disk extends PluginStorageService {
  _Disk(this.installed);

  List<ExtensionPlugin> installed;

  @override
  Future<List<ExtensionPlugin>> listInstalledPlugins() async =>
      List<ExtensionPlugin>.of(installed);

  @override
  Future<ExtensionPlugin?> pinRepositoryUrl(
    ExtensionPlugin plugin,
    String repositoryUrl,
  ) async {
    if (plugin.repositoryUrl != null) return null;
    final pinned = plugin.copyWith(repositoryUrl: repositoryUrl);
    installed = [
      for (final p in installed)
        p.packageName == plugin.packageName ? pinned : p,
    ];
    return pinned;
  }
}

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

  /// Alpha v1 on disk as installed from the repository with id [repoId]:
  /// before addresses were kept - no address in its record - or from [from].
  void installAlpha({String? from, String? repoId = 'repo.a'}) {
    final folder = Directory('${support.path}/extensions/plugin/$_alpha')
      ..createSync(recursive: true);
    File('${folder.path}/meta.json').writeAsStringSync(
      jsonEncode({
        'packageName': _alpha,
        'name': 'Alpha',
        'version': 1,
        'repositoryId': repoId,
        'repositoryUrl': ?from,
      }),
    );
    File('${folder.path}/plugin.js').writeAsStringSync('function init() {}');
  }

  /// One launch, following [saved] - every repository [web] has, unless
  /// given - with the plugins on disk; returns it once updates are checked.
  Future<ProviderContainer> launch(
    Map<String, (String, String, List<ExtensionPlugin>)> web, {
    List<String>? saved,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: saved ?? web.keys.toList(),
    });
    final container = ProviderContainer(
      overrides: [
        repositoryServiceProvider.overrideWithValue(_Web(web)),
        pluginStorageServiceProvider.overrideWithValue(PluginStorageService()),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
        extensionManagerProvider.overrideWith(_Manager.new),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(extensionsControllerProvider.notifier);
    await controller.ensureInitialized();
    await controller.checkForUpdates();
    return container;
  }

  /// Where Alpha's install record says it came from.
  Future<String?> pinOnDisk() async =>
      (await PluginStorageService().listInstalledPlugins())
          .single
          .repositoryUrl;

  test('an older install is pinned to the one repository declaring its id, '
      'and updates from it', () async {
    installAlpha();

    final container = await launch({
      _a: ('Repo A', 'repo.a', [_listed('repo.a', 2)]),
      _b: ('Repo B', 'repo.b', const <ExtensionPlugin>[]),
    });

    expect(await pinOnDisk(), _a);
    final state = container.read(extensionsControllerProvider);
    expect(state.installedPlugins.single.repositoryUrl, _a);
    expect(state.availableUpdates[_alpha]?.repositoryUrl, _a);
  });

  test('nothing is pinned when two repositories declare its id', () async {
    installAlpha();

    await launch({
      _a: ('Repo A', 'repo.a', [_listed('repo.a', 1)]),
      _b: ('Repo B', 'repo.a', [_listed('repo.a', 1)]),
    });

    expect(await pinOnDisk(), isNull);
  });

  test('nothing is pinned on a launch where a saved repository did not '
      'load', () async {
    // The one missing may be a second claimant to the id.
    installAlpha();

    await launch(
      {
        _a: ('Repo A', 'repo.a', [_listed('repo.a', 1)]),
      },
      saved: [_a, _b],
    );

    expect(await pinOnDisk(), isNull);
  });

  test('an install with an address keeps it', () async {
    installAlpha(from: _b);

    await launch({
      _a: ('Repo A', 'repo.a', [_listed('repo.a', 1)]),
    });

    expect(await pinOnDisk(), _b);
  });

  test('once pinned, a repository taking its id later gets no update, with '
      'the real one removed', () async {
    installAlpha();
    await launch({
      _a: ('Repo A', 'repo.a', [_listed('repo.a', 1)]),
    });

    // A collection adds one declaring the same id, and the user removes A.
    final container = await launch({
      _b: ('Repo B', 'repo.a', [_listed('repo.a', 9)]),
    });

    expect(
      container.read(extensionsControllerProvider).availableUpdates,
      isEmpty,
    );
    expect(await pinOnDisk(), _a);
  });

  // The ids the app gives a plugin no repository it can name supplied name
  // no repository: a repository declaring one as its own would otherwise be
  // the one claimant of every plugin installed from a file, say, and pin it
  // and update it with code of its own.
  for (final (kind, recorded, declared) in <(String, String?, String)>[
    // How an install from a file is recorded: with no repository id, which
    // reads back as "Local".
    ('the id a file install reads back as', null, 'Local'),
    ('"UnknownRepo" as its id', 'UnknownRepo', 'UnknownRepo'),
    ('"LocalAssets" as its id', 'LocalAssets', 'LocalAssets'),
    ('"Unknown" as its id', 'Unknown', 'Unknown'),
    ('an empty id', '', ''),
    ('a blank id', '  ', '  '),
  ]) {
    test('a repository declaring $kind gets neither the pin nor the '
        'update', () async {
      installAlpha(repoId: recorded);

      final container = await launch({
        _a: ('Repo A', declared, [_listed(declared, 9)]),
      });

      expect(await pinOnDisk(), isNull);
      expect(
        container.read(extensionsControllerProvider).availableUpdates,
        isEmpty,
      );
    });
  }

  testWidgets('a pinned older install can be installed from another '
      'repository', (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: <String>[_a, _b],
    });
    final older = ExtensionPlugin(
      packageName: _alpha,
      name: 'Alpha',
      repositoryId: 'repo.a',
      sourceUrl: 'https://cdn.test/repo.a/alpha-v1.sky',
      version: 1,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          repositoryServiceProvider.overrideWithValue(
            _Web({
              _a: ('Repo A', 'repo.a', [_listed('repo.a', 1)]),
              _b: ('Repo B', 'repo.b', [_listed('repo.b', 2)]),
            }),
          ),
          pluginStorageServiceProvider.overrideWithValue(_Disk([older])),
          settingsRepositoryProvider.overrideWithValue(
            _FakeSettingsRepository(),
          ),
          extensionManagerProvider.overrideWith(_Manager.new),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ExtensionsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repositories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repo B'));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Alpha'),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('Install from this repository'),
      ),
      findsOneWidget,
    );
  });
}
