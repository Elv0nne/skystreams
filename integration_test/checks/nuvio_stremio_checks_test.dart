/// Nuvio scrapers and Stremio add-ons meeting a bot check, cleared by the app's own browser, on
/// the device: against [FakeCloudflare], a local stand-in for Cloudflare's check, so it runs the
/// same on every platform.
///
/// ```
/// flutter test integration_test/checks/nuvio_stremio_checks_test.dart -d DEVICE \
///   --dart-define=CHECKS_E2E=true
/// ```
///
/// Prints `CHECKS-E2E {json}`. It forgets the app's saved clearances between phases: run it on a
/// test profile (macOS: the test app id).
///
/// With `--dart-define=DPAD=true`, one more step waits for a person: a check whose checkbox no
/// automatic tap reaches opens its sheet, and prints `CHECKS-DPAD sheet` for the host to tick
/// it: with the D-pad on a TV (`adb shell input keyevent`), with a tap on a phone
/// (`adb shell input tap`).
// The printed line is the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/nuvio/data/nuvio_repository.dart';
import 'package:skystream/core/nuvio/data/nuvio_stream_service.dart';

import '../cloudstream/support.dart' show pumpUntil, withApp;
import 'fake_cloudflare.dart';

const _run = bool.fromEnvironment('CHECKS_E2E');
const _dpad = bool.fromEnvironment('DPAD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Nuvio scrapers and Stremio add-ons get past a bot check through the app\'s browser',
    skip: !_run,
    timeout: const Timeout(Duration(minutes: 10)),
    (tester) async {
      final site = (await tester.runAsync(FakeCloudflare.start))!;
      final report = <String, Object?>{};
      try {
        await withApp(tester, (container) async {
          final clearance = Clearance.instance;
          await tester.runAsync(clearance.init);
          final nuvio = container.read(nuvioRepositoryProvider.notifier);
          final addons = container.read(addonRepositoryProvider.notifier);
          final manifestUrl = '${site.origin}/nuvio/manifest.json';
          final addonUrl = '${site.origin}/addon/manifest.json';

          /// A fresh check: the site's secret changes and the app forgets its clearances.
          void freshCheck() {
            site.rotate();
            clearance.store.clear();
          }

          Future<
            ({
              int streams,
              int solves,
              SiteCheck? check,
              List<String> status,
              double seconds,
            })
          >
          scraper(String id, {bool personWaiting = true}) async {
            final solvesBefore = site.solves;
            final watch = Stopwatch()..start();
            final progress = await tester.runAsync(
              () => container
                  .read(nuvioStreamServiceProvider)
                  .resolve(
                    tmdbId: '603',
                    mediaType: 'movie',
                    personWaiting: personWaiting,
                    only: {id},
                    fresh: true,
                  )
                  .last,
            );
            return (
              streams: progress!.streams.length,
              solves: site.solves - solvesBefore,
              check: clearance.checks['127.0.0.1'],
              status: [
                for (final s in progress.statuses) s.message ?? s.outcome.name,
              ],
              seconds: watch.elapsedMilliseconds / 1000,
            );
          }

          try {
            await tester.runAsync(() => nuvio.addRepository(manifestUrl));

            // 1. A scraper that calls Cloudflare.solve itself.
            freshCheck();
            final solved = await scraper('fakecf-solve');
            report['cloudflareSolve'] = {
              'streams': solved.streams,
              'solves': solved.solves,
            };
            expect(solved.streams, 1);
            expect(solved.solves, greaterThanOrEqualTo(1));

            // 2. The clearance it left serves another scraper: no check, no solve.
            final challengesBefore = site.challenges;
            final reused = await scraper('fakecf-auto');
            report['clearanceShared'] = {
              'streams': reused.streams,
              'newChallenges': site.challenges - challengesBefore,
            };
            expect(reused.streams, 1);
            expect(site.challenges, challengesBefore);

            // 3. A scraper that leaves the check to the app.
            freshCheck();
            final auto = await scraper('fakecf-auto');
            report['automatic'] = {
              'streams': auto.streams,
              'solves': auto.solves,
              'checkState': auto.check?.state.name,
              'checkSources': auto.check?.sources.toList(),
            };
            expect(auto.streams, 1);
            expect(auto.solves, greaterThanOrEqualTo(1));
            expect(auto.check?.sources, contains('nuvio:fakecf-auto'));

            // 4. A scraper's own timeout doesn't run out while the app clears its check: its
            // timer waits with the run.
            freshCheck();
            // Longer than the scraper's own 5 s, which leaves a cold device time for the
            // request that meets the check.
            site.checkTakes = const Duration(seconds: 8);
            final timed = await scraper('fakecf-timer');
            site.checkTakes = const Duration(milliseconds: 500);
            report['ownTimeout'] = {
              'streams': timed.streams,
              'solves': timed.solves,
              'status': timed.status,
              'seconds': timed.seconds,
            };
            expect(timed.solves, greaterThanOrEqualTo(1));
            expect(timed.streams, 1);

            // 4b. A check that waits for its checkbox, with nobody waiting: the hidden solve ticks
            // it where the platform can tap; elsewhere (iOS) it waits for a person, as before.
            freshCheck();
            site.tapToClear = true;
            final ticked = await scraper('fakecf-auto', personWaiting: false);
            site.tapToClear = false;
            final canTap = clearance.solver.canTap;
            report['tap'] = {
              'canTap': canTap,
              'streams': ticked.streams,
              'solves': ticked.solves,
              'checkState': ticked.check?.state.name,
              'seconds': ticked.seconds,
            };
            if (canTap) {
              expect(ticked.streams, 1);
              expect(ticked.solves, greaterThanOrEqualTo(1));
            } else {
              expect(ticked.streams, 0);
              expect(ticked.solves, 0);
              expect(ticked.check?.state, CheckState.needsYou);
            }

            // 4c (DPAD=true): the taps miss, and the person waiting gets the sheet, ticked by the
            // host: the D-pad on a TV, a tap on a phone.
            if (_dpad) {
              freshCheck();
              site
                ..tapToClear = true
                ..tapMisses = true;
              final solvesBefore = site.solves;
              final watch = Stopwatch()..start();
              NuvioProgress? done;
              Object? failed;
              final resolving = container
                  .read(nuvioStreamServiceProvider)
                  .resolve(
                    tmdbId: '603',
                    mediaType: 'movie',
                    personWaiting: true,
                    only: {'fakecf-auto'},
                    fresh: true,
                  )
                  .last
                  .then<void>(
                    (p) => done = p,
                    onError: (Object e) {
                      failed = e;
                    },
                  );
              // A phone's person taps (`adb shell input tap`): the test lets real touches through.
              final binding = IntegrationTestWidgetsFlutterBinding.instance;
              binding.shouldPropagateDevicePointerEvents = true;
              try {
                // The sheet is the app's own: it shows and takes keys only while frames come.
                var announced = false;
                await pumpUntil(
                  tester,
                  () {
                    if (!announced &&
                        clearance.checks['127.0.0.1']?.state ==
                            CheckState.opening) {
                      announced = true;
                      print('CHECKS-DPAD sheet');
                    }
                    return done != null || failed != null;
                  },
                  what: 'the scraper, ticked through the sheet',
                  timeout: const Duration(minutes: 4),
                );
                await resolving;
              } finally {
                binding.shouldPropagateDevicePointerEvents = false;
              }
              site
                ..tapToClear = false
                ..tapMisses = false;
              report['dpad'] = {
                'streams': done?.streams.length,
                'solves': site.solves - solvesBefore,
                'checkState': clearance.checks['127.0.0.1']?.state.name,
                'seconds': watch.elapsedMilliseconds / 1000,
                if (failed != null) 'error': '$failed',
              };
              expect(done?.streams, hasLength(1));
              expect(clearance.checks['127.0.0.1']?.state, CheckState.cleared);
            }

            // 5. An add-on behind the check: installing it meets the check (filed under its
            // address: its id comes with the manifest), then its streams pass on the clearance.
            freshCheck();
            final installed = await tester.runAsync(
              () => addons.install(addonUrl),
            );
            final afterInstall = site.challenges;
            final streams = await tester.runAsync(
              () => container
                  .read(addonClientProvider)
                  .streams(
                    installed!,
                    type: 'movie',
                    id: 'tt1',
                    personWaiting: true,
                  ),
            );
            report['addon'] = {
              'installed': installed?.manifest?.name,
              'streams': streams?.length,
              'newChallengesForStreams': site.challenges - afterInstall,
              'checkSources': clearance.checks['127.0.0.1']?.sources.toList(),
            };
            expect(installed?.manifest?.id, 'test.fakecf');
            expect(streams, hasLength(1));
            expect(site.challenges, afterInstall);
            expect(
              clearance.checks['127.0.0.1']?.sources,
              contains('addon:$addonUrl'),
            );
            expect(clearance.checks['127.0.0.1']?.state, CheckState.cleared);

            // 6. A block page: no solve, and a plain message.
            final blocked = ManagedAddon(
              manifestUrl: '${site.origin}/blocked/manifest.json',
              addedAt: DateTime.now(),
              manifest: AddonManifest.fromJson({
                'id': 'test.blocked',
                'name': 'Blocked',
                'version': '1.0.0',
                'resources': ['stream'],
                'types': ['movie'],
              }),
            );
            final solvesBefore = site.solves;
            Object? error;
            await tester.runAsync(() async {
              try {
                await container
                    .read(addonClientProvider)
                    .streams(
                      blocked,
                      type: 'movie',
                      id: 'tt1',
                      personWaiting: true,
                    );
              } catch (e) {
                error = e;
              }
            });
            report['blocked'] = {
              'error': '$error',
              'solves': site.solves - solvesBefore,
            };
            expect(error, isA<AddonBlockedException>());
            expect(site.solves, solvesBefore);
          } finally {
            await tester.runAsync(() async {
              await nuvio.removeRepository(manifestUrl);
              await addons.remove(addonUrl);
            });
            print('CHECKS-E2E ${jsonEncode(report)}');
          }
        });
      } finally {
        await tester.runAsync(site.close);
      }
    },
  );
}
