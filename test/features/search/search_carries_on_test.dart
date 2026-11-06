import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';

/// A search carries on after a bot check clears: the extensions that met the
/// site and came back empty search again, and their results join the rest.
class _Plugin extends SkyStreamProvider {
  _Plugin(this.packageName, this.answers, {String? source})
    : checkSource = source ?? 'js:$packageName';

  @override
  final String packageName;
  @override
  final String? checkSource;

  /// What each search answers, in turn; the last repeats.
  final List<Future<List<MultimediaItem>> Function()> answers;
  int searches = 0;

  @override
  String get name => packageName;
  @override
  String get mainUrl => 'https://$packageName.example';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) => answers[(searches++).clamp(0, answers.length - 1)]();

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

class _Manager extends ExtensionManager {
  _Manager(this.plugins);

  final List<SkyStreamProvider> plugins;

  @override
  List<SkyStreamProvider> build() => plugins;
}

MultimediaItem _film(String title) =>
    MultimediaItem(title: title, url: 'u/$title', posterUrl: '');

List<String> _titles(SearchAggregateState state) => [
  for (final r in state.results) ...r.results.map((i) => i.title),
];

void main() {
  late SiteChecks checks;

  setUp(() {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    checks = SiteChecks();
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: checks,
      solver: ClearanceSolver(store: store, siteKeys: keys, checks: checks),
    );
  });

  /// A search that meets [site]'s check, which wants a person: it comes back
  /// empty, filed under [source].
  Future<List<MultimediaItem>> Function() metCheck(
    String site,
    String source,
  ) => () async {
    checks.met(site, source: source);
    checks.update(site, CheckState.needsYou);
    return const [];
  };

  /// Runs a search for [query] over [plugins], and the states it emits.
  Future<(ProviderContainer, List<SearchAggregateState>)> search(
    List<SkyStreamProvider> plugins, {
    String query = 'film',
  }) async {
    final container = ProviderContainer(
      overrides: [
        extensionManagerProvider.overrideWith(() => _Manager(plugins)),
      ],
    );
    addTearDown(container.dispose);
    final states = <SearchAggregateState>[];
    container.listen(searchResultsProvider, (_, next) {
      if (next.hasValue) states.add(next.value!);
    }, fireImmediately: true);
    container.read(searchQueryProvider.notifier).set(query);
    await until(() => states.isNotEmpty && !states.last.isLoading);
    return (container, states);
  }

  test('when a site clears, the extension that met it searches again, and '
      'its results join', () async {
    final a = _Plugin('a', [
      metCheck('a.com', 'js:a'),
      () async => [_film('Film A')],
    ]);
    final b = _Plugin('b', [
      () async => [_film('Film B')],
    ]);
    final (_, states) = await search([a, b]);
    expect(_titles(states.last), ['Film B']);

    checks.update('a.com', CheckState.cleared);
    await until(() => _titles(states.last).contains('Film A'));

    expect(_titles(states.last), unorderedEquals(['Film A', 'Film B']));
    expect(a.searches, 2);
    expect(b.searches, 1);
    expect(states.last.isLoading, isFalse);
  });

  test('an extension that found results anyway is not asked again', () async {
    final a = _Plugin('a', [
      () async {
        checks.met('x.com', source: 'js:a');
        return [_film('Film A')];
      },
    ]);
    final b = _Plugin('b', [
      metCheck('x.com', 'js:b'),
      () async => [_film('Film B')],
    ]);
    final (_, states) = await search([a, b]);

    checks.update('x.com', CheckState.cleared);
    await until(() => _titles(states.last).contains('Film B'));

    expect(a.searches, 1);
    expect(b.searches, 2);
    expect(_titles(states.last), unorderedEquals(['Film A', 'Film B']));
  });

  test('a search replaced by a newer one does not carry on', () async {
    final a = _Plugin('a', [
      metCheck('a.com', 'js:a'),
      () async => [_film('Film A')],
    ]);
    final (container, _) = await search([a]);
    container.read(searchQueryProvider.notifier).set('');
    await pumpEventQueue();

    checks.update('a.com', CheckState.cleared);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(a.searches, 1);
  });

  test('a search ends once no check it met can still clear', () async {
    final a = _Plugin('a', [
      () async {
        checks.met('a.com', source: 'js:a');
        return const [];
      },
      () async => [_film('Film A')],
    ]);
    await search([a]);

    // Still being tried as the search finished: it waits. Then it can't clear.
    checks.update('a.com', CheckState.blocked);
    await pumpEventQueue();
    checks.update('a.com', CheckState.cleared);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(a.searches, 1);
  });

  test(
    'while it searches again, the search names it, and is not loading',
    () async {
      final gate = Completer<List<MultimediaItem>>();
      final a = _Plugin('a', [metCheck('a.com', 'js:a'), () => gate.future]);
      final (_, states) = await search([a]);

      checks.update('a.com', CheckState.cleared);
      await until(() => states.last.rerunning.contains('a'));
      expect(states.last.isLoading, isFalse);

      gate.complete([_film('Film A')]);
      await until(() => states.last.rerunning.isEmpty);
      expect(_titles(states.last), ['Film A']);
    },
  );

  test('a CloudStream check with no extension named re-runs the CloudStream '
      'extensions that came back empty', () async {
    final c = _Plugin('cs3:k/C', [
      metCheck('c.com', 'cs3'),
      () async => [_film('Film C')],
    ], source: 'cs3:k/C');
    final (_, states) = await search([c]);

    checks.update('c.com', CheckState.cleared);
    await until(() => _titles(states.last).contains('Film C'));
    expect(c.searches, 2);
  });
}

/// Waits, a few milliseconds at a time, until [done].
Future<void> until(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
