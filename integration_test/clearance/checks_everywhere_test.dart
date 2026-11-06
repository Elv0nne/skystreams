/// The bot checks a search meets, with the three SkyStream plugins whose
/// sites check: Movierulz, Tamilblasters and Zinkmovies. Movierulz's and
/// Tamilblasters' sites moved for good (`5movierulz.pictures` → `.works`,
/// `1tamilblasters.pro` → `.tech`), and Zinkmovies' sends the browser to
/// another site after its check.
///
/// ```
/// flutter test integration_test/clearance/checks_everywhere_test.dart \
///   -d DEVICE --dart-define=CLEARANCE_E2E=true
/// ```
///
/// The test doesn't install the plugins: copy their folders
/// (`com.igris.repo.{movierulz,tamilblasters,zinkmovies}`) into the app's
/// `extensions/plugin/` first. It empties the app's clearance store, so on a
/// computer run it under a test app id. Prints one `CHK {json}` line per
/// check as the search's first pass ends, `CHK-MOVES {json}` and
/// `CHK-RESULTS {json}`; then, for up to 3 minutes while checks are still
/// tried, `CHK-CHANGE {json}` for each change; then `CHK-END {json}`.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';

import '../cloudstream/support.dart';

const _live = bool.fromEnvironment('CLEARANCE_E2E');

const _plugins = {'Movierulz', 'Tamilblasters', 'Zinkmovies'};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the checks a search meets, the moves, and searching again',
    skip: !_live,
    (tester) async {
      await withApp(tester, (container) async {
        final clearance = Clearance.instance;
        // Every check from the start: no clearance held, no move known.
        clearance.store.clear();
        await pumpUntil(
          tester,
          () => _plugins.every(
            (name) => container
                .read(extensionManagerProvider)
                .any((p) => p.name == name),
          ),
          what: 'the plugins $_plugins',
        );

        final states = <SearchAggregateState>[];
        container.read(searchQueryProvider.notifier).set('Pushpa');
        final search = container.listen(searchResultsProvider, (_, next) {
          if (next.hasValue) states.add(next.value!);
        }, fireImmediately: true);
        try {
          await pumpUntil(
            tester,
            () => states.isNotEmpty && !states.last.isLoading,
            what: "the search's first pass",
            timeout: const Duration(minutes: 4),
          );
          final first = states.last;
          final began = first.startedAt!;
          final checks = clearance.checks;
          Map<String, Object?> row(SiteCheck check) => {
            'site': check.site,
            'state': check.state.name,
            'movedFrom': ?check.movedFrom,
            'elsewhere': ?check.elsewhere,
            'sources': check.sources.toList(),
            'seconds': checks.now.difference(check.since).inSeconds,
          };
          for (final check in checks.since(began)) {
            print('CHK ${jsonEncode(row(check))}');
          }
          print(
            'CHK-MOVES ${jsonEncode({for (final move in clearance.store.moves.entries) move.key: '${move.value}'})}',
          );
          print('CHK-RESULTS ${jsonEncode(_counts(first))}');

          // While a check is still tried, a site may clear, and the plugins
          // that met it search again.
          final shown = {
            for (final check in checks.since(began)) check.site: check.state,
          };
          final again = <String>{};
          final changes = checks.changes.listen((_) {
            for (final check in checks.since(began)) {
              if (shown[check.site] == check.state) continue;
              shown[check.site] = check.state;
              print('CHK-CHANGE ${jsonEncode(row(check))}');
            }
          });
          final end = DateTime.now().add(const Duration(minutes: 3));
          while (DateTime.now().isBefore(end)) {
            again.addAll(states.last.rerunning);
            final busy =
                checks.since(began).any((c) => c.pending) ||
                states.last.rerunning.isNotEmpty;
            if (!busy) break;
            await pumpFor(tester, const Duration(seconds: 1));
          }
          await changes.cancel();
          final last = states.last;
          print(
            'CHK-END ${jsonEncode({
              'checks': [for (final check in checks.since(began)) row(check)],
              'searchedAgain': again.toList(),
              'results': _counts(last),
            })}',
          );

          expect(
            checks.since(began),
            isNotEmpty,
            reason: 'the search met no check',
          );
          for (final (old, moved) in [
            ('5movierulz.pictures', '5movierulz.works'),
            ('1tamilblasters.pro', '1tamilblasters.tech'),
          ]) {
            // Moves are kept by host: the host of [old] the plugin asks.
            final to = [
              for (final move in clearance.store.moves.entries)
                if (clearance.siteKeys.siteOf(move.key) == old) move.value,
            ];
            expect(
              [for (final uri in to) clearance.siteKeys.siteOf(uri.host)],
              [moved],
              reason: '$old should be recorded as moved to $moved',
            );
            expect(
              checks[old],
              isNull,
              reason: 'a check was filed under $old, the old domain',
            );
          }
          // Searching again replaces only the plugins that did.
          final before = _counts(first);
          final after = _counts(last);
          for (final plugin in before.keys) {
            if (again.any((id) => _named(container, id) == plugin)) continue;
            expect(
              after[plugin],
              before[plugin],
              reason: "$plugin didn't search again, but its results changed",
            );
          }
        } finally {
          search.close();
          container.read(searchQueryProvider.notifier).set('');
        }
      });
    },
  );
}

/// Each plugin's result count.
Map<String, int> _counts(SearchAggregateState state) => {
  for (final result in state.results)
    result.providerName: result.results.length,
};

/// The name of the plugin [id] is the package of.
String? _named(ProviderContainer container, String id) => container
    .read(extensionManagerProvider)
    .where((p) => p.packageName == id)
    .firstOrNull
    ?.name;
