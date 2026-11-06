/// Settings screens that open more screens from their own (StreamPlay's tiles, CineStream's sections),
/// walked step by step on a device: each tile tapped, then Back, from a freshly opened screen. Each step
/// prints `CS3-WALK {json}`: the windows the screen showed (all hidden?) and whether it ended. A window
/// that escapes SkyStream's sheet is logged by the engine ("…'s window shows as Android draws it"), in
/// logcat beside these lines; on Android, the test fails on any window shown unhidden (the desktops' and
/// iOS's windows are stand-ins nothing draws).
///
/// ```
/// flutter test integration_test/cloudstream/settings_walk_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true [--dart-define=WALK_ONLY=CineStream] --dart-define-from-file=DEFINES
/// ```
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';

import 'support.dart';

const _phisher =
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json';
const _csx = 'https://raw.githubusercontent.com/SaurabhKaperwan/CSX/builds/CS.json';
const _only = String.fromEnvironment('WALK_ONLY');

/// (repository, internal name, the tiles that open more), from the Android trees of 2026-10-05.
const walks = <(String, String, List<String>)>[
  (
    _phisher,
    'StreamPlay',
    [
      'Performance Settings',
      'Enable / Disable Sources',
      'Toggle Extensions',
      'Febbox Login',
      'Wyzie Key',
      'Stremio Catalog Addons',
      'Stremio Addons',
      'Change Language',
    ],
  ),
  (
    _csx,
    'CineStream',
    ['Scraping Settings', 'Cloudflare Bypass', 'API Tokens', 'Active Catalogs', 'Providers', 'Stremio Addons'],
  ),
];

Iterable<UiNode> _all(UiNode node) sync* {
  yield node;
  for (final child in node.children) {
    yield* _all(child);
  }
}

List<UiWindow>? _windows(List<Map<String, dynamic>> events, int session) {
  final last = events.lastWhere((e) => e['event'] == 'ui' && e['session'] == session, orElse: () => const {});
  if (last.isEmpty) return null;
  return [for (final w in last['windows'] as List) UiWindow.fromJson(Map<String, dynamic>.from(w as Map))];
}

/// One event, briefly: a screen's windows (kinds, all hidden, the top one's first words) or its end.
Object _describe(Map<String, dynamic> event) {
  if (event['event'] == 'uiClosed') return {'closed': event['reason']};
  if (event['event'] != 'ui') return {'event': event['event']};
  final windows = [for (final w in event['windows'] as List) UiWindow.fromJson(Map<String, dynamic>.from(w as Map))];
  return {
    'windows': [for (final w in windows) w.kind],
    if (Platform.isAndroid) 'hidden': windows.every((w) => w.hidden == true),
    if (windows.isNotEmpty)
      'top': _all(windows.last.root).map((n) => n.text).nonNulls.where((t) => t.trim().isNotEmpty).take(4).toList(),
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'screens that open more screens keep every window in the sheet',
    (tester) async {
      await withApp(tester, (container) async {
        final host = container.read(cloudStreamEngineHostProvider);
        final notifier = container.read(cloudStreamRepositoryProvider.notifier);
        final changes = await CloudStreamChanges.note(tester, container);
        final events = <Map<String, dynamic>>[];
        final listening = host.events.listen(events.add);
        final unhidden = <String>[];
        final wanted = _only.isEmpty ? null : _only.split(',').map((s) => s.trim()).toSet();
        try {
          for (final (repository, name, tiles) in walks) {
            if (wanted != null && !wanted.contains(name)) continue;
            // StreamPlay can't load on iOS (dex2jar's 512 MB heap drops its classes: part 2's ruling).
            if (Platform.isIOS && name == 'StreamPlay') {
              print('CS3-WALK ${asciiJson({'extension': name, 'skipped': "it can't load on iOS"})}');
              continue;
            }
            late String path;
            late String url;
            await tester.runAsync(() async {
              final repo = await notifier.addRepository(repository);
              final listed = repo.plugins.firstWhere((p) => p.internalName == name);
              final installed = await notifier.install(listed);
              path = installed.filePath;
              url = listed.url;
            });
            for (final tile in tiles) {
              final step = <String, Object?>{'extension': name, 'tile': tile};
              final session = await whilePumping(tester, host.openSettings(path, pluginUrl: url));
              await pumpUntil(
                tester,
                () => _windows(events, session) != null,
                what: '$name showing its screen',
                timeout: const Duration(seconds: 20),
              );
              final node = _windows(events, session)!
                  .expand((w) => _all(w.root))
                  .where((n) => n.tappable && _all(n).any((c) => (c.words ?? '').contains(tile)))
                  .firstOrNull;
              if (node == null) {
                step['missing'] = true;
              } else {
                // The tile, then Back on whatever it opened: each watched for 4 s.
                var from = events.length;
                await whilePumping(tester, host.uiAction(session, node.id, 'click'));
                await pumpFor(tester, const Duration(seconds: 4));
                step['tap'] = [
                  for (final e in events.sublist(from))
                    if (e['session'] == session) _describe(e),
                ];
                final open = !events.sublist(from).any((e) => e['event'] == 'uiClosed' && e['session'] == session);
                final top = open ? _windows(events, session)?.lastOrNull : null;
                if (top != null) {
                  from = events.length;
                  await whilePumping(tester, host.uiAction(session, top.root.id, 'close'));
                  await pumpFor(tester, const Duration(seconds: 4));
                  step['back'] = [
                    for (final e in events.sublist(from))
                      if (e['session'] == session) _describe(e),
                  ];
                }
              }
              final mine = events.where((e) => e['event'] == 'ui' && e['session'] == session);
              if (mine.any((e) => (_describe(e) as Map)['hidden'] == false)) unhidden.add('$name: $tile');
              print('CS3-WALK ${asciiJson(step)}');
              if (!events.any((e) => e['event'] == 'uiClosed' && e['session'] == session)) {
                await whilePumping(tester, host.closeUi(session, force: true));
                await pumpUntil(
                  tester,
                  () => events.any((e) => e['event'] == 'uiClosed' && e['session'] == session),
                  what: '$name closing',
                  timeout: const Duration(seconds: 10),
                );
              }
            }
          }
        } finally {
          await listening.cancel();
          await changes.undo(tester, container);
        }
        expect(unhidden, isEmpty, reason: 'a window showed unhidden');
      });
    },
    skip: skipReason != null,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
