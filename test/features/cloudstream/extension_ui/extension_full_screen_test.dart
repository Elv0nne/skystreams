/// The full-screen view (Phase 7c's §2): a window that asks for the whole screen fills it, with no header; each
/// platform's way out sends Back to the top window; two Backs to the same window and 3 s close one that stays; the
/// device's bars, wakelock and an iPhone's orientation go as it opens and come back as it goes.
library;

import 'dart:async';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_ui_session.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_full_screen.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_page_view.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../core/cloudstream/extension_ui/fake_page_browser.dart';

class _Api implements ExtensionUiApi {
  final sent = <String>[];

  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  Future<int> openSettings(String plugin) async => 1;

  @override
  Future<int> openPopups(String plugin) async => 1;

  @override
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) async {
    sent.add('$node $action $value');
    return {'done': true};
  }

  @override
  Future<void> closeUi(int session, {bool force = false}) async => sent.add('closeUi $force');
}

class _Device implements FullScreenDevice {
  final calls = <String>[];

  /// Set to hold an enter on its way (the platform's calls take a while): 'entered' once it completes.
  Completer<void>? holdEnter;

  @override
  Future<void> enter({required bool keepScreenOn, List<DeviceOrientation>? orientations}) async {
    calls.add('enter $keepScreenOn ${orientations?.map((o) => o.name).join(',')}');
    final hold = holdEnter;
    if (hold != null) {
      await hold.future;
      calls.add('entered');
    }
  }

  @override
  Future<void> leave() async => calls.add('leave');
}

/// A game's window: a page (node [root]) that fills it, or (with [page] false) a reader's words.
Map<String, Object?> _game({
  String id = 'w1',
  int root = 1,
  bool page = true,
  int? orientation,
  bool keepScreenOn = false,
}) => {
  'id': id,
  'kind': 'dialog',
  'fullScreen': true,
  'keepScreenOn': keepScreenOn,
  'orientation': ?orientation,
  'root': page
      ? {'id': root, 'kind': 'page'}
      : {
          'id': root,
          'kind': 'column',
          'children': [
            {'id': root + 1, 'kind': 'text', 'text': 'Chapter 1'},
          ],
        },
};

Map<String, Object?> _dialog(String id, String text, {int root = 50}) => {
  'id': id,
  'kind': 'alert',
  'root': {'id': root, 'kind': 'text', 'text': text},
};

Map<String, Object?> _ui(List<Map<String, Object?>> windows) => {'event': 'ui', 'session': 1, 'windows': windows};

void main() {
  late _Api api;
  late _Device device;
  late FakePageBrowser browser;
  final appPages = ExtensionPages.shared;

  setUp(() {
    api = _Api();
    device = _Device();
    browser = FakePageBrowser();
    ExtensionPages.shared = ExtensionPages(create: () async => browser, desktop: true);
  });

  tearDown(() => ExtensionPages.shared = appPages);

  /// Opens the view over a home screen for a screen with [windows]; their pages open first, as the engine opens them.
  Future<ExtensionUiSession> show(
    WidgetTester tester,
    List<Map<String, Object?>> windows, {
    bool iPhone = false,
    bool desktop = false,
    bool ios = false,
    bool pageFullScreen = true,
  }) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final window in windows) {
      final root = window['root']! as Map<String, Object?>;
      if (root['kind'] == 'page') {
        await ExtensionPages.shared.open({
          'rid': 9,
          'session': 1,
          'node': root['id'],
          'url': 'https://game.test/',
          'fullScreen': pageFullScreen,
        }, PageReports().call);
      }
    }
    final session = ExtensionUiSession.test(api, windows: [for (final window in windows) UiWindow.fromJson(window)]);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(
                Navigator.of(context).push(
                  PageRouteBuilder<void>(
                    pageBuilder: (_, _, _) => ExtensionFullScreen(
                      session: session,
                      title: 'Game',
                      device: device,
                      iPhone: iPhone,
                      desktop: desktop,
                      ios: ios,
                      android: false,
                    ),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return session;
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
  }

  testWidgets('a window that asks for the whole screen fills it, with no header, its page taking the keys', (
    tester,
  ) async {
    await show(tester, [_game()]);
    final page = tester.widget<ExtensionPageView>(find.byType(ExtensionPageView));
    expect((page.fill, page.autofocus), (true, true));
    expect(tester.getSize(find.byType(ExtensionPageView)), const Size(800, 400));
    expect(find.text('Game'), findsNothing);
  });

  testWidgets('Back goes to the top window, and the view leaves once the screen has', (tester) async {
    final session = await show(tester, [_game()]);
    await back(tester);
    expect(api.sent, ['1 close null']);
    session.receive({'event': 'uiClosed', 'session': 1, 'reason': 'closed'});
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsNothing);
    expect(device.calls, ['enter false null', 'leave']);
  });

  testWidgets('once no window asks for the whole screen the view leaves, the screen going on', (tester) async {
    final session = await show(tester, [_game()]);
    session.receive(_ui([_dialog('w2', 'Saved!')]));
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsNothing);
    expect(device.calls.last, 'leave');
  });

  testWidgets('two Backs to the same window, and one still there 3 s after the second is closed by force', (
    tester,
  ) async {
    await show(tester, [_game()]);
    await back(tester);
    await tester.pump(const Duration(seconds: 1));
    await back(tester);
    await tester.pump(const Duration(milliseconds: 2900));
    expect(api.sent, ['1 close null', '1 close null'], reason: 'not yet');
    await tester.pump(const Duration(milliseconds: 200));
    expect(api.sent.last, '1 close force', reason: 'that window alone, not the screen');
  });

  testWidgets('Backs further apart than 3 s are a game asking again, not a window that stays', (tester) async {
    await show(tester, [_game()]);
    await back(tester);
    await tester.pump(const Duration(seconds: 4));
    await back(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(api.sent, ['1 close null', '1 close null']);
  });

  testWidgets("a Back that closed a dialog over the game isn't the game's first", (tester) async {
    final session = await show(tester, [_game(), _dialog('w2', 'Quit?')]);
    await back(tester);
    session.receive(_ui([_game()]));
    await tester.pump();
    await back(tester);
    await tester.pump(const Duration(seconds: 4));
    expect(api.sent, ['50 close null', '1 close null']);
  });

  testWidgets('an iPhone holds the orientation the extension asked for, with the screen kept on', (tester) async {
    await show(tester, [_game(orientation: 6, keepScreenOn: true)], iPhone: true);
    expect(device.calls, ['enter true landscapeLeft,landscapeRight']);
  });

  testWidgets('on an iPhone an orientation asked for later is followed', (tester) async {
    final session = await show(tester, [_game()], iPhone: true);
    session.receive(_ui([_game(orientation: 1)]));
    await tester.pump();
    expect(device.calls, ['enter false null', 'enter false portraitUp']);
  });

  testWidgets('anywhere but an iPhone, nothing is turned', (tester) async {
    await show(tester, [_game(orientation: 6)]);
    expect(device.calls, ['enter false null']);
  });

  testWidgets('on iPhone and iPad a swipe in from the left edge is Back; the page never gets the strip', (
    tester,
  ) async {
    await show(tester, [_game()], ios: true);
    expect(tester.getTopLeft(find.byType(ExtensionPageView)).dx, ExtensionFullScreen.edgeStrip);
    await tester.dragFrom(const Offset(4, 200), const Offset(120, 0));
    await tester.pump();
    expect(api.sent, ['1 close null']);
  });

  testWidgets("on a desktop a window that isn't a page gets a × while the mouse moves, gone 2 s after", (tester) async {
    await show(tester, [_game(page: false)], desktop: true);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 200));
    await mouse.moveTo(const Offset(410, 210));
    await tester.pump();
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(api.sent, ['1 close null']);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    await mouse.removePointer();
  });

  testWidgets("on a desktop a page's own × is Back for its screen, and SkyStream draws none over it", (tester) async {
    await show(tester, [_game()], desktop: true);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 200));
    await mouse.moveTo(const Offset(410, 210));
    await tester.pump();
    expect(find.byIcon(Icons.close_rounded), findsNothing, reason: 'the page has its own');
    await mouse.removePointer();
    browser.controller.add(const ScriptMessage('{"cs3-back":1}'));
    await tester.pump();
    await tester.pump();
    expect(api.sent, ['1 close null']);
  });

  testWidgets("on a desktop a window on top of a page gets SkyStream's ×: the page's own stepped aside with it", (
    tester,
  ) async {
    // Desktops send no Back but a ×: without one here, a dialog with no button of its own was a dead end.
    final session = await show(tester, [_game()], desktop: true);
    session.receive(_ui([_game(), _dialog('w2', 'Quit?')]));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(400, 200));
    await mouse.moveTo(const Offset(410, 210));
    await tester.pump();
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(api.sent, ['50 close null'], reason: 'Back to the window on top');
    await mouse.removePointer();
  });

  testWidgets("a page that opened before its window asked for the whole screen gets a full-screen page's script", (
    tester,
  ) async {
    // On a desktop its own × is the way out of a page: SkyStream draws none over it.
    await show(tester, [_game()], desktop: true, pageFullScreen: false);
    expect(browser.scripts, contains(fullScreenScript('POST', closeButton: true)));
  });

  testWidgets('a window on top shows over the page, which steps aside until it goes', (tester) async {
    // Review Focus 2: on Windows and Linux the page is a native window over everything.
    final session = await show(tester, [_game()]);
    session.receive(_ui([_game(), _dialog('w2', 'Quit?')]));
    await tester.pump();
    expect(find.text('Quit?'), findsOneWidget);
    expect(find.byKey(const ValueKey('extension-page-placeholder')), findsOneWidget);
    session.receive(_ui([_game()]));
    await tester.pump();
    expect(find.text('Quit?'), findsNothing);
    expect(find.byKey(const ValueKey('extension-page-placeholder')), findsNothing);
  });

  testWidgets('back from the background, the view asks the device again', (tester) async {
    // Review Focus 3: the system bars, the wakelock and an iPhone's orientation.
    await show(tester, [_game(orientation: 6)], iPhone: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(device.calls, ['enter false landscapeLeft,landscapeRight', 'enter false landscapeLeft,landscapeRight']);
  });

  testWidgets('back from the background as the view goes, it still gives the device back', (tester) async {
    // Part 1's review: a resume as the view left asked again for a window that was gone, forgot what it had asked,
    // and gave nothing back: the system bars stayed hidden, the wakelock on, an iPhone pinned.
    final session = await show(tester, [_game()]);
    session.receive({'event': 'uiClosed', 'session': 1, 'reason': 'closed'});
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsNothing);
    expect(device.calls, ['enter false null', 'leave']);
  });

  testWidgets("back from the background in the engine's end grace, it still gives the device back", (tester) async {
    // The second review: the last window gone, the engine waits 300 ms before it ends the screen; a resume then asked
    // again for no window, forgot what it had asked, and the view went without giving anything back.
    final session = await show(tester, [_game(orientation: 6, keepScreenOn: true)], iPhone: true);
    session.receive(_ui([]));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    session.receive({'event': 'uiClosed', 'session': 1, 'reason': 'closed'});
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsNothing);
    expect(device.calls, ['enter true landscapeLeft,landscapeRight', 'leave']);
  });

  testWidgets("back from the background in the end grace, then a plain window: the device is given back", (
    tester,
  ) async {
    final session = await show(tester, [_game(orientation: 6, keepScreenOn: true)], iPhone: true);
    session.receive(_ui([]));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    session.receive(_ui([_dialog('w2', 'Saved!')]));
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsNothing);
    expect(device.calls, ['enter true landscapeLeft,landscapeRight', 'leave']);
  });

  testWidgets('a leave asked while an enter is on its way comes after it, so the enter undoes nothing', (tester) async {
    // Part 1's review: the enter's later steps (the bars hidden, the wakelock on) landed after the leave.
    device.holdEnter = Completer<void>();
    final session = await show(tester, [_game()]);
    session.receive({'event': 'uiClosed', 'session': 1, 'reason': 'closed'});
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsNothing);
    device.holdEnter!.complete();
    await tester.pump();
    expect(device.calls, ['enter false null', 'entered', 'leave']);
  });

  testWidgets('asked twice for one screen, one view shows, and both askers hear it go', (tester) async {
    final session = ExtensionUiSession.test(api, windows: [UiWindow.fromJson(_game(page: false))]);
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Text('Home')),
      ),
    );
    final context = tester.element(find.text('Home'));
    var gone = 0;
    unawaited(showExtensionFullScreen(context, session: session, title: 'Game', device: device).then((_) => gone++));
    unawaited(showExtensionFullScreen(context, session: session, title: 'Game', device: device).then((_) => gone++));
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsOneWidget);
    session.receive({'event': 'uiClosed', 'session': 1, 'reason': 'closed'});
    await tester.pumpAndSettle();
    expect(gone, 2);
  });

  test("Android's orientations map to an iPhone's", () {
    expect(orientationsFor(6), [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    expect(orientationsFor(11), [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    expect(orientationsFor(1), [DeviceOrientation.portraitUp]);
    expect(orientationsFor(-1), isNull);
    expect(orientationsFor(4), isNull);
    expect(orientationsFor(null), isNull);
  });

  test('the view shows from the last window that asks for the whole screen', () {
    final windows = [
      _dialog('w0', 'Settings'),
      _game(id: 'w1'),
      _dialog('w2', 'Quit?'),
    ].map(UiWindow.fromJson).toList();
    expect(fullScreenIndex(windows), 1);
    expect(fullScreenIndex([UiWindow.fromJson(_dialog('w0', 'Settings'))]), isNull);
    expect(fullScreenIndex(const []), isNull);
  });
}
