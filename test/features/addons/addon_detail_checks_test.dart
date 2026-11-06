import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/features/addons/presentation/addon_detail_screen.dart';
import 'package:skystream/features/addons/presentation/addon_providers.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class _Repo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    addons: [
      ManagedAddon(
        manifestUrl: 'https://addon.test/manifest.json',
        addedAt: DateTime(2026),
        manifest: AddonManifest.fromJson({
          'id': 'test.addon',
          'name': 'Test',
          'version': '1.0.0',
          'resources': ['meta', 'stream'],
          'types': ['movie'],
        }),
      ),
    ],
    isLoading: false,
  );
}

/// A solver that notes Verify instead of opening a page.
class _Solver extends ClearanceSolver {
  _Solver({required super.store, required super.siteKeys, super.checks});

  final verified = <String>[];

  @override
  Future<SolveOutcome> verify(String site) async {
    verified.add(site);
    return const SolveOutcome(SolveResult.failed);
  }
}

/// A Stremio title whose details an add-on couldn't give past a bot check.
void main() {
  late SiteChecks checks;
  late _Solver solver;

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
      solver: solver = _Solver(store: store, siteKeys: keys, checks: checks),
    );
  });

  tearDown(() => Clearance.instance.solver.dispose());

  group('on TV, the page opens with the remote on', () {
    Future<void> open(WidgetTester tester, AddonMeta? meta) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            addonRepositoryProvider.overrideWith(_Repo.new),
            addonMetaProvider('movie', 'tt1').overrideWith((ref) async => meta),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AddonDetailScreen(type: 'movie', id: 'tt1'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// Whether the control holding the focus is the one labelled [label].
    bool focused(WidgetTester tester, String label) {
      final node = FocusManager.instance.primaryFocus;
      // A scope holding the focus means no control does.
      final holder = node is FocusScopeNode ? null : node?.context?.widget;
      return holder != null &&
          find
              .descendant(of: find.byWidget(holder), matching: find.text(label))
              .evaluate()
              .isNotEmpty;
    }

    testWidgets('its add-ons search, the one way to its streams', (
      tester,
    ) async {
      await open(
        tester,
        const AddonMeta(id: 'tt1', type: 'movie', name: 'Film'),
      );
      expect(focused(tester, 'Search Stremio add-ons'), isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Retry, when the details failed', (tester) async {
      await open(tester, null);
      expect(focused(tester, 'Retry'), isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('on TV, UP from Retry reaches Verify, and select presses it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          addonRepositoryProvider.overrideWith(_Repo.new),
          addonMetaProvider('movie', 'tt1').overrideWith((ref) async => null),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AddonDetailScreen(type: 'movie', id: 'tt1'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    checks
      ..met('addon.test', source: 'addon:test.addon')
      ..update('addon.test', CheckState.needsYou);
    await tester.pump();
    await tester.pump();
    expect(find.text('Verify'), findsOneWidget);

    Focus.of(tester.element(find.text('Retry'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      Focus.of(tester.element(find.text('Verify'))).hasPrimaryFocus,
      isTrue,
      reason: 'UP from Retry missed Verify',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(solver.verified, ['addon.test']);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the check its add-on met shows with Verify, and once cleared the details load again',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var fetches = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            addonRepositoryProvider.overrideWith(_Repo.new),
            addonMetaProvider('movie', 'tt1').overrideWith((ref) async {
              fetches++;
              return null;
            }),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: AddonDetailScreen(type: 'movie', id: 'tt1'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fetches, 1);

      checks
        ..met('addon.test', source: 'addon:test.addon')
        ..update('addon.test', CheckState.needsYou);
      // The checks' change arrives after the first frame.
      await tester.pump();
      await tester.pump();
      expect(find.text('addon.test needs a quick check'), findsOneWidget);
      expect(find.text('Verify'), findsOneWidget);

      checks.update('addon.test', CheckState.cleared);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fetches, 2);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
