import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/core/network/link_probe_service.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/sources/presentation/plugin_sources_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

class _Repo extends NuvioRepository {
  @override
  NuvioState build() => NuvioState(
    isLoading: false,
    repos: [
      NuvioRepo(
        manifestUrl: 'https://repo.test/manifest.json',
        addedAt: DateTime(2026),
        manifest: const NuvioManifest(
          name: 'Repo',
          version: '1',
          scrapers: [
            NuvioScraperInfo(
              id: 'a',
              name: 'A',
              version: '1',
              filename: 'a.js',
            ),
            NuvioScraperInfo(
              id: 'b',
              name: 'B',
              version: '1',
              filename: 'b.js',
            ),
          ],
        ),
      ),
    ],
  );
}

/// Notes each resolve. The first run ends with A empty (it met a check) and
/// B still running; a run of A alone finds its stream.
class _Service implements NuvioStreamService {
  final calls = <({bool personWaiting, Set<String>? only, bool fresh})>[];

  @override
  Stream<NuvioProgress> resolve({
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
    bool personWaiting = false,
    Set<String>? only,
    bool fresh = false,
  }) async* {
    calls.add((personWaiting: personWaiting, only: only, fresh: fresh));
    if (only == null) {
      yield const NuvioProgress(
        statuses: [
          NuvioScraperStatus(
            scraperName: 'A',
            outcome: NuvioScraperOutcome.empty,
          ),
          NuvioScraperStatus(
            scraperName: 'B',
            outcome: NuvioScraperOutcome.running,
          ),
        ],
        completedCount: 1,
        totalCount: 2,
      );
      return;
    }
    yield const NuvioProgress(
      streams: [
        NuvioStreamResult(
          scraperId: 'a',
          scraperName: 'A',
          title: 'Movie from A',
          url: 'https://cdn.test/a.mkv',
          quality: '1080p',
        ),
      ],
      statuses: [
        NuvioScraperStatus(
          scraperName: 'A',
          outcome: NuvioScraperOutcome.links,
          linkCount: 1,
        ),
      ],
      completedCount: 1,
      totalCount: 1,
      isLoading: false,
    );
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A run with B's stream to start the remote on; A met a check.
class _OneStream extends _Service {
  @override
  Stream<NuvioProgress> resolve({
    required String tmdbId,
    required String mediaType,
    int? season,
    int? episode,
    bool personWaiting = false,
    Set<String>? only,
    bool fresh = false,
  }) async* {
    yield const NuvioProgress(
      streams: [
        NuvioStreamResult(
          scraperId: 'b',
          scraperName: 'B',
          title: 'Movie from B',
          url: 'https://cdn.test/b.mkv',
          quality: '1080p',
        ),
      ],
      statuses: [
        NuvioScraperStatus(
          scraperName: 'A',
          outcome: NuvioScraperOutcome.empty,
        ),
        NuvioScraperStatus(
          scraperName: 'B',
          outcome: NuvioScraperOutcome.links,
          linkCount: 1,
        ),
      ],
      completedCount: 2,
      totalCount: 2,
      isLoading: false,
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
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

/// Nuvio's sources dialog and the bot checks its scrapers meet.
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
    final container = ProviderContainer(
      overrides: [
        nuvioStreamServiceProvider.overrideWithValue(_OneStream()),
        nuvioRepositoryProvider.overrideWith(_Repo.new),
        linkProbeServiceProvider.overrideWithValue(_Probe()),
        playerSettingsProvider.overrideWithBuild(
          (_, _) => const PlayerSettings(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(brightness: Brightness.dark),
          home: PluginSourcesSheet(
            target: MultimediaItem(
              title: 'Test Movie',
              url: '',
              posterUrl: '',
              tmdbId: 1234,
            ),
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
    'on TV, UP from the first stream reaches Verify, and select presses it',
    (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          nuvioStreamServiceProvider.overrideWithValue(_OneStream()),
          nuvioRepositoryProvider.overrideWith(_Repo.new),
          linkProbeServiceProvider.overrideWithValue(_Probe()),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(brightness: Brightness.dark),
            home: PluginSourcesSheet(
              target: MultimediaItem(
                title: 'Test Movie',
                url: '',
                posterUrl: '',
                tmdbId: 1234,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      checks
        ..met('a.com', source: 'nuvio:a')
        ..update('a.com', CheckState.needsYou);
      await tester.pump();
      await tester.pump();
      expect(find.text('Verify'), findsOneWidget);
      // The remote starts on the stream, not on Verify.
      final start = FocusManager.instance.primaryFocus!.rect;
      expect(
        start.contains(tester.getCenter(find.text('Movie from B'))),
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
      expect(solver.verified, ['a.com']);
    },
  );

  testWidgets(
    'a check a scraper met shows with Verify, and once cleared only that scraper runs again',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = _Service();
      final container = ProviderContainer(
        overrides: [
          nuvioStreamServiceProvider.overrideWithValue(service),
          nuvioRepositoryProvider.overrideWith(_Repo.new),
          linkProbeServiceProvider.overrideWithValue(_Probe()),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: ThemeData(brightness: Brightness.dark),
            home: PluginSourcesSheet(
              target: MultimediaItem(
                title: 'Test Movie',
                url: '',
                posterUrl: '',
                tmdbId: 1234,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(service.calls.single.personWaiting, isTrue);

      // A met a check that wants a person; B met one too, but is still running.
      checks
        ..met('a.com', source: 'nuvio:a')
        ..update('a.com', CheckState.needsYou)
        ..met('b.com', source: 'nuvio:b')
        ..update('b.com', CheckState.needsYou);
      // The checks' change arrives after the first frame.
      await tester.pump();
      await tester.pump();
      expect(find.text('a.com needs a quick check'), findsOneWidget);
      expect(find.text('Verify'), findsNWidgets(2));

      checks
        ..update('a.com', CheckState.cleared)
        ..update('b.com', CheckState.cleared);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(service.calls, hasLength(2));
      expect(service.calls.last.only, {'a'});
      expect(service.calls.last.fresh, isTrue);
      expect(find.text('Movie from A'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
