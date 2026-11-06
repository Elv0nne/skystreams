/// A repository the user adds by its code is kept as the short link the
/// code was found at.
///
/// It used to be kept as the code as typed, and looked up again on every
/// launch in each of the spellings a typed code is tried in - "Universe" as
/// typed, then in lower case - so anyone registering a spelling ahead of the
/// one that answered would take the repository over, and with it what the
/// app installs and runs. Kept as the short link, the code is still looked
/// up on every launch, so the repository can move, but only that code is.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/extensions/models/extension_plugin.dart';
import 'package:skystream/core/extensions/providers.dart';
import 'package:skystream/core/extensions/services/plugin_storage_service.dart';
import 'package:skystream/core/extensions/services/repository_service.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/extensions/providers/extensions_controller.dart';

const String _abc = 'https://cutt.ly/sky-abc';
const String _universe = 'https://cutt.ly/sky-universe';
const String _a = 'https://a.test/repo.json';
const String _b = 'https://b.test/repo.json';

/// cutt.ly with SkyStream's `sky-abc`, a repository, and `sky-universe`, a
/// collection listing [universeLists] - in lower case only - and the
/// repositories they lead to. Anything else is a 404. Records every request.
class _Net implements HttpClientAdapter {
  final List<String> requested = <String>[];
  List<String> universeLists = <String>[_a];

  Iterable<String> get shortened =>
      requested.where((url) => url.startsWith('https://cutt.ly/'));

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requested.add(url);
    ResponseBody redirect(String to) => ResponseBody.fromString(
      '',
      302,
      headers: {
        'location': [to],
      },
    );
    ResponseBody json(Object body) =>
        ResponseBody.fromString(jsonEncode(body), 200);
    ResponseBody repo(String host) => json({
      'name': 'Repo $host',
      'packageName': 'repo.$host',
      'pluginLists': ['https://$host/plugins.json'],
    });
    return switch (url) {
      _abc => redirect('https://abc.test/repo.json'),
      _universe => redirect('https://universe.test/collection.json'),
      'https://universe.test/collection.json' => json({
        'name': 'Universe',
        'packageName': 'collection.universe',
        'repos': universeLists,
      }),
      'https://abc.test/repo.json' => repo('abc.test'),
      _a => repo('a.test'),
      _b => repo('b.test'),
      'https://abc.test/plugins.json' => json([
        {
          'packageName': 'com.example.alpha',
          'name': 'Alpha',
          'url': 'https://abc.test/alpha.sky',
          'version': 2,
        },
      ]),
      'https://a.test/plugins.json' ||
      'https://b.test/plugins.json' => json(<Object>[]),
      _ => ResponseBody.fromString('not found', 404),
    };
  }

  @override
  void close({bool force = false}) {}
}

class _Disk extends PluginStorageService {
  _Disk(this.installed);

  final List<ExtensionPlugin> installed;

  @override
  Future<List<ExtensionPlugin>> listInstalledPlugins() async =>
      List<ExtensionPlugin>.of(installed);
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

  late _Net net;

  setUp(() {
    net = _Net();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// One run of the app, over the preferences the last left behind.
  ProviderContainer app({
    List<ExtensionPlugin> installed = const <ExtensionPlugin>[],
  }) {
    final container = ProviderContainer(
      overrides: [
        repositoryServiceProvider.overrideWithValue(
          RepositoryService(Dio()..httpClientAdapter = net),
        ),
        pluginStorageServiceProvider.overrideWithValue(_Disk(installed)),
        settingsRepositoryProvider.overrideWithValue(_FakeSettingsRepository()),
        extensionManagerProvider.overrideWith(_NoopExtensionManager.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ExtensionsController controllerOf(ProviderContainer container) =>
      container.read(extensionsControllerProvider.notifier);

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  test('one added by its code is kept as the short link it was found at, '
      'and its plugins with it', () async {
    final container = app();

    await controllerOf(container).addRepository('Abc');

    expect((await prefs()).getStringList(ExtensionsController.repoUrlsKey), [
      _abc,
    ]);
    final state = container.read(extensionsControllerProvider);
    expect(state.repositories.single.url, _abc);
    expect(state.availablePlugins.keys, [_abc]);
    expect(state.availablePlugins[_abc]!.single.repositoryUrl, _abc);
  });

  test(
    'a collection added by its code is followed as its short link',
    () async {
      await controllerOf(app()).addRepository('Universe');

      final followed = jsonDecode(
        (await prefs()).getString(ExtensionsController.collectionsKey)!,
      ) as Map<String, dynamic>;
      expect(followed.keys, [_universe]);
      expect((await prefs()).getStringList(ExtensionsController.repoUrlsKey), [
        _a,
      ]);
    },
  );

  test('kept as a short link, it loads on later launches by that code alone, '
      'and the plugins pinned to it update', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: <String>[_abc],
    });
    final container = app(
      installed: [
        ExtensionPlugin(
          packageName: 'com.example.alpha',
          name: 'Alpha',
          repositoryId: 'repo.abc.test',
          repositoryUrl: _abc,
          sourceUrl: 'https://abc.test/alpha.sky',
          version: 1,
        ),
      ],
    );

    await controllerOf(container).ensureInitialized();
    await controllerOf(container).checkForUpdates();

    final update = container
        .read(extensionsControllerProvider)
        .availableUpdates['com.example.alpha'];
    expect(update?.version, 2);
    expect(update?.repositoryUrl, _abc);
    expect(net.shortened, [_abc]);
  });

  test(
    'a collection kept as a short link is read again on later launches',
    () async {
      await controllerOf(app()).addRepository('Universe');
      net
        ..requested.clear()
        ..universeLists = <String>[_a, _b];

      final report = await controllerOf(app()).autoUpdate();

      expect(report.newRepositories, {
        'Universe': ['Repo b.test'],
      });
      expect(net.shortened, [_universe]);
    },
  );

  test('a code a collection lists is kept as listed, so a removal of it '
      'holds', () async {
    // The collection's list is what each launch compares the user's
    // repositories, and the ones they removed, with.
    net.universeLists = <String>['abc'];
    final first = app();
    await controllerOf(first).addRepository('Universe');
    expect((await prefs()).getStringList(ExtensionsController.repoUrlsKey), [
      'abc',
    ]);
    await controllerOf(first).removeRepository('abc');

    await controllerOf(app()).autoUpdate();

    expect(
      (await prefs()).getStringList(ExtensionsController.repoUrlsKey),
      isEmpty,
    );
  });

  test('one saved by its code before keeps working as it did', () async {
    // Saved as typed, before codes were kept as their short links. Typed in
    // lower case, as it had to be then, it is looked up in no other case.
    SharedPreferences.setMockInitialValues(<String, Object>{
      ExtensionsController.repoUrlsKey: <String>['abc'],
    });
    final container = app();

    await controllerOf(container).ensureInitialized();

    final state = container.read(extensionsControllerProvider);
    expect(state.repositories.single.url, 'abc');
    expect(state.availablePlugins.keys, ['abc']);
    expect(net.shortened, [_abc]);
  });
}
