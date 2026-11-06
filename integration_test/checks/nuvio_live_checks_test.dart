/// Live Nuvio scrapers that met a bot check in the survey of 2026-10-04 (81 repositories found
/// online, 647 scrapers; 62 met a check), run in the app: what its browser clears by itself.
/// Nobody waits, so a check that wants a click is counted, not opened.
///
/// ```
/// flutter test integration_test/checks/nuvio_live_checks_test.dart -d DEVICE \
///   --dart-define=NUVIO_LIVE=true
/// ```
///
/// Prints one `NUVIO-LIVE {json}` line per scraper, then `NUVIO-LIVE-END {json}`. Each
/// repository is added for its scraper and removed after.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';

import '../cloudstream/support.dart' show withApp;

const _run = bool.fromEnvironment('NUVIO_LIVE');

/// One scraper per site that showed a check, and the repository listing it.
const _targets = <({String manifest, String id})>[
  (
    manifest: 'https://raw.githubusercontent.com/itsmeadarsh2008/Streamline/main/manifest.json',
    id: 'vegamovies',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/D3adlyRocket/Hindi-Nuvio/main/manifest.json',
    id: 'cinemacity',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/D3adlyRocket/Anime-Nuvio/main/manifest.json',
    id: 'animeworld',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/Gowaru/gowaru-nuvio-providers/main/manifest.json',
    id: 'french-anime',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/JaredJomar/Nuvio-JJJ/main/manifest.json',
    id: 'anidb',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/JaredJomar/Nuvio-JJJ/main/manifest.json',
    id: 'onlykdrama',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/arifbutitv/My_Nuvio_plugins/main/manifest.json',
    id: 'cinemacity',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/bebokurd/nuvio-plugins/main/manifest.json',
    id: 'nuvio-animepahe',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/municipalidad1998/nuvio-providers/main/manifest.json',
    id: 'jkanime',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/phisher98/phisher-nuvio-providers/main/manifest.json',
    id: 'Xdmovies',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/A2R14N/nuvio-providers/main/manifest.json',
    id: 'desenefaine',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/A2R14N/nuvio-providers/main/manifest.json',
    id: 'filmehd',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/A2R14N/nuvio-providers/main/manifest.json',
    id: '1shows',
  ),
  (
    manifest: 'https://raw.githubusercontent.com/Abinanthankv/nuvio-providers-test/main/manifest.json',
    id: 'tamilblasters',
  ),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'live Nuvio scrapers that met a bot check, through the app\'s browser',
    skip: !_run,
    timeout: const Timeout(Duration(minutes: 60)),
    (tester) async {
      await withApp(tester, (container) async {
        final clearance = Clearance.instance;
        await tester.runAsync(clearance.init);
        final repository = container.read(nuvioRepositoryProvider.notifier);
        var withStreams = 0;
        var cleared = 0;
        var wantedPerson = 0;
        for (final target in _targets) {
          final report = <String, Object?>{
            'manifest': target.manifest,
            'scraper': target.id,
          };
          final since = clearance.checks.now;
          final watch = Stopwatch()..start();
          try {
            await tester.runAsync(
              () => repository.addRepository(target.manifest),
            );
            final progress = await tester.runAsync(
              () => container
                  .read(nuvioStreamServiceProvider)
                  .resolve(
                    tmdbId: '299534',
                    mediaType: 'movie',
                    only: {target.id},
                    fresh: true,
                  )
                  .last,
            );
            report['streams'] = progress?.streams.length;
            report['status'] = progress?.statuses
                .map((s) => s.message ?? s.outcome.name)
                .toList();
          } catch (e) {
            report['error'] = '$e'.split('\n').first;
          } finally {
            await tester.runAsync(
              () => repository.removeRepository(target.manifest),
            );
          }
          final checks = clearance.checks.since(
            since,
            sources: {NuvioStreamService.sourceFor(target.id)},
          );
          report['checks'] = {for (final c in checks) c.site: c.state.name};
          report['seconds'] = watch.elapsedMilliseconds / 1000;
          if (((report['streams'] as int?) ?? 0) > 0) withStreams++;
          cleared += checks.where((c) => c.state.name == 'cleared').length;
          wantedPerson += checks.where((c) => c.wantsPerson).length;
          print('NUVIO-LIVE ${jsonEncode(report)}');
        }
        print(
          'NUVIO-LIVE-END ${jsonEncode({'scrapers': _targets.length, 'withStreams': withStreams, 'checksCleared': cleared, 'checksWantingAPerson': wantedPerson})}',
        );
      });
    },
  );
}
