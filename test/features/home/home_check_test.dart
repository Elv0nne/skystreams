import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart' hide Step;
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
import 'package:skystream/features/home/presentation/home_provider.dart';
import 'package:skystream/features/home/presentation/home_state.dart';
import 'package:skystream/features/home/presentation/widgets/home_check_card.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../core/network/clearance/fakes.dart';

/// Home's one site: its check in place of Home's wait, Verify when it needs
/// a person, and Home fetching again once it clears.
class _Plugin extends SkyStreamProvider {
  _Plugin(this.name, this.answers);

  @override
  final String name;
  final List<Future<Map<String, List<MultimediaItem>>> Function()> answers;
  int homes = 0;

  @override
  String get packageName => 'p.$name';
  @override
  String? get checkSource => 'js:$name';
  @override
  String get mainUrl => '';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      answers[(homes++).clamp(0, answers.length - 1)]();
  @override
  Future<List<MultimediaItem>> search(String q, {CancelToken? cancelToken}) =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

_Plugin _plugin(
  String name, {
  List<Future<Map<String, List<MultimediaItem>>> Function()>? answers,
}) => _Plugin(name, answers ?? [() async => {}]);

/// The real notifier reaches for storage and the extension manager on every
/// write; this keeps the state transition and drops the persistence.
class _FakeActiveProvider extends ActiveProvider {
  _FakeActiveProvider(this._initial);

  final SkyStreamProvider? _initial;

  @override
  SkyStreamProvider? build() => _initial;

  @override
  Future<void> set(SkyStreamProvider? provider) async {
    state = provider;
  }
}

void main() {
  late SiteChecks checks;
  late ClearanceSolver solver;
  late DateTime began;

  // Built inside the test body: futures made in setUp belong to the real
  // zone, and pumping never runs their callbacks.
  void useClearance() {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    solver = ClearanceSolver(
      store: store,
      siteKeys: keys,
      checks: checks,
      // Verify's page is past its check, so Done clears.
      openPage: PageFactory([
        FakePage(const [Step('Example')]),
      ]).call,
    );
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: checks,
      solver: solver,
    );
  }

  Future<void> pumpGate(
    WidgetTester tester, {
    required SkyStreamProvider provider,
    VoidCallback? onRetry,
  }) {
    useClearance();
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: HomeCheckGate(
            provider: provider,
            since: began,
            onRetry: onRetry ?? () {},
            child: const Text('the wait'),
          ),
        ),
      ),
    );
  }

  setUp(() {
    checks = SiteChecks();
    began = checks.now;
  });

  testWidgets('while Home\'s plugin is checked, the card shows instead of '
      'the wait', (tester) async {
    await pumpGate(tester, provider: _plugin('a'));
    checks.met('a.com', source: 'js:a');
    await tester.pump();
    expect(
      find.textContaining('Checking a.com automatically…'),
      findsOneWidget,
    );
    expect(find.text('the wait'), findsNothing);
  });

  testWidgets('when it needs a person, Verify, and the wait comes back once '
      'it clears', (tester) async {
    await pumpGate(tester, provider: _plugin('a'));
    checks
      ..met('a.com', source: 'js:a')
      ..update('a.com', CheckState.needsYou);
    await tester.pump();
    expect(find.text('a.com needs a quick check'), findsOneWidget);
    solver.presenter = ({
      required page,
      required site,
      required cleared,
    }) async => ChallengeSheetResult.done;
    await tester.tap(find.text('Verify'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.text('the wait'), findsOneWidget);
    // The sheet's watcher stops at its next look.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('while Verify opens the check, the card says so', (tester) async {
    await pumpGate(tester, provider: _plugin('a'));
    checks
      ..met('a.com', source: 'js:a')
      ..update('a.com', CheckState.opening);
    await tester.pump();
    expect(find.text('Opening a.com\'s check…'), findsOneWidget);
  });

  testWidgets('another plugin\'s check is not Home\'s', (tester) async {
    await pumpGate(tester, provider: _plugin('b'));
    checks.met('a.com', source: 'js:a');
    await tester.pump();
    expect(find.text('the wait'), findsOneWidget);
  });

  testWidgets(
    'an outdated browser, a site that refuses SkyStream, and one that keeps '
    'asking each say so; only the last offers Verify',
    (tester) async {
      await pumpGate(tester, provider: _plugin('a'), onRetry: () {});
      checks
        ..met('a.com', source: 'js:a')
        ..update('a.com', CheckState.outdated);
      await tester.pump();
      expect(
        find.text("Update Android System WebView to clear this site's check"),
        findsOneWidget,
      );
      expect(find.text('Verify'), findsNothing);
      checks.update('a.com', CheckState.ineffective);
      // One change reaches the card in the frame after it.
      await tester.pump();
      await tester.pump();
      expect(
        find.text(
          'The check passed, but this site still refuses SkyStream. Trying '
          'again in a few minutes.',
        ),
        findsOneWidget,
      );
      expect(find.text('Verify'), findsNothing);
      checks.update('a.com', CheckState.keepsAsking);
      // One change reaches the card in the frame after it.
      await tester.pump();
      await tester.pump();
      expect(
        find.text('This site keeps asking. Try later, or without a VPN.'),
        findsOneWidget,
      );
      expect(find.text('Verify'), findsOneWidget);
    },
  );

  testWidgets('a blocked site says so, with Retry', (tester) async {
    var retried = 0;
    await pumpGate(tester, provider: _plugin('a'), onRetry: () => retried++);
    checks
      ..met('a.com', source: 'js:a')
      ..update('a.com', CheckState.blocked);
    await tester.pump();
    expect(find.text('Blocked by the site; try without a VPN'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
  });

  // Some plugins turn a failure into empty rows: Home still shows the check,
  // with Verify, and fetches again once it clears.
  test(
    'a plugin that answers empty rows while its site\'s check isn\'t '
    'cleared: Home shows the check, then fetches again once it clears',
    () async {
      useClearance();
      final film = MultimediaItem(title: 'Film', url: 'u/film', posterUrl: '');
      final a = _plugin(
        'a',
        answers: [
          () async {
            checks
              ..met('a.com', source: 'js:a')
              ..update('a.com', CheckState.needsYou);
            return {'Row': <MultimediaItem>[]};
          },
          () async => {
            'Row': [film],
          },
        ],
      );
      final container = ProviderContainer(
        overrides: [
          activeProviderProvider.overrideWith(() => _FakeActiveProvider(a)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(homeDataProvider, (_, _) {}, fireImmediately: true);
      await until(() => container.read(homeDataProvider) is HomeError);
      checks.update('a.com', CheckState.cleared);
      await until(() => container.read(homeDataProvider) is HomeSuccess);
      expect((container.read(homeDataProvider) as HomeSuccess).data['Row'], [
        film,
      ]);
    },
  );

  test('Home fetches again when the check it gave up on clears', () async {
    useClearance();
    // getHome: the first call meets a.com's check and fails; the second answers.
    final a = _plugin(
      'a',
      answers: [
        () async {
          checks
            ..met('a.com', source: 'js:a')
            ..update('a.com', CheckState.needsYou);
          throw Exception('challenge');
        },
        () async => {'Row': <MultimediaItem>[]},
      ],
    );
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWith(() => _FakeActiveProvider(a)),
      ],
    );
    addTearDown(container.dispose);
    container.listen(homeDataProvider, (_, _) {}, fireImmediately: true);
    await until(() => container.read(homeDataProvider) is HomeError);
    checks.update('a.com', CheckState.cleared);
    await until(() => container.read(homeDataProvider) is HomeSuccess);
    expect(a.homes, 2);
  });

  // The screen reads the start while it builds Home's wait, and the first
  // fetch only runs after that build: without a start, Home's first load
  // never showed its check.
  test('Home knows when its first fetch began as soon as it loads', () {
    useClearance();
    final container = ProviderContainer(
      overrides: [
        activeProviderProvider.overrideWith(
          () => _FakeActiveProvider(_plugin('a')),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(homeDataProvider, (_, _) {}, fireImmediately: true);
    expect(container.read(homeDataProvider), isA<HomeLoading>());
    expect(container.read(homeDataProvider.notifier).fetchStartedAt, isNotNull);
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
