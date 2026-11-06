/// CloudStream extensions that reach into the CloudStream app itself rather than its library:
/// accounts and sync (CineStream, TorraStream, StreamCenter), an older plugin's account settings
/// (FStream, left out since 2026-10-08: its repository answers every app with a login page), the
/// Chillx extractor the library dropped (Gomov, Ngefilm, Nodrakorid), and where the plugin was
/// installed from (ViStream). The engine gives them stand-ins of those classes
/// (2026-10-03), so each must load everywhere. Their sites come and go, so links are reported, not
/// required.
///
/// Prints one `CS3-APP {json}` line per extension (with the app's browser requests it made and the
/// check sheets left waiting for a person), then `CS3-APP-END {json}`. A repository that can't be
/// reached is reported, not failed: the extension never got to load.
///
/// ```
/// flutter test integration_test/cloudstream/app_classes_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true [--dart-define=APP_ONLY=CineStream,ViStreamProvider]
/// ```
///
/// Installs the extensions, and takes the device's CloudStream setup back afterwards. FshareProvider
/// is left out: it only registers inside the official CloudStream app, whose signing certificate it
/// checks.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';

import 'extension_run.dart';
import 'resolver_group.dart' show ResolverExtension;
import 'support.dart';

const _only = String.fromEnvironment('APP_ONLY');

const _indoStream =
    'https://raw.githubusercontent.com/TeKuma25/IndoStream/builds/repo.json';

/// [ResolverExtension.androidLinks]: what Android gave on 2026-10-03.
const appClassGroup = <ResolverExtension>[
  (
    repository:
        'https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json',
    name: 'CineStream',
    query: 'avengers',
    androidLinks: 0,
  ),
  (
    repository: 'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json',
    name: 'TorraStream',
    query: 'avengers',
    androidLinks: 0,
  ),
  (
    repository: 'https://raw.githubusercontent.com/doGior/doGiorsHadEnough/refs/heads/builds/repo.json',
    name: 'StreamCenter',
    query: 'avengers endgame',
    androidLinks: 0,
  ),
  (repository: _indoStream, name: 'Gomov', query: 'love', androidLinks: 0),
  (repository: _indoStream, name: 'Ngefilm', query: 'love', androidLinks: 0),
  (repository: _indoStream, name: 'Nodrakorid', query: 'love', androidLinks: 0),
  (
    repository:
        'https://gitlab.com/tearrs/cloudstream-vietnamese/-/raw/main/repo.json',
    name: 'ViStreamProvider',
    query: 'avengers',
    androidLinks: 0,
  ),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'CloudStream extensions that need the app\'s own classes load',
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 60)),
    (tester) async {
      final only = {
        for (final name in _only.split(','))
          if (name.trim().isNotEmpty) name.trim(),
      };
      final group = [
        for (final extension in appClassGroup)
          if (only.isEmpty || only.contains(extension.name)) extension,
      ];
      final notLoaded = <String>[];
      final unreachable = <String>[];
      await withApp(tester, (container) async {
        final changes = await CloudStreamChanges.note(tester, container);
        final host = container.read(cloudStreamEngineHostProvider);
        final asked = <String, int>{};
        final events = host.events.listen((event) {
          if (event['event'] != 'webRequest') return;
          final op = event['op'] as String? ?? 'solve';
          asked[op] = (asked[op] ?? 0) + 1;
        });
        var withLinks = 0;
        try {
          for (final extension in group) {
            final report = <String, Object?>{'extension': extension.name};
            final before = Map.of(asked);
            final watch = Stopwatch()..start();
            await runExtension(extension, report, tester, container, host);
            report['seconds'] = watch.elapsedMilliseconds / 1000;
            report['asked'] = {
              for (final op in asked.keys)
                if (asked[op] != (before[op] ?? 0))
                  op: asked[op]! - (before[op] ?? 0),
            };
            // A check that wants a person waits in its sheet, as it would for a person who
            // walked away: noted, then closed as a person would.
            await tester.pump(const Duration(seconds: 1));
            final sheets = find.byType(ChallengeBrowserView);
            report['sheetsWaiting'] = sheets.evaluate().length;
            while (sheets.evaluate().isNotEmpty) {
              Navigator.of(tester.element(sheets.first)).pop();
              await tester.pump(const Duration(seconds: 1));
            }
            print('CS3-APP ${jsonEncode(report)}');
            final error = report['error'] as String?;
            if (error == 'not loaded') notLoaded.add(extension.name);
            if (error?.startsWith('install:') ?? false) {
              unreachable.add(extension.name);
            }
            if (((report['links'] as int?) ?? 0) > 0) withLinks++;
          }
          print(
            'CS3-APP-END ${jsonEncode({'extensions': group.length, 'withLinks': withLinks, 'notLoaded': notLoaded, 'unreachable': unreachable})}',
          );
        } finally {
          await events.cancel();
          await changes.undo(tester, container);
        }
      });
      expect(notLoaded, isEmpty);
    },
  );
}
