/// CloudStream extensions that load a page to find their video: CloudStream's `WebViewResolver`,
/// or a library extractor built on it ([resolverGroup], from the survey of 2026-09-30).
/// On every platform the page loads hidden in SkyStream's own browser, and the engine matches the
/// requests it makes (on Android since 2026-10-02, in place of CloudStream's own WebView).
///
/// For each extension, as the survey did: its search results for the survey's words, then its
/// home page's titles; the first of the first three with episodes is opened, and its first
/// episode's links loaded. Prints one `CS3-WVR {json}` line per extension,
/// then `CS3-WVR-END {json}` with the totals and the browser pages still open once idle pages
/// have closed.
///
/// ```
/// flutter test integration_test/cloudstream/web_resolver_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true [--dart-define=WVR_ONLY=GuardaSerie,Streamed]
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_provider.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/http_defaults.dart';

import 'resolver_group.dart';
import 'support.dart';

const _only = String.fromEnvironment('WVR_ONLY');

/// Extensions the JVM can't convert: StreamPlay's needs about 4 GB of heap.
const _jvmCannotLoad = {'StreamPlay'};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'CloudStream extensions that resolve a page, through the app\'s browser',
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 180)),
    (tester) async {
      final only = {
        for (final name in _only.split(','))
          if (name.trim().isNotEmpty) name.trim(),
      };
      final group = [
        for (final extension in resolverGroup)
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
              await _try(extension, report, tester, container, host);
            }
            if (((report['links'] as int?) ?? 0) > 0) withLinks++;
            report['asked'] = {
              for (final op in asked.keys)
                if (asked[op] != (before[op] ?? 0))
                  op: asked[op]! - (before[op] ?? 0),
            };
            report['seconds'] = watch.elapsedMilliseconds / 1000;
            print('CS3-WVR ${jsonEncode(report)}');
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
            'CS3-WVR-END ${jsonEncode({'extensions': group.length, 'withLinks': withLinks, 'androidWithLinksThen': group.where((e) => e.androidLinks > 0).length, 'asked': asked, 'sheetsLeftOpen': sheetsLeftOpen, 'pagesOpen': clearance.isReady ? clearance.solver.openPages : null})}',
          );
        } finally {
          await events.cancel();
          await changes.undo(tester, container);
        }
      });
    },
  );
}

/// Installs [extension] and goes as far as its links, noting what happened
/// in [report].
Future<void> _try(
  ResolverExtension extension,
  Map<String, Object?> report,
  WidgetTester tester,
  ProviderContainer container,
  CloudStreamEngineHost host,
) async {
  // Not ensureInstalled: an install that fails inside its runAsync fails the
  // whole test, and some repositories list files that are gone.
  final notifier = container.read(cloudStreamRepositoryProvider.notifier);
  var installed = false;
  await tester.runAsync(() async {
    try {
      final repo = await notifier.addRepository(extension.repository);
      final listed = repo.plugins.firstWhere(
        (p) => p.internalName == extension.name,
      );
      if (container.read(cloudStreamRepositoryProvider).installedFor(listed) ==
          null) {
        await notifier.install(listed);
      }
      installed = true;
    } catch (e) {
      report['error'] = 'install: ${_short(e)}';
    }
  });
  if (!installed) return;
  final plugin = container
      .read(cloudStreamRepositoryProvider)
      .installed
      .where((p) => p.info.internalName == extension.name)
      .firstOrNull;
  if (plugin == null || plugin.providers.isEmpty) {
    report['error'] = 'not loaded';
    return;
  }
  final provider = CloudStreamProvider(
    plugin: plugin,
    pluginKey: CloudStreamRepository.keyOf(plugin.info),
    info: plugin.providers.first,
    host: host,
  );
  await tester.runAsync(() async {
    try {
      await () async {
        final query = extension.query;
        final found = query == null
            ? const <MultimediaItem>[]
            : await provider.search(query);
        report['results'] = found.length;
        // The survey's words were a title on that day's home page: the home
        // page now has today's.
        final candidates = [...found, ...await _home(provider)];
        for (final item in candidates.take(3)) {
          final MultimediaItem details;
          try {
            details = await provider.getDetails(item.url);
          } catch (_) {
            continue;
          }
          final episode = details.episodes?.firstOrNull;
          if (episode == null) continue;
          report['title'] = details.title;
          final streams = await provider.loadStreams(episode.url);
          report['links'] = streams.length;
          if (streams.isNotEmpty) report['probe'] = await _probe(streams.first);
          return;
        }
      }().timeout(const Duration(minutes: 4));
    } catch (e) {
      report['error'] = _short(e);
    }
  });
}

/// The titles of [provider]'s home page; none when it has none, or fails.
Future<List<MultimediaItem>> _home(CloudStreamProvider provider) async {
  try {
    return [for (final row in (await provider.getHome()).values) ...row];
  } catch (_) {
    return const [];
  }
}

/// What [stream]'s address answers when asked as the player asks it: with the link's own headers,
/// and the player's default agent when the link names none. A status code, or the error.
Future<String> _probe(StreamResult stream) async {
  final url = Uri.tryParse(stream.url);
  if (url == null || !url.isScheme('http') && !url.isScheme('https')) {
    return 'not http';
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client
        .getUrl(url)
        .timeout(const Duration(seconds: 15));
    final headers = {
      for (final e in (stream.headers ?? const <String, String>{}).entries)
        e.key.toLowerCase(): e.value,
    };
    request.headers.set(
      'user-agent',
      headers['user-agent'] ?? kDefaultBrowserUserAgent,
    );
    for (final e in headers.entries) {
      if (e.key != 'user-agent') request.headers.set(e.key, e.value);
    }
    request.headers.set('range', 'bytes=0-1023');
    final response = await request.close().timeout(const Duration(seconds: 15));
    await response.drain<void>();
    return '${response.statusCode}';
  } catch (e) {
    return 'error: ${_short(e)}';
  } finally {
    client.close(force: true);
  }
}

String _short(Object error) {
  final text = '$error'.replaceAll('\n', ' ');
  return text.length > 200 ? text.substring(0, 200) : text;
}
