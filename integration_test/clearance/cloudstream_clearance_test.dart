/// CloudStream extensions whose sites sit behind Cloudflare, through the
/// engine bridge: the engine's interceptor meets the challenge and asks the
/// app (`webRequest`), the app's solver clears it in a hidden page, and the
/// engine sends the request again with the clearance. A second search within
/// the clearance's lifetime asks nothing.
///
/// ```
/// flutter test integration_test/clearance/cloudstream_clearance_test.dart \
///   -d DEVICE --dart-define=CLEARANCE_E2E=true
/// ```
///
/// Installs the extensions, and takes the device's CloudStream setup back
/// afterwards. Empties the app's clearance store first. Prints one
/// `CLR-CS3 {json}` line per extension and round.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/network/clearance/clearance.dart';

import '../cloudstream/support.dart';

const _live = bool.fromEnvironment('CLEARANCE_E2E');

const _arabic =
    'https://raw.githubusercontent.com/Abodabodd/re-3arabi/refs/heads/main/repo';
const _german =
    'https://raw.githubusercontent.com/Bnyro/GermanProviders/refs/heads/master/repo.json';

/// Extensions whose sites challenged a plain client in the MegaRepo survey.
/// Animerco refuses every request from outside a browser.
const _extensions = [
  (repository: _arabic, name: 'Anime4up', query: 'naruto'),
  (repository: _arabic, name: 'Witanime', query: 'naruto'),
  (repository: _arabic, name: 'Animerco', query: 'naruto'),
  (repository: _german, name: 'Moflix', query: 'batman'),
  (repository: _german, name: 'Kinoger', query: 'batman'),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'CloudStream extensions behind Cloudflare, through the engine bridge',
    skip: !_live,
    (tester) async {
      await withApp(tester, (container) async {
        final changes = await CloudStreamChanges.note(tester, container);
        final host = container.read(cloudStreamEngineHostProvider);
        final asked = <String>[];
        final events = host.events.listen((event) {
          if (event['event'] == 'webRequest') {
            asked.add('${event['op'] ?? 'solve'} ${event['url']}');
          }
        });
        try {
          for (final extension in _extensions) {
            await ensureInstalled(
              tester,
              container,
              repository: extension.repository,
              internalName: extension.name,
            );
          }
          final installed = container
              .read(cloudStreamRepositoryProvider)
              .installed;
          final providers = [
            for (final extension in _extensions)
              for (final plugin in installed)
                if (plugin.info.internalName == extension.name)
                  (
                    query: extension.query,
                    provider: CloudStreamProvider(
                      plugin: plugin,
                      pluginKey: CloudStreamRepository.keyOf(plugin.info),
                      info: plugin.providers.first,
                      host: host,
                    ),
                  ),
          ];

          // Start clean: no clearance in the app, none in the browser.
          final clearance = Clearance.instance;
          clearance.store.clear();
          await tester.runAsync(() async {
            final browser = await ChallengeBrowser.create();
            for (final p in providers) {
              await browser.deleteCookies(p.provider.mainUrl);
            }
            await browser.dispose();
          });

          for (final round in ['first', 'again']) {
            for (final p in providers) {
              final provider = p.provider;
              final site = clearance.siteKeys.siteOf(
                Uri.parse(provider.mainUrl).host,
              );
              final solvedBefore = clearance.store[site]?.solvedAt;
              final askedBefore = asked.length;
              final watch = Stopwatch()..start();
              int? results;
              String? error;
              await tester.runAsync(() async {
                try {
                  results = (await provider.search(p.query)).length;
                } catch (e) {
                  final text = '$e'.replaceAll('\n', ' ');
                  error = text.length > 160 ? text.substring(0, 160) : text;
                }
              });
              final entry = clearance.store[site];
              print(
                'CLR-CS3 ${jsonEncode({'round': round, 'extension': provider.pluginName, 'mainUrl': provider.mainUrl, 'site': site, 'results': results, 'error': ?error, 'engineAsked': asked.skip(askedBefore).toList(), 'solved': entry?.solvedAt != null && entry!.solvedAt != solvedBefore, 'clearance': entry?.hasClearance ?? false, 'needsPerson': entry?.needsPerson ?? false, 'seconds': watch.elapsedMilliseconds / 1000})}',
              );
            }
          }
        } finally {
          await events.cancel();
          await changes.undo(tester, container);
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
