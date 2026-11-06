/// Research for Phase 3b (2026-10-03): the CloudStream extensions that build their own
/// `android.webkit.WebView` ([ownWebViewGroup]), run as the page-resolver test runs its group. On
/// Android the WebView is real; on the JVM it is a stub, so the two runs tell what a stand-in would
/// add.
///
/// For each extension, as the survey did: its search results for the survey's words, then its
/// home page's titles; the first of the first three with episodes is opened, and its first
/// episode's links loaded. Prints one `CS3-WVR {json}` line per extension,
/// then `CS3-WVR-END {json}` with the totals and the browser pages still open once idle pages
/// have closed.
///
/// ```
/// flutter test integration_test/cloudstream/web_resolver_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true [--dart-define=OWV_ONLY=CB01,AniSnatch]
/// ```
///
/// Installs the extensions, and takes the device's CloudStream setup back afterwards.
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:convert';
import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/network/clearance/clearance.dart';

import 'extension_run.dart';
import 'own_webview_group.dart';
import 'support.dart';

const _only = String.fromEnvironment('OWV_ONLY');

/// Extensions the JVM can't convert: StreamPlay's needs about 4 GB of heap.
const _jvmCannotLoad = {'StreamPlay'};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'CloudStream extensions that build their own WebView',
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 180)),
    (tester) async {
      final only = {
        for (final name in _only.split(','))
          if (name.trim().isNotEmpty) name.trim(),
      };
      final group = [
        for (final extension in ownWebViewGroup)
          if (only.isEmpty || only.contains(extension.name)) extension,
      ];
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
            final report = <String, Object?>{
              'extension': extension.name,
              'androidLinksThen': extension.androidLinks,
            };
            final before = Map.of(asked);
            final watch = Stopwatch()..start();
            if (!Platform.isAndroid &&
                _jvmCannotLoad.contains(extension.name)) {
              report['skipped'] = 'the JVM can\'t convert it';
            } else {
              await runExtension(extension, report, tester, container, host);
            }
            if (((report['links'] as int?) ?? 0) > 0) withLinks++;
            report['asked'] = {
              for (final op in asked.keys)
                if (asked[op] != (before[op] ?? 0))
                  op: asked[op]! - (before[op] ?? 0),
            };
            report['seconds'] = watch.elapsedMilliseconds / 1000;
            print('CS3-OWV ${jsonEncode(report)}');
          }
          // Pages kept a while (a site's origin, a check that wants a person)
          // close once idle: 60 and 120 s.
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 130)),
          );
          // A check sheet nobody answered stays up with its page, as it would
          // for a person who walked away: close each as a person would.
          // Frames run only when a test pumps, so build what the app opened
          // meanwhile before looking.
          await tester.pump(const Duration(seconds: 1));
          final sheets = find.byType(ChallengeBrowserView);
          final sheetsLeftOpen = sheets.evaluate().length;
          while (sheets.evaluate().isNotEmpty) {
            Navigator.of(tester.element(sheets.first)).pop();
            await tester.pump(const Duration(seconds: 1));
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 3)),
          );
          final clearance = Clearance.instance;
          print(
            'CS3-OWV-END ${jsonEncode({'extensions': group.length, 'withLinks': withLinks, 'androidWithLinksThen': group.where((e) => e.androidLinks > 0).length, 'asked': asked, 'sheetsLeftOpen': sheetsLeftOpen, 'pagesOpen': clearance.isReady ? clearance.solver.openPages : null})}',
          );
        } finally {
          await events.cancel();
          await changes.undo(tester, container);
        }
      });
    },
  );
}
