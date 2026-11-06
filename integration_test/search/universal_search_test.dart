/// The search bar's Stremio and Nuvio sections, on the device: a local add-on that searches and
/// a local Nuvio repository ([FakeSources]), with TMDB for Nuvio's titles (its key comes with the
/// defines).
///
/// ```
/// flutter test integration_test/search/universal_search_test.dart -d DEVICE \
///   --dart-define=UNIVERSAL_SEARCH_E2E=true --dart-define-from-file=DEFINES.json
/// ```
///
/// Searches "matrix" in the Search tab, opens the add-on's result (Stremio's details page) and
/// Nuvio's film (its sources dialog, where the scraper's stream shows), and prints
/// `UNIVERSAL-SEARCH {json}`. The add-on and the repository are removed after.
// The printed line is the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/features/addons/presentation/addon_detail_screen.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';
import 'package:skystream/features/search/presentation/search_sources.dart';
import 'package:skystream/features/search/presentation/widgets/search_result_section.dart';
import 'package:skystream/features/sources/presentation/plugin_sources_sheet.dart';
import 'package:skystream/shared/widgets/multimedia_card.dart';

import '../cloudstream/support.dart' show go, pumpFor, pumpUntil, withApp;
import 'fake_sources.dart';

const _run = bool.fromEnvironment('UNIVERSAL_SEARCH_E2E');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Stremio add-ons and Nuvio search with the extensions, and open in their own pages',
    skip: !_run,
    timeout: const Timeout(Duration(minutes: 10)),
    (tester) async {
      final sources = (await tester.runAsync(FakeSources.start))!;
      final report = <String, Object?>{};
      try {
        await withApp(tester, (container) async {
          final addons = container.read(addonRepositoryProvider.notifier);
          final nuvio = container.read(nuvioRepositoryProvider.notifier);
          await tester.runAsync(() async {
            await addons.install(sources.addonUrl);
            await nuvio.addRepository(sources.nuvioUrl);
          });

          Finder section(SearchSourceKind kind) => find.byWidgetPredicate(
            (w) => w is SearchResultSection && w.kind == kind,
          );

          /// [title]'s card in [kind]'s section, looked up afresh each use: the
          /// results rebuild as the search goes on.
          Finder card(SearchSourceKind kind, String title) => find
              .ancestor(
                of: find.descendant(
                  of: section(kind),
                  matching: find.text(title),
                ),
                matching: find.byType(MultimediaCard),
              )
              .first;

          /// Taps [title]'s card in [kind]'s section, brought on screen first: a
          /// short window shows only the first section or two.
          Future<void> tapCard(SearchSourceKind kind, String title) async {
            final target = card(kind, title);
            await tester.ensureVisible(target);
            await pumpFor(tester, const Duration(milliseconds: 500));
            await tester.tap(target);
          }

          try {
            go(tester, '/search');
            await pumpFor(tester, const Duration(seconds: 2));
            container.read(searchQueryProvider.notifier).set('matrix');
            await pumpUntil(
              tester,
              () =>
                  section(SearchSourceKind.stremio).evaluate().isNotEmpty &&
                  section(SearchSourceKind.nuvio).evaluate().isNotEmpty,
              what: 'the Stremio and Nuvio sections',
              timeout: const Duration(minutes: 2),
            );
            report['sections'] = [
              for (final s in tester.widgetList<SearchResultSection>(
                find.byType(SearchResultSection),
              ))
                {
                  'name': s.providerName,
                  'kind': s.kind.name,
                  'results': s.results.length,
                },
            ];
            report['addonSearches'] = sources.searches;
            expect(
              find.descendant(
                of: section(SearchSourceKind.stremio),
                matching: find.text('Stremio'),
              ),
              findsOneWidget,
            );
            expect(
              find.descendant(
                of: section(SearchSourceKind.stremio),
                matching: find.text('Search Test'),
              ),
              findsOneWidget,
            );

            // The add-on's result opens Stremio's details page.
            await tapCard(SearchSourceKind.stremio, 'The Matrix');
            // Its title shows in capitals on some layouts.
            final matrix = find.byWidgetPredicate(
              (w) => w is Text && (w.data ?? '').toLowerCase() == 'the matrix',
            );
            await pumpUntil(
              tester,
              () => find
                  .descendant(
                    of: find.byType(AddonDetailScreen),
                    matching: matrix,
                  )
                  .evaluate()
                  .isNotEmpty,
              what: "Stremio's details page for The Matrix",
            );
            report['stremioOpened'] = true;

            go(tester, '/search');
            await pumpUntil(
              tester,
              () => section(SearchSourceKind.nuvio).evaluate().isNotEmpty,
              what: 'the search again',
            );

            // Nuvio's film opens its sources dialog, where the scraper runs.
            await tapCard(SearchSourceKind.nuvio, 'The Matrix');
            await pumpUntil(
              tester,
              () => find.byType(PluginSourcesSheet).evaluate().isNotEmpty,
              what: "Nuvio's sources dialog",
            );
            report['nuvioOpened'] = true;
            await pumpUntil(
              tester,
              () => find
                  .descendant(
                    of: find.byType(PluginSourcesSheet),
                    matching: find.textContaining('Plain'),
                  )
                  .evaluate()
                  .isNotEmpty,
              what: "the plain scraper's stream",
              timeout: const Duration(minutes: 1),
            );
            report['nuvioStream'] = true;
            Navigator.of(tester.element(find.byType(PluginSourcesSheet))).pop();
            await pumpFor(tester, const Duration(seconds: 1));
          } finally {
            container.read(searchQueryProvider.notifier).set('');
            await tester.runAsync(() async {
              await addons.remove(sources.addonUrl);
              await nuvio.removeRepository(sources.nuvioUrl);
            });
            print('UNIVERSAL-SEARCH ${jsonEncode(report)}');
          }
        });
      } finally {
        await tester.runAsync(sources.close);
      }
    },
  );
}
