/// The test extension's game on a device (Phase 7c part 1):
/// - Play opens it full screen, with no sheet. Its window asks for the whole screen and the screen kept on, and on the
///   JVM for landscape, which an iPhone follows.
/// - Back once leaves it up, with the game's own "Press back again" message (on the JVM in the page). Back again saves
///   and closes it, and the Play call ends with no links, saying a full-screen window showed.
/// - Its EXIT GAME button does the same (the JVM: the page is the app's own).
/// - Its page comes from the extension's own files (served by the app on the JVM). It reads the file beside it, asks
///   its interface and opens its dialogs. What it reports matches Android's own bridge, on all five, and a chrome
///   client takes its dialogs on the dialogs title.
/// - On the JVM a chrome client that leaves the page's dialogs to the app gets SkyStream's own dialog, which the person
///   answers; on Windows and Linux the page, a window of its own, steps aside while it shows.
/// - A game that swallows Back goes after two Backs and 3 s.
/// - Through the app's own screens the title page shows after, never "No streams found".
/// With `CS3_GAME_HOLD_S=340` the game is first held past the old 330 s end, and the call still waits.
///
/// ```
/// packages/cs3_engine/tool/build_test_extension.sh
/// python3 -m http.server 8765 --directory packages/cs3_engine/test_extension/build &
/// flutter test integration_test/cloudstream/extension_games_test.dart -d DEVICE \
///   --dart-define=CS3_E2E=true --dart-define=CS3_TEST_EXTENSION=http://10.0.2.2:8765/SkyStreamTest.cs3 \
///   [--dart-define=CS3_GAME_HOLD_S=340]
/// ```
// The printed lines are the test's report.
// ignore_for_file: avoid_print
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_engine.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_full_screen.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_sheet.dart';
import 'package:skystream/shared/widgets/custom_widgets.dart';
import 'package:skystream/shared/widgets/multimedia_card.dart';

import 'support.dart';
import 'test_extension.dart';

const _holdS = int.fromEnvironment('CS3_GAME_HOLD_S');
const _provider = 'SkyStream Test A';
const _ask = 'Press back again to save & exit';

/// What the game's page reports (Phase 7c part 2): the same on every platform, Android's own bridge included.
const _seen = <String, Object?>{
  'file': 1048576,
  'ready': true,
  'name': 'Test Game ü 🎮\u0000!',
  'level': 42,
  'half': 2.5,
  'big': 1048576,
  'broken': 'threw: Java exception was raised during method invocation',
  'nothing': 'undefined',
  // Calls made while the page has replaced JSON, Array.prototype.slice, Function.prototype.call and Error.
  'replaced': 42,
  'replacedThrow': 'threw: Java exception was raised during method invocation',
  'loaded': '{"level":3}',
  'alert': 'undefined',
  'confirm': false,
  'prompt': null,
};

/// The app's pages, noting each toast a full-screen page showed.
class _Pages extends ExtensionPages {
  final toasts = <String>[];

  @override
  Future<bool> toast(String text) async {
    final shown = await super.toast(text);
    if (shown) toasts.add(text);
    return shown;
  }
}

typedef _Played = ({Future<Map<String, dynamic>> call, Map<String, dynamic> window, int session});

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a game: full screen, Back saves and closes it, and the Play ends quietly',
    (tester) async {
      final appPages = ExtensionPages.shared;
      final pages = _Pages();
      ExtensionPages.shared = pages;
      addTearDown(() => ExtensionPages.shared = appPages);
      await withApp(tester, (container) async {
        final changes = await CloudStreamChanges.note(tester, container);
        final host = container.read(cloudStreamEngineHostProvider);
        final events = <Map<String, dynamic>>[];
        final listening = host.events.listen(events.add);
        final plugin = await installTestExtension(tester, container);
        final path = plugin.filePath;

        Future<String> state() async {
          final home = await whilePumping(
            tester,
            host.run(path, (e) => e.mainPage(_provider, page: 3, plugin: path), kind: 'mainPage'),
          );
          return ((((home['sections'] as List).single as Map)['items'] as List).single as Map)['name'] as String;
        }

        /// What the last game's page reported to the extension (Home's fourth page), once it has.
        Future<Map<String, dynamic>> seen() async {
          final until = DateTime.now().add(const Duration(minutes: 1));
          while (true) {
            final home = await whilePumping(
              tester,
              host.run(path, (e) => e.mainPage(_provider, page: 4, plugin: path), kind: 'mainPage'),
            );
            final name =
                ((((home['sections'] as List).single as Map)['items'] as List).single as Map)['name'] as String;
            if (name != 'Report: none') return jsonDecode(name.substring('Report: '.length)) as Map<String, dynamic>;
            if (DateTime.now().isAfter(until)) fail("the game's page didn't report in a minute");
            await pumpFor(tester, const Duration(milliseconds: 500));
          }
        }

        Future<void> back() async {
          await tester.binding.handlePopRoute();
          await pumpFor(tester, const Duration(milliseconds: 300));
        }

        /// Play on [url]'s title: the call, the game's window as the engine published it, and its screen.
        Future<_Played> play(String url) async {
          final title = await whilePumping(
            tester,
            host.run(path, (e) => e.load(_provider, url, plugin: path), kind: 'load'),
          );
          final from = events.length;
          final call = host.run(
            path,
            (e) => e.loadLinks(_provider, title['dataUrl'] as String, plugin: path),
            kind: 'loadLinks',
          );
          await pumpUntil(
            tester,
            () => find.byType(ExtensionFullScreen).evaluate().isNotEmpty,
            what: 'the game full screen',
          );
          final shown = events.skip(from).lastWhere((e) => e['event'] == 'ui');
          return (
            call: call,
            window: Map<String, dynamic>.from((shown['windows'] as List).last as Map),
            session: shown['session'] as int,
          );
        }

        ExtensionPage? pageOf(_Played game) =>
            ExtensionPages.shared.at(game.session, (game.window['root'] as Map)['id'] as int);

        /// [game]'s page once it has loaded: its scripts run as it loads, which a window not in front can take a while
        /// to do.
        Future<ExtensionPage> loaded(_Played game) async {
          await pumpUntil(tester, () => pageOf(game) != null, what: "the game's page");
          final page = pageOf(game)!;
          final until = DateTime.now().add(const Duration(minutes: 1));
          while (true) {
            String loaded;
            try {
              loaded = await whilePumping(tester, page.browser.evaluate("!!document.getElementById('exit')"));
            } on TimeoutException {
              // An engine can drop a script sent while its page changes (iOS, as the page starts to load).
              loaded = 'false';
            }
            if (loaded == 'true') return page;
            if (DateTime.now().isAfter(until)) {
              fail("the game's page didn't load in a minute");
            }
            await pumpFor(tester, const Duration(milliseconds: 500));
          }
        }

        // Until the run through the app's own screens, each game plays over the player's opaque page, as Play puts it
        // under a game: over Home, a game that turns the phone has Flutter lay Home out once at its old width in the
        // frame the view covers it, and report a header overflow nobody sees (debug only).
        final navigator = Navigator.of(tester.element(find.byType(Scaffold).first), rootNavigator: true);
        final under = PageRouteBuilder<void>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (_, _, _) => const ColoredBox(color: Colors.black),
        );
        unawaited(navigator.push(under));
        await pumpFor(tester, const Duration(milliseconds: 300));

        try {
          // Back once, then again.
          final game = await play('https://skystream.invalid/game/1');
          var ended = false;
          game.call.whenComplete(() => ended = true).ignore();
          expect(game.window['fullScreen'], isTrue);
          expect(game.window['keepScreenOn'], isTrue);
          if (!Platform.isAndroid) {
            expect(game.window['orientation'], 6, reason: "the JVM carries the game's landscape");
          }
          expect(find.byType(ExtensionSheet), findsNothing);
          // Its page, from the extension's own files: what it read, and its answers, as Android's bridge gives them.
          expect(await seen(), _seen);
          print('CS3-GAMES the page: its file, its answers and its dialogs, as on Android');
          final iPhone =
              Platform.isIOS && MediaQuery.sizeOf(tester.element(find.byType(ExtensionFullScreen))).shortestSide < 600;
          if (iPhone) {
            await pumpUntil(tester, () {
              final size = ui.PlatformDispatcher.instance.implicitView!.physicalSize;
              return size.width > size.height;
            }, what: 'the iPhone turned');
          }
          if (!Platform.isAndroid) {
            final page = await loaded(game);
            expect(
              await whilePumping(tester, page.browser.evaluate('location.protocol')),
              isNot('"file:"'),
              reason: 'served from the app',
            );
            expect(await whilePumping(tester, page.browser.evaluate('typeof window.__cs3Toast')), '"function"');
            final desktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
            expect(
              await whilePumping(tester, page.browser.evaluate('typeof window.__cs3Back')),
              desktop ? '"function"' : '"undefined"',
            );
          }
          if (_holdS > 0) {
            await pumpFor(tester, const Duration(seconds: _holdS));
            await pumpFor(tester, const Duration(seconds: 1));
            expect(ended, isFalse, reason: 'the Play call still waits after $_holdS s');
            print('CS3-GAMES held ${_holdS}s, the call still waiting');
          }
          await back();
          await pumpFor(tester, const Duration(seconds: 1));
          expect(find.byType(ExtensionFullScreen), findsOneWidget, reason: 'the first Back only asks');
          if (!Platform.isAndroid) expect(pages.toasts, [_ask], reason: "the game's own words, in its page");
          await back();
          final answer = await whilePumping(tester, game.call);
          expect(answer['links'], isEmpty);
          expect(answer['fullScreen'], isTrue);
          await pumpUntil(tester, () => find.byType(ExtensionFullScreen).evaluate().isEmpty, what: 'the game gone');
          expect(await state(), 'Game: saved by back');
          print('CS3-GAMES back twice: saved and closed');

          // Its own EXIT GAME button (the JVM: the page is the app's own).
          if (!Platform.isAndroid) {
            final exit = await play('https://skystream.invalid/game/1');
            final page = await loaded(exit);
            await whilePumping(tester, page.browser.evaluate("document.getElementById('exit').click()"));
            await whilePumping(tester, exit.call);
            expect(await state(), 'Game: saved by its exit');
            print('CS3-GAMES its EXIT GAME: saved and closed');
          }

          // A game that swallows Back: SkyStream's escape.
          final stuck = await play('https://skystream.invalid/game/stuck');
          await back();
          await pumpFor(tester, const Duration(milliseconds: 700));
          await back();
          await pumpFor(tester, const Duration(seconds: 4));
          await whilePumping(tester, stuck.call);
          expect(await state(), 'Game: closed');
          print('CS3-GAMES a game that swallows Back: closed after two Backs and 3 s');

          // A game whose chrome client takes its page's dialogs: the prompt answered later, with what it heard.
          final withDialogs = await play('https://skystream.invalid/game/dialogs');
          expect(await seen(), {..._seen, 'confirm': true, 'prompt': 'heard: Game ready'});
          await back();
          await pumpFor(tester, const Duration(seconds: 1));
          await back();
          await whilePumping(tester, withDialogs.call);
          expect(await state(), 'Game: saved by back');
          print('CS3-GAMES its chrome client: the dialogs answered as on Android');

          // A game whose chrome client leaves the page's dialogs to the app: SkyStream's own dialog, which the person
          // answers (Android's WebView shows its own then). Its page waits in each dialog, so nothing here waits on a
          // script in it.
          if (!Platform.isAndroid) {
            final left = await play('https://skystream.invalid/game/appdialogs');
            await pumpUntil(tester, () => pageOf(left) != null, what: "the game's page");
            final shown = find.byKey(ValueKey('extension-page-${pageOf(left)!.rid}'));
            final nativeWindow = Platform.isWindows || Platform.isLinux;
            Future<void> answer(String message, String button, {String? field, String? text}) async {
              final dialog = find.ancestor(of: find.text(message), matching: find.byType(AlertDialog));
              await pumpUntil(tester, () => dialog.evaluate().isNotEmpty, what: "SkyStream's dialog: $message");
              // A page that is a window of its own would cover it.
              if (nativeWindow) expect(shown, findsNothing, reason: 'the page steps aside');
              final input = find.descendant(of: dialog, matching: find.byType(TextField));
              if (field != null) expect(find.descendant(of: input, matching: find.text(field)), findsOneWidget);
              if (text != null) await tester.enterText(input, text);
              await tester.tap(find.descendant(of: dialog, matching: find.text(button)));
              await pumpUntil(tester, () => dialog.evaluate().isEmpty, what: 'the dialog gone: $message');
            }

            await answer('Game ready', 'OK');
            await answer('Keep playing?', 'Cancel');
            await answer('Your name?', 'OK', field: 'Player', text: 'Tester');
            expect(await seen(), {..._seen, 'confirm': false, 'prompt': 'Tester'});
            await pumpUntil(tester, () => shown.evaluate().isNotEmpty, what: 'the page back');
            await back();
            await pumpFor(tester, const Duration(seconds: 1));
            await back();
            await whilePumping(tester, left.call);
            expect(await state(), 'Game: saved by back');
            print("CS3-GAMES SkyStream's own dialog: the page's dialogs answered by the person");
          }

          // Through the app's own screens: Search, the title, Play, Back twice, and the title page again.
          navigator.removeRoute(under);
          await pumpFor(tester, const Duration(milliseconds: 300));
          go(tester, '/search');
          await waitFor(tester, find.byType(TextField));
          await typeInto(tester, find.byType(TextField).first, 'game');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await pumpFor(tester, const Duration(seconds: 1));
          if (find.textContaining('Press the Search key').evaluate().isNotEmpty) {
            tester.widget<TextField>(find.byType(TextField).first).onSubmitted?.call('game');
          }
          final card = find.ancestor(of: find.text('Test Game'), matching: find.byType(MultimediaCard));
          await waitFor(tester, card);
          await tester.tap(card.first);
          final playLabel = find.byWidgetPredicate(
            (w) => w is Text && RegExp(r'^(Play|Resume)( S\d+)?( E\d+)?$').hasMatch(w.data ?? ''),
          );
          final playButton = find.ancestor(of: playLabel, matching: find.byType(CustomButton));
          await pumpUntil(
            tester,
            () => playButton.evaluate().isNotEmpty && tester.widget<CustomButton>(playButton.first).onPressed != null,
            what: 'Play',
          );
          // A small phone's title page has Play below the fold.
          await reveal(tester, playButton);
          await tester.tap(playButton.first);
          await pumpUntil(
            tester,
            () => find.byType(ExtensionFullScreen).evaluate().isNotEmpty,
            what: 'the game full screen',
          );
          await back();
          await pumpFor(tester, const Duration(seconds: 1));
          await back();
          await pumpUntil(tester, () => find.byType(ExtensionFullScreen).evaluate().isEmpty, what: 'the game gone');
          await pumpUntil(tester, () => playButton.evaluate().isNotEmpty, what: 'the title page again');
          await pumpFor(tester, const Duration(seconds: 3));
          expect(find.text('No streams found.'), findsNothing);
          expect(playButton, findsWidgets);
          print('CS3-GAMES through the screens: the title page again, no error');
        } finally {
          await listening.cancel();
          await tester.runAsync(() => container.read(cloudStreamRepositoryProvider.notifier).uninstall(plugin));
          await changes.undo(tester, container);
        }
      });
    },
    skip: skipReason != null || testExtensionUrl.isEmpty,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
