/// The other extension windows that ask for the whole screen (Phase 7c part 3), where they can be reached:
/// - Comix's reader and Witanime's player open from a title's Play (their sites decide whether there's one to show);
/// - StreamHubOne's and CineStream's Cloudflare pages open from a row of their settings, opened as a person opens them
///   (CloudStream's settings, the extension's settings button, a row of its sheet).
/// Each should show in the full-screen view, with no sheet, and go with Back. One `CS3-FULLSCREEN {json}` line per
/// window; a window that can't be reached says why, and the run goes on.
///
/// ```
/// flutter test integration_test/cloudstream/fullscreen_windows_test.dart -d DEVICE --dart-define=CS3_E2E=true
/// ```
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_full_screen.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_sheet.dart';

import 'support.dart';

const _phisher =
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json';
const _arabic = 'https://raw.githubusercontent.com/Abodabodd/re-3arabi/refs/heads/main/repo';
const _desi = 'https://raw.githubusercontent.com/Faisal0786/Desi/main/repo.json';
const _csx = 'https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json';

/// `FULLSCREEN_ONLY=Comix,CineStream` picks windows by extension.
const _only = String.fromEnvironment('FULLSCREEN_ONLY');
bool _picked(String name) => _only.isEmpty || _only.split(',').contains(name);

/// Windows from a title's Play: the search that finds a title with one (the extension survey's).
const _plays = [(_phisher, 'Comix', "The Crown I'll Claim"), (_arabic, 'Witanime', 'naruto')];

/// Windows from a settings row: its words. CineStream's Cloudflare card opens first, then its site's Open.
final _rows = [
  (_desi, 'StreamHubOne', RegExp('cloudflare', caseSensitive: false)),
  (_csx, 'CineStream', RegExp(r'cloudflare|^\W*open$', caseSensitive: false)),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'the other windows that ask for the whole screen show in the full-screen view',
    (tester) async {
      await withApp(tester, (container) async {
        final host = container.read(cloudStreamEngineHostProvider);
        final notifier = container.read(cloudStreamRepositoryProvider.notifier);
        final changes = await CloudStreamChanges.note(tester, container);
        final events = <Map<String, dynamic>>[];
        final listening = host.events.listen(events.add);
        try {
          for (final (repository, name, query) in _plays.where((p) => _picked(p.$2))) {
            final line = <String, Object?>{'window': name, 'from': 'play'};
            try {
              await _fromPlay(tester, host, notifier, events, repository, name, query, line);
            } catch (e) {
              line['error'] = '$e'.split('\n').first;
            }
            print('CS3-FULLSCREEN ${asciiJson(line)}');
          }
          for (final (repository, name, row) in _rows.where((r) => _picked(r.$2))) {
            final line = <String, Object?>{'window': name, 'from': 'settings'};
            try {
              await _fromSettings(tester, host, notifier, events, repository, name, row, line);
            } catch (e) {
              line['error'] = '$e'.split('\n').first;
            }
            print('CS3-FULLSCREEN ${asciiJson(line)}');
          }
        } finally {
          await listening.cancel();
          await changes.undo(tester, container);
        }
      });
    },
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

/// The installed extension [name] from [repository]: its path, its first provider and where it came from.
Future<({String path, String provider, String? url})> _install(
  WidgetTester tester,
  CloudStreamRepository notifier,
  String repository,
  String name,
) async {
  late ({String path, String provider, String? url}) installed;
  await tester.runAsync(() async {
    final repo = await notifier.addRepository(repository);
    final listed = repo.plugins.firstWhere((p) => p.internalName == name);
    final plugin = await notifier.install(listed);
    installed = (path: plugin.filePath, provider: plugin.providers.first.name, url: listed.url);
  });
  return installed;
}

/// Whether one of [events]' screens shows a full-screen window: the last such window.
Map<String, dynamic>? _fullScreenWindow(Iterable<Map<String, dynamic>> events) {
  for (final event in events.toList().reversed) {
    if (event['event'] != 'ui') continue;
    for (final window in ((event['windows'] as List?) ?? const []).reversed) {
      if ((window as Map)['fullScreen'] == true) return Map<String, dynamic>.from(window);
    }
  }
  return null;
}

/// The window [window] as the line reports it, and how the app shows it.
void _report(WidgetTester tester, Map<String, dynamic> window, Map<String, Object?> line) {
  line['fullScreen'] = true;
  line['keepScreenOn'] = window['keepScreenOn'];
  line['orientation'] = window['orientation'];
  line['view'] = find.byType(ExtensionFullScreen).evaluate().isNotEmpty;
  line['sheet'] = find.byType(ExtensionSheet).evaluate().isNotEmpty;
}

/// Back, then again a second later if the window is still there: a full-screen window's way out.
Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await pumpFor(tester, const Duration(seconds: 1));
  if (find.byType(ExtensionFullScreen).evaluate().isNotEmpty) await tester.binding.handlePopRoute();
  await pumpUntil(
    tester,
    () => find.byType(ExtensionFullScreen).evaluate().isEmpty,
    what: 'the full-screen view gone',
    timeout: const Duration(seconds: 30),
  );
}

Future<void> _fromPlay(
  WidgetTester tester,
  CloudStreamEngineHost host,
  CloudStreamRepository notifier,
  List<Map<String, dynamic>> events,
  String repository,
  String name,
  String query,
  Map<String, Object?> line,
) async {
  final (:path, :provider, :url) = await _install(tester, notifier, repository, name);
  final found = await whilePumping(
    tester,
    host.run(
      path,
      (e) => e.search(provider, query, plugin: path),
      kind: 'search',
      pluginUrl: url,
    ),
  );
  var items = (found['items'] as List?) ?? const [];
  line['results'] = items.length;
  if (items.isEmpty) {
    // Its home page, then: the first title there.
    final home = await whilePumping(
      tester,
      host.run(
        path,
        (e) => e.mainPage(provider, plugin: path),
        kind: 'mainPage',
        pluginUrl: url,
      ),
    );
    final sections = (home['sections'] as List?) ?? const [];
    items = sections.isEmpty ? const [] : ((sections.first as Map)['items'] as List?) ?? const [];
    line['homeResults'] = items.length;
    if (items.isEmpty) return;
  }
  final title = await whilePumping(
    tester,
    host.run(
      path,
      (e) => e.load(provider, (items.first as Map)['url'] as String, plugin: path),
      kind: 'load',
      pluginUrl: url,
    ),
  );
  final episodes = (title['episodes'] as List?) ?? const [];
  final data = title['dataUrl'] as String? ?? (episodes.isEmpty ? null : (episodes.first as Map)['data'] as String?);
  line['played'] = data != null;
  if (data == null) return;

  // What Play puts under a window: the player's opaque page.
  final navigator = Navigator.of(tester.element(find.byType(Scaffold).first), rootNavigator: true);
  final under = PageRouteBuilder<void>(
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
  );
  unawaited(navigator.push(under));
  await pumpFor(tester, const Duration(milliseconds: 300));
  final from = events.length;
  var ended = false;
  Map<String, dynamic>? answer;
  host
      .run(
        path,
        (e) => e.loadLinks(provider, data, plugin: path),
        kind: 'loadLinks',
        pluginUrl: url,
      )
      .then<void>((value) => answer = value, onError: (Object e) => line['callError'] = '$e'.split('\n').first)
      .whenComplete(() => ended = true)
      .ignore();
  await pumpUntil(
    tester,
    () => _fullScreenWindow(events.skip(from)) != null || ended,
    what: "$name's window",
    timeout: const Duration(minutes: 2),
  );
  // A window can come just after the call answers: Comix's reader opens once it has handed back its one link.
  if (_fullScreenWindow(events.skip(from)) == null) {
    await pumpUntil(
      tester,
      () => _fullScreenWindow(events.skip(from)) != null,
      what: "$name's window after its call",
      timeout: const Duration(seconds: 15),
    ).catchError((Object _) {});
    line['afterCall'] = _fullScreenWindow(events.skip(from)) != null;
  }
  final window = _fullScreenWindow(events.skip(from));
  if (window == null) {
    line['fullScreen'] = false;
  } else {
    await pumpFor(tester, const Duration(seconds: 2));
    _report(tester, window, line);
    await _back(tester);
    line['closed'] = true;
  }
  await pumpUntil(tester, () => ended, what: "$name's Play call ending", timeout: const Duration(minutes: 2));
  final links = (answer?['links'] as List?) ?? const [];
  line['links'] = links.length;
  // What a Play that showed no window gave instead.
  line['linkNames'] = [for (final l in links.take(3)) '${(l as Map)['name']} ${'${l['url']}'.split('?').first}'];
  line['callFullScreen'] = answer?['fullScreen'];
  navigator.removeRoute(under);
  await pumpFor(tester, const Duration(milliseconds: 300));
}

Future<void> _fromSettings(
  WidgetTester tester,
  CloudStreamEngineHost host,
  CloudStreamRepository notifier,
  List<Map<String, dynamic>> events,
  String repository,
  String name,
  RegExp row,
  Map<String, Object?> line,
) async {
  final (:path, provider: _, :url) = await _install(tester, notifier, repository, name);
  final loaded = await whilePumping(tester, host.ensureLoaded(path, pluginUrl: url));
  if (loaded['hasSettings'] != true) {
    line['settings'] = false;
    return;
  }
  // Nothing left over the app from before: a window's view or a sheet.
  for (var i = 0; i < 4; i++) {
    if (find.byType(ExtensionFullScreen).evaluate().isEmpty && find.byType(ExtensionSheet).evaluate().isEmpty) break;
    await tester.binding.handlePopRoute();
    await pumpFor(tester, const Duration(seconds: 1));
  }
  // As a person opens it: CloudStream's settings, the extension's settings button, its sheet.
  final from = events.length;
  go(tester, '/settings/cloudstream');
  final button = find.byKey(ValueKey('cs3_settings_$name'));
  await waitFor(tester, button);
  await reveal(tester, button);
  await tester.tap(button);
  final sheet = find.byType(ExtensionSheet);
  await waitFor(tester, sheet, timeout: const Duration(seconds: 30));
  await pumpFor(tester, const Duration(seconds: 2));
  // The rows with [row]'s words, pressed in turn until a window takes the whole screen; a row pressed can show more
  // (a card that opens), so the sheet is read again each time.
  final full = find.byType(ExtensionFullScreen);
  final tried = <String>[];
  String label(Element e) => (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText() ?? '';
  for (var attempt = 0; attempt < 4 && full.evaluate().isEmpty; attempt++) {
    final rows = find.descendant(of: sheet, matching: find.textContaining(row));
    final labels = [for (final e in rows.evaluate()) label(e)];
    final index = labels.indexWhere((l) => !tried.contains(l));
    if (index < 0) break;
    tried.add(labels[index]);
    line['rows'] = tried;
    line['row'] = labels[index];
    final candidate = rows.at(index);
    await reveal(tester, candidate);
    await tester.tap(candidate, warnIfMissed: false);
    await pumpUntil(
      tester,
      () => full.evaluate().isNotEmpty,
      what: "$name's page",
      timeout: const Duration(seconds: 20),
    ).catchError((Object _) {});
  }
  final window = _fullScreenWindow(events.skip(from));
  if (full.evaluate().isEmpty) {
    line['fullScreen'] = window != null;
    line['view'] = false;
    // What the sheet shows instead: its texts, for the ledger.
    line['texts'] = [
      for (final e in find.descendant(of: sheet, matching: find.byType(Text)).evaluate().take(60))
        (e.widget as Text).data ?? (e.widget as Text).textSpan?.toPlainText(),
    ];
  } else {
    await pumpFor(tester, const Duration(seconds: 2));
    _report(tester, window ?? const {}, line);
    await _back(tester);
    line['closed'] = true;
  }
  // The sheet goes with Back too.
  for (var i = 0; i < 3 && sheet.evaluate().isNotEmpty; i++) {
    await tester.binding.handlePopRoute();
    await pumpFor(tester, const Duration(seconds: 1));
  }
  line['sheetClosed'] = sheet.evaluate().isEmpty;
}
