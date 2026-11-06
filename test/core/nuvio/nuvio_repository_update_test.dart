/// Nuvio scrapers on a launch: every repository fetched again, however
/// recently it was checked, and the scrapers whose version moved named, so
/// the launch toast can say what changed. So are scrapers a repository lists
/// for the first time, under the repository's name.
///
/// A repository used to be skipped for six hours after its last check.
/// Scrapers break when the sites they read change, and the developer's fix
/// only helps once it is here, so every launch checks now. The user's
/// auto-update switch still decides whether it happens at all.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/network/dio_client_provider.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';

const String _manifestUrl = 'https://nuvio.test/manifest.json';

Map<String, dynamic> _manifestJson(
  String scraperVersion, {
  bool withSecond = false,
}) => <String, dynamic>{
  'name': 'Test Repo',
  'version': scraperVersion,
  'scrapers': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'one',
      'name': 'Scraper One',
      'version': scraperVersion,
      'filename': 'one.js',
      'supportedTypes': <String>['movie'],
    },
    if (withSecond)
      <String, dynamic>{
        'id': 'two',
        'name': 'Scraper Two',
        'version': '1.0.0',
        'filename': 'two.js',
        'supportedTypes': <String>['movie'],
      },
  ],
};

/// The manifest for [_manifestUrl], and a scrap of code for anything else.
class _FakeNuvio implements HttpClientAdapter {
  _FakeNuvio(this.published, {this.withSecond = false});

  final String published;

  /// Whether the published manifest lists a second scraper, which the stored
  /// one does not.
  final bool withSecond;
  final List<String> requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requested.add(url);
    final body = url == _manifestUrl
        ? jsonEncode(_manifestJson(published, withSecond: withSecond))
        : '/* scraper code */';
    return ResponseBody.fromString(body, 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() {
    // NuvioCodeStore keeps scraper code under the application support
    // directory; give it a scratch one.
    support = Directory.systemTemp.createTempSync('nuvio_update_test');
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
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  ProviderContainer boot(_FakeNuvio nuvio, {bool autoUpdate = true}) {
    final stored = NuvioRepo(
      manifestUrl: _manifestUrl,
      manifest: NuvioManifest.fromJson(_manifestJson('1.0.0')),
      addedAt: DateTime(2026),
      // Checked a minute ago: the six-hour interval would have skipped it.
      lastCheckedAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      'nuvio_repos_v1': <String>[jsonEncode(stored.toJson())],
      'nuvio_auto_update_v1': autoUpdate,
    });
    final container = ProviderContainer(
      overrides: [
        dioClientProvider.overrideWithValue(Dio()..httpClientAdapter = nuvio),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a repository checked a minute ago is still refreshed', () async {
    final nuvio = _FakeNuvio('1.1.0');
    final container = boot(nuvio);

    final report = await container
        .read(nuvioRepositoryProvider.notifier)
        .autoUpdate();
    // Let the background prefetch of the new code finish.
    await pumpEventQueue();

    expect(report.updated, <String>['Scraper One']);
    expect(report.newPlugins, isEmpty);
    expect(nuvio.requested, contains(_manifestUrl));
    expect(
      container.read(nuvioRepositoryProvider).repos.single.manifest?.version,
      '1.1.0',
    );
  });

  test('the auto-update switch still decides', () async {
    final nuvio = _FakeNuvio('1.1.0');
    final container = boot(nuvio, autoUpdate: false);

    final report = await container
        .read(nuvioRepositoryProvider.notifier)
        .autoUpdate();

    expect(report.isEmpty, isTrue);
    expect(nuvio.requested, isEmpty);
  });

  test(
    'a scraper the repository lists for the first time is named under it',
    () async {
      final nuvio = _FakeNuvio('1.0.0', withSecond: true);
      final container = boot(nuvio);

      final report = await container
          .read(nuvioRepositoryProvider.notifier)
          .autoUpdate();
      await pumpEventQueue();

      expect(report.newPlugins, <String, List<String>>{
        'Test Repo': <String>['Scraper Two'],
      });
      expect(report.updated, isEmpty);

      // Said once: the next launch diffs against what this one stored.
      final again = await container
          .read(nuvioRepositoryProvider.notifier)
          .autoUpdate();
      await pumpEventQueue();
      expect(again.isEmpty, isTrue);
    },
  );

  test(
    'loading the repositories does not start a refresh of its own',
    () async {
      final nuvio = _FakeNuvio('1.1.0');
      final container = boot(nuvio);

      container.read(nuvioRepositoryProvider);
      await pumpEventQueue();

      expect(container.read(nuvioRepositoryProvider).repos, hasLength(1));
      expect(
        nuvio.requested,
        isEmpty,
        reason: 'load() fetched a manifest the launch refresh fetches again',
      );
    },
  );
}
