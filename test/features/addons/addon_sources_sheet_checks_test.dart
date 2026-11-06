import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/data/addon_stream_service.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/features/addons/presentation/addon_sources_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

final _addon = ManagedAddon(
  manifestUrl: 'https://addon.test/manifest.json',
  addedAt: DateTime(2026),
  manifest: AddonManifest.fromJson({
    'id': 'test.addon',
    'name': 'Test',
    'version': '1.0.0',
    'resources': ['stream'],
    'types': ['movie'],
  }),
);

class _Repo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(addons: [_addon], isLoading: false);
}

/// Notes each resolve. The add-on first comes back empty (it met a check);
/// asked again on its own, it has a stream.
class _Service implements AddonStreamService {
  final calls =
      <({bool personWaiting, Set<String>? only, bool forceRefresh})>[];

  @override
  Stream<AddonStreamProgress> resolve({
    required List<dynamic> addons,
    required AddonStreamRequest request,
    bool forceRefresh = false,
    dynamic cancelToken,
    bool personWaiting = false,
    Set<String>? only,
  }) async* {
    calls.add((
      personWaiting: personWaiting,
      only: only,
      forceRefresh: forceRefresh,
    ));
    if (only == null) {
      yield const AddonStreamProgress(
        statuses: [
          AddonQueryStatus(addonName: 'Test', outcome: AddonQueryOutcome.empty),
        ],
        completedCount: 1,
        totalCount: 1,
      );
      return;
    }
    yield const AddonStreamProgress(
      streams: [
        AddonStreamSource(
          addonId: 'test.addon',
          addonName: 'Test',
          name: 'Found 1080p',
          title: 'Found',
          url: 'https://cdn.test/found.mkv',
        ),
      ],
      statuses: [
        AddonQueryStatus(
          addonName: 'Test',
          outcome: AddonQueryOutcome.links,
          linkCount: 1,
        ),
      ],
      completedCount: 1,
      totalCount: 1,
    );
  }

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// An add-on with a stream to start the remote on, that met a check too.
class _OneStream extends _Service {
  @override
  Stream<AddonStreamProgress> resolve({
    required List<dynamic> addons,
    required AddonStreamRequest request,
    bool forceRefresh = false,
    dynamic cancelToken,
    bool personWaiting = false,
    Set<String>? only,
  }) async* {
    yield const AddonStreamProgress(
      streams: [
        AddonStreamSource(
          addonId: 'test.addon',
          addonName: 'Test',
          name: 'Found 1080p',
          title: 'Found',
          url: 'https://cdn.test/found.mkv',
        ),
      ],
      statuses: [
        AddonQueryStatus(
          addonName: 'Test',
          outcome: AddonQueryOutcome.links,
          linkCount: 1,
        ),
      ],
      completedCount: 1,
      totalCount: 1,
    );
  }
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

class _Probe implements LinkProbeService {
  @override
  Future<LinkProbeResult> probe(String url, {Map<String, String>? headers}) =>
      Future.value(const LinkProbeResult(reachable: true));

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Whether the control holding the focus is the one labelled [label].
bool _focusedOn(String label) {
  final node = FocusManager.instance.primaryFocus;
  // A scope holding the focus means no control does.
  final holder = node is FocusScopeNode ? null : node?.context?.widget;
  return holder != null &&
      find
          .descendant(of: find.byWidget(holder), matching: find.text(label))
          .evaluate()
          .isNotEmpty;
}

/// A Stremio add-on's sources sheet and the bot checks its add-ons meet.
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

  testWidgets('on TV, UP from the filters reaches the status line\'s Details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          addonStreamServiceProvider.overrideWithValue(_OneStream()),
          addonRepositoryProvider.overrideWith(_Repo.new),
          linkProbeServiceProvider.overrideWithValue(_Probe()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(brightness: Brightness.dark),
          home: AddonSourcesSheet(
            item: MultimediaItem(title: 'T', url: '', posterUrl: ''),
            request: const AddonStreamRequest(type: 'movie', contentId: 'tt1'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Details'), findsOneWidget);
    // From the first stream: the filters, then the status line above them.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(
      _focusedOn('Details'),
      isTrue,
      reason: 'UP from the filters skipped Details',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'on TV, with the keyboard put away, DOWN leaves the links search',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            addonStreamServiceProvider.overrideWithValue(_OneStream()),
            addonRepositoryProvider.overrideWith(_Repo.new),
            linkProbeServiceProvider.overrideWithValue(_Probe()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(brightness: Brightness.dark),
            home: AddonSourcesSheet(
              item: MultimediaItem(title: 'T', url: '', posterUrl: ''),
              request: const AddonStreamRequest(
                type: 'movie',
                contentId: 'tt1',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('Search links'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final field = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode;
      expect(field.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        field.hasFocus,
        isFalse,
        reason: 'DOWN stayed in the links search',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'on TV, UP from the first stream reaches Verify, and select presses it',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            addonStreamServiceProvider.overrideWithValue(_OneStream()),
            addonRepositoryProvider.overrideWith(_Repo.new),
            linkProbeServiceProvider.overrideWithValue(_Probe()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(brightness: Brightness.dark),
            home: AddonSourcesSheet(
              item: MultimediaItem(title: 'T', url: '', posterUrl: ''),
              request: const AddonStreamRequest(
                type: 'movie',
                contentId: 'tt1',
              ),
            ),
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
      // The remote starts on the stream, not on Verify.
      final start = FocusManager.instance.primaryFocus!.rect;
      expect(
        start.contains(tester.getCenter(find.textContaining('Found').first)),
        isTrue,
      );
      expect(start.contains(tester.getCenter(find.text('Verify'))), isFalse);

      bool onVerify() =>
          Focus.of(tester.element(find.text('Verify'))).hasPrimaryFocus;
      // The check line sits right above the streams it holds back.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(
        onVerify(),
        isTrue,
        reason: 'UP from the first stream missed Verify',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(solver.verified, ['addon.test']);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an add-on\'s check shows with Verify, and once cleared it alone is asked again',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = _Service();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            addonStreamServiceProvider.overrideWithValue(service),
            addonRepositoryProvider.overrideWith(_Repo.new),
            linkProbeServiceProvider.overrideWithValue(_Probe()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(brightness: Brightness.dark),
            home: AddonSourcesSheet(
              item: MultimediaItem(title: 'T', url: '', posterUrl: ''),
              request: const AddonStreamRequest(
                type: 'movie',
                contentId: 'tt1',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.calls.single.personWaiting, isTrue);

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

      expect(service.calls, hasLength(2));
      expect(service.calls.last.only, {'test.addon'});
      expect(service.calls.last.forceRefresh, isTrue);
      expect(find.textContaining('Found'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
