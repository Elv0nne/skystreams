/// Real extensions' pages in their own screens (the spec's §9; the part 5 research found 8 sign-in pages and 12
/// manual Cloudflare pages behind a tap): each is installed, its screen opened in SkyStream's sheet, the tap path to
/// its page followed, and the page shown, then kept on screen for 8 s (the device run takes a screenshot on the
/// `CS3-REAL-PAGE … shown` line). On the JVM its page must have loaded (a title, or a URL); on Android its own WebView
/// is lent to the sheet, and must stay put (the same platform view throughout: no flicker). One `CS3-REAL-PAGE` line
/// each, then `CS3-REAL-PAGES-END`.
///
/// ```
/// flutter test integration_test/cloudstream/real_pages_test.dart -d DEVICE --dart-define=CS3_E2E=true \
///   [--dart-define=REAL_ONLY=Cinemacity] --dart-define-from-file=DEFINES
/// ```
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_page_view.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_sheet.dart';

import 'support.dart';

const _only = String.fromEnvironment('REAL_ONLY');

const _phisher =
    'https://raw.githubusercontent.com/phisher98/cloudstream-extensions-phisher/refs/heads/builds/repo.json';
const _raghav = 'https://raw.githubusercontent.com/KSHITIJ8473/raghav/builds/repo.json';

/// (repository, internal name, the words of each tile to tap, in order, matched at their start), from the part 5
/// research's page hunt (2026-10-07).
const _real = <(String, String, List<String>)>[
  (_phisher, 'Cinemacity', ['CinemaCity Account', '🔐 Login to CinemaCity']),
  (_phisher, 'Kartoons', ['Kartoons Account', '🔐 Login to Kartoons']),
  (_phisher, 'StreamPlay', ['Febbox Login', 'Login with Google']),
  (_phisher, 'Aniworld', ['Login / Cloudflare Captcha']),
  (_raghav, 'AnimeWorldIndia', ['Bypass Cloudflare']),
];

Iterable<UiNode> _all(UiNode n) sync* {
  yield n;
  for (final child in n.children) {
    yield* _all(child);
  }
}

/// A tile's words: its own and its children's, as the sheet shows them.
String _label(UiNode n) => _all(n).map((c) => c.words?.trim()).nonNulls.where((t) => t.isNotEmpty).join(' | ');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'real pages show in the sheet',
    (tester) async {
      await withApp(tester, (container) async {
        final host = container.read(cloudStreamEngineHostProvider);
        final changes = await CloudStreamChanges.note(tester, container);
        final events = <Map<String, dynamic>>[];
        final listening = host.events.listen(events.add);
        final wanted = _only.isEmpty ? null : _only.split(',').map((s) => s.trim()).toSet();
        var shown = 0;
        try {
          for (final (repository, name, taps) in _real) {
            if (wanted != null && !wanted.contains(name)) continue;
            final report = <String, Object?>{'extension': name};
            try {
              await ensureInstalled(tester, container, repository: repository, internalName: name);
              go(tester, '/settings/cloudstream');
              final settings = find.byKey(ValueKey('cs3_settings_$name'));
              await waitFor(tester, settings, timeout: const Duration(minutes: 3));
              final opened = events.length;
              await tester.tap(settings);
              await pumpUntil(
                tester,
                () => events.skip(opened).any((e) => e['event'] == 'ui'),
                what: '$name showing its screen',
                timeout: const Duration(seconds: 30),
              );
              final session = events.skip(opened).firstWhere((e) => e['event'] == 'ui')['session'] as int;
              List<UiWindow> windows() => [
                for (final w
                    in events.lastWhere((e) => e['event'] == 'ui' && e['session'] == session)['windows'] as List)
                  UiWindow.fromJson(Map<String, dynamic>.from(w as Map)),
              ];
              for (final words in taps) {
                await pumpUntil(
                  tester,
                  () => _all(windows().last.root).any((n) => n.tappable && _label(n).startsWith(words)),
                  what: '$name: "$words"',
                  timeout: const Duration(seconds: 20),
                );
                final tile = _all(windows().last.root).firstWhere((n) => n.tappable && _label(n).startsWith(words));
                await whilePumping(tester, host.uiAction(session, tile.id, 'click'));
                await pumpFor(tester, const Duration(seconds: 2));
              }
              UiNode? page() =>
                  windows().isEmpty ? null : _all(windows().last.root).where((n) => n.kind == UiKind.page).firstOrNull;
              await pumpUntil(
                tester,
                () => page() != null,
                what: '$name: its page',
                timeout: const Duration(seconds: 20),
              );
              await waitFor(tester, find.byType(ExtensionPageView), timeout: const Duration(seconds: 20));
              final node = page()!;
              if (Platform.isAndroid) {
                final view = tester.element(find.byType(PlatformViewLink));
                print('CS3-REAL-PAGE $name shown');
                await pumpFor(tester, const Duration(seconds: 8));
                report['steady'] = identical(tester.element(find.byType(PlatformViewLink)), view);
              } else {
                await pumpUntil(
                  tester,
                  () => ExtensionPages.shared.at(session, node.id) != null,
                  what: '$name: its page opened',
                  timeout: const Duration(seconds: 20),
                );
                print('CS3-REAL-PAGE $name shown');
                await pumpFor(tester, const Duration(seconds: 8));
                final browser = ExtensionPages.shared.at(session, node.id)?.browser;
                report['title'] = browser == null
                    ? null
                    : await tester.runAsync(() => browser.evaluate('document.title'));
                report['url'] = browser == null ? null : await tester.runAsync(() => browser.evaluate('location.href'));
              }
              report['shown'] = true;
              shown++;
            } catch (e) {
              report['error'] = '$e';
            } finally {
              // Force close, from the sheet's More menu, as extension_settings_test.dart does. An extension can show
              // a window again as its last one goes (Cinemacity's settings, as its login closes): the person force
              // closes again.
              var closes = 0;
              while (find.byType(ExtensionSheet).evaluate().isNotEmpty && closes < 3) {
                closes++;
                await tester.tap(find.byTooltip('More').first);
                await tester.pump(const Duration(milliseconds: 500));
                await tester.tap(find.text('Force close'));
                await pumpFor(tester, const Duration(seconds: 3));
              }
              report['closes'] = closes;
              report['stuck'] = find.byType(ExtensionSheet).evaluate().isNotEmpty;
              print('CS3-REAL-PAGE ${asciiJson(report)}');
            }
          }
          print('CS3-REAL-PAGES-END ${asciiJson({'platform': Platform.operatingSystem, 'shown': shown})}');
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
