import 'dart:async';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:challenge_browser/src/messages.g.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_host.dart';

/// The sheet with keys and a D-pad. A desktop target shows the page without a platform view; the
/// fake host plays the page, reporting where focus leaves it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeHost host;

  setUp(() => host = FakeHost());

  const strings = ChallengeSheetStrings(
    note: 'Tick the box to continue.',
    retry: 'Retry',
    fullScreen: 'Full screen',
    exitFullScreen: 'Exit full screen',
    close: 'Close',
    done: 'Done',
    verified: 'Verified',
  );
  final desktop = TargetPlatformVariant.only(TargetPlatform.linux);

  /// Opens a sheet for [browser] on a [size] screen; completes with its result once it closes.
  Future<Future<ChallengeSheetResult>> open(
    WidgetTester tester,
    ChallengeBrowser browser, {
    Size size = const Size(1280, 800),
    bool tv = false,
    Future<void>? cleared,
    ChallengeSheetStrings strings = strings,
    Locale? locale,
    bool inTab = false,
    double systemBar = 0,
    double keyboard = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = FakeViewPadding(bottom: systemBar);
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    late Future<ChallengeSheetResult> result;
    Widget button(BuildContext context) => Center(
      child: ElevatedButton(
        onPressed: () =>
            result = showChallengeSheet(context, browser: browser, strings: strings, tv: tv, cleared: cleared),
        child: const Text('Open'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: [const Locale('en'), ?locale],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        // As in the app: a tab's own navigator, under the app's bottom bar.
        home: inTab
            ? Scaffold(
                extendBody: true,
                body: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: button)),
                bottomNavigationBar: const ColoredBox(
                  key: Key('bottom bar'),
                  color: Color(0xFF2196F3),
                  child: SizedBox(height: 64, width: double.infinity),
                ),
              )
            : Builder(builder: (context) => Scaffold(body: button(context))),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return result;
  }

  Future<void> leave(WidgetTester tester, ChallengeBrowser browser, FocusDirection direction) async {
    await host.emit(browser.id, PageEvent(kind: PageEventKind.focusExit, direction: direction));
    await tester.pump();
  }

  Future<String> press(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    return _focused();
  }

  /// The app's strings: five buttons, and help under the note.
  const appStrings = ChallengeSheetStrings(
    note: '127.0.0.1 checks that you are a person. Finish the check below; SkyStream remembers it for a while.',
    retry: 'Retry',
    fullScreen: 'Full screen',
    exitFullScreen: 'Exit full screen',
    close: 'Close',
    done: 'Done',
    verified: 'Verified',
    quiet: "Don't open this automatically",
    help: 'Keeping Android System WebView updated helps.',
  );

  /// Opens the sheet's menu of other buttons (Material's "Show menu"), and returns what it offers.
  Future<List<String>> more(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Show menu'));
    await tester.pumpAndSettle();
    return [
      for (final item in tester.widgetList<PopupMenuItem<VoidCallback>>(find.byType(PopupMenuItem<VoidCallback>)))
        ((item.child! as ListTile).title! as Text).data!,
    ];
  }

  testWidgets('desktop: a dialog where Tab goes through the page and every button, and Escape closes it', (
    tester,
  ) async {
    final browser = await ChallengeBrowser.create();
    final result = await open(tester, browser);
    expect(tester.getSize(_card), const Size(480, 560));
    expect(_focused(), 'page', reason: 'the keyboard starts in the page');
    expect(host.callsOf('focus').last, [browser.id, true]);

    // Tab inside the page is the page's; it reports leaving at its last control.
    await leave(tester, browser, FocusDirection.forward);
    final order = [_focused()];
    for (var i = 0; i < 3; i++) {
      order.add(await press(tester, LogicalKeyboardKey.tab));
    }
    expect(order, ['Show menu', 'Close', 'Done', 'page']);
    expect(host.callsOf('focus').last, [browser.id, true], reason: 'entered at its first control');

    await leave(tester, browser, FocusDirection.backward);
    expect(_focused(), 'Done');
    expect(await press(tester, LogicalKeyboardKey.tab, shift: true), 'Close');
    expect(await press(tester, LogicalKeyboardKey.tab, shift: true), 'Show menu');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, ChallengeSheetResult.closed);
  }, variant: desktop);

  testWidgets('Shift+Tab into the page enters it at its last control', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser);
    await leave(tester, browser, FocusDirection.forward);
    expect(_focused(), 'Show menu');
    expect(await press(tester, LogicalKeyboardKey.tab, shift: true), 'page');
    expect(host.callsOf('focus').last, [browser.id, false]);
  }, variant: desktop);

  testWidgets("help shows under the note, and \"don't open this automatically\" closes it so", (tester) async {
    final browser = await ChallengeBrowser.create();
    final result = await open(
      tester,
      browser,
      strings: const ChallengeSheetStrings(
        note: 'Tick the box to continue.',
        retry: 'Retry',
        fullScreen: 'Full screen',
        exitFullScreen: 'Exit full screen',
        close: 'Close',
        done: 'Done',
        verified: 'Verified',
        quiet: "Don't open this automatically",
        help: 'Keeping your browser updated helps.',
      ),
    );
    expect(find.text('Keeping your browser updated helps.'), findsOneWidget);
    await more(tester);
    await tester.tap(find.text("Don't open this automatically"));
    await tester.pumpAndSettle();
    expect(await result, ChallengeSheetResult.quiet);
  }, variant: desktop);

  testWidgets('a small phone (360×640) keeps room for the page: Close and Done in sight, the rest under More', (
    tester,
  ) async {
    final browser = await ChallengeBrowser.create();
    final result = await open(tester, browser, size: const Size(360, 640), strings: appStrings);
    expect(
      tester.getSize(find.byType(ChallengeBrowserView)).height,
      greaterThanOrEqualTo(180),
      reason: 'the check needs room to be seen and ticked',
    );
    expect(find.text('Close').hitTestable(), findsOneWidget);
    expect(find.text('Done').hitTestable(), findsOneWidget);
    expect(await more(tester), ['Retry', 'Full screen', "Don't open this automatically"]);
    await tester.tap(find.text("Don't open this automatically"));
    await tester.pumpAndSettle();
    expect(await result, ChallengeSheetResult.quiet);
  }, variant: desktop);

  testWidgets('the sheet reads English and runs left to right in an app set to Arabic', (tester) async {
    final browser = await ChallengeBrowser.create();
    final result = await open(
      tester,
      browser,
      size: const Size(360, 640),
      strings: appStrings,
      locale: const Locale('ar'),
    );
    expect(Directionality.of(tester.element(find.text('Close'))), TextDirection.ltr);
    expect(find.byTooltip('Show menu'), findsOneWidget, reason: "Material's own words, too");
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(await result, ChallengeSheetResult.closed);
  }, variant: desktop);

  testWidgets('the dialog keeps room for the page, its other buttons under More', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser, strings: appStrings);
    expect(tester.getSize(find.byType(ChallengeBrowserView)).height, greaterThanOrEqualTo(300));
    expect(find.text('Close').hitTestable(), findsOneWidget);
    expect(find.text('Done').hitTestable(), findsOneWidget);
    expect(await more(tester), ['Retry', 'Full screen', "Don't open this automatically"]);
  }, variant: desktop);

  testWidgets('full screen has room for every button in one line', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser, strings: appStrings);
    await more(tester);
    await tester.tap(find.text('Full screen'));
    await tester.pumpAndSettle();
    for (final label in ['Retry', 'Exit full screen', "Don't open this automatically", 'Close', 'Done']) {
      expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
    }
    expect(find.byTooltip('Show menu'), findsNothing);
  }, variant: desktop);

  testWidgets('phone: a bottom sheet that leaves focus alone, which Done closes', (tester) async {
    final browser = await ChallengeBrowser.create();
    final result = await open(tester, browser, size: const Size(400, 800));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(host.callsOf('focus'), isEmpty);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(await result, ChallengeSheetResult.done);
  }, variant: desktop);

  // A bottom sheet takes a vertical drag for itself: the page under the finger never scrolled, and a drag
  // down took the whole sheet away.
  testWidgets('phone: a drag on the page is the page\'s, and never moves the sheet', (tester) async {
    final browser = await ChallengeBrowser.create();
    var closed = false;
    unawaited((await open(tester, browser, size: const Size(400, 800))).then((_) => closed = true));
    await tester.drag(find.byType(ChallengeBrowserView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(closed, isFalse);
  }, variant: desktop);

  testWidgets('phone: the page claims its own drags, ahead of anything around it', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser, size: const Size(400, 800));
    final view = tester.widget<ChallengeBrowserView>(find.byType(ChallengeBrowserView));
    final made = [for (final factory in view.gestureRecognizers) factory.constructor()];
    addTearDown(() {
      for (final recognizer in made) {
        recognizer.dispose();
      }
    });
    expect(made, contains(isA<EagerGestureRecognizer>()));
  }, variant: desktop);

  testWidgets('phone: the handle still pulls the sheet down', (tester) async {
    final browser = await ChallengeBrowser.create();
    final result = await open(tester, browser, size: const Size(400, 800));
    final sheet = tester.getRect(find.byType(BottomSheet));
    await tester.dragFrom(Offset(sheet.center.dx, sheet.top + 12), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(await result, ChallengeSheetResult.closed);
  }, variant: desktop);

  testWidgets('phone: opened from a tab, the sheet is over the app\'s bottom bar', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser, size: const Size(400, 800), inTab: true);
    expect(find.byKey(const Key('bottom bar')), findsOneWidget);
    expect(find.byKey(const Key('bottom bar')).hitTestable(), findsNothing, reason: 'under the sheet and its barrier');
  }, variant: desktop);

  testWidgets('phone: Close and Done clear the system\'s navigation bar', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser, size: const Size(400, 800), systemBar: 48);
    for (final label in ['Close', 'Done']) {
      expect(tester.getRect(find.text(label)).bottom, lessThanOrEqualTo(800 - 48), reason: label);
    }
  }, variant: desktop);

  testWidgets('phone: the page and its buttons stay above the keyboard', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser, size: const Size(400, 800), keyboard: 300);
    for (final label in ['Close', 'Done']) {
      expect(tester.getRect(find.text(label)).bottom, lessThanOrEqualTo(800 - 300), reason: label);
    }
    expect(tester.getRect(find.byType(ChallengeBrowserView)).bottom, lessThanOrEqualTo(800 - 300));
    expect(tester.takeException(), isNull);
  }, variant: desktop);

  testWidgets('TV: the whole screen, the D-pad goes up from the page to the buttons and back, Back closes', (
    tester,
  ) async {
    final browser = await ChallengeBrowser.create();
    final result = await open(tester, browser, size: const Size(960, 540), tv: true);
    expect(tester.getSize(_card), const Size(960, 540));
    expect(find.text('Full screen'), findsNothing);
    expect(_focused(), 'page', reason: 'the D-pad starts in the page');

    // The buttons sit above the page: up leaves a challenge's frame in a press or two.
    await leave(tester, browser, FocusDirection.up);
    expect(['Retry', 'Close', 'Done'], contains(_focused()));
    final across = [_focused()];
    for (var i = 0; i < 2; i++) {
      across.add(await press(tester, LogicalKeyboardKey.arrowRight));
    }
    for (var i = 0; i < 2; i++) {
      across.add(await press(tester, LogicalKeyboardKey.arrowLeft));
    }
    expect(across, ['Retry', 'Close', 'Done', 'Close', 'Retry']);
    expect(await press(tester, LogicalKeyboardKey.arrowDown), 'page');
    expect(host.callsOf('focus').last, [browser.id, true]);

    // Back.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(await result, ChallengeSheetResult.closed);
  }, variant: desktop);

  testWidgets('a cleared check shows Verified, then closes by itself', (tester) async {
    final browser = await ChallengeBrowser.create();
    final cleared = Completer<void>();
    final result = await open(tester, browser, cleared: cleared.future);
    expect(find.text('Verified'), findsNothing);
    cleared.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text(strings.note), findsNothing);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(Dialog), findsNothing);
    expect(await result, ChallengeSheetResult.verified);
  }, variant: desktop);

  testWidgets('without Done, a sign-in sheet offers only Close, and its redirect closes it', (tester) async {
    final redirected = Completer<void>();
    final result = await open(
      tester,
      await ChallengeBrowser.create(),
      cleared: redirected.future,
      strings: const ChallengeSheetStrings(
        note: 'Sign in to continue.',
        retry: 'Retry',
        fullScreen: 'Full screen',
        exitFullScreen: 'Exit full screen',
        close: 'Close',
        verified: 'Signed in',
      ),
    );
    expect(find.text('Done'), findsNothing);
    expect(find.text('Close'), findsOneWidget);
    redirected.complete();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(await result, ChallengeSheetResult.verified);
  });

  testWidgets('Full screen takes the whole window, and gives it back', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser);
    await more(tester);
    await tester.tap(find.text('Full screen'));
    await tester.pumpAndSettle();
    expect(tester.getSize(_card), const Size(1280, 800));
    await tester.tap(find.text('Exit full screen'));
    await tester.pumpAndSettle();
    expect(tester.getSize(_card), const Size(480, 560));
  }, variant: desktop);

  testWidgets('the address shows the page\'s site, with a lock for https, and the load\'s progress', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser);
    await host.emit(
      browser.id,
      PageEvent(kind: PageEventKind.pageStarted, url: 'https://example.com/cdn-cgi/challenge-platform'),
    );
    await tester.pump();
    expect(find.text('example.com'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await host.emit(browser.id, PageEvent(kind: PageEventKind.pageFinished, url: 'https://example.com/'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  }, variant: desktop);

  // The sheet asks where the page is as it opens. An answer that never comes must leave the
  // address to the page's next event, not throw from the sheet.
  testWidgets('a page that never answers where it is still shows its check', (tester) async {
    host.evaluateHangs = true;
    final browser = await ChallengeBrowser.create();
    await open(tester, browser);
    await tester.pump(const Duration(seconds: 11));
    await host.emit(browser.id, PageEvent(kind: PageEventKind.pageFinished, url: 'https://example.com/'));
    await tester.pump();
    expect(find.text('example.com'), findsOneWidget);
  }, variant: desktop);

  testWidgets('a page whose answer about where it is can\'t be read still shows its check', (tester) async {
    host.evaluateReply = 'not json';
    final browser = await ChallengeBrowser.create();
    await open(tester, browser);
    await host.emit(browser.id, PageEvent(kind: PageEventKind.pageFinished, url: 'https://example.com/'));
    await tester.pump();
    expect(find.text('example.com'), findsOneWidget);
  }, variant: desktop);

  testWidgets('Retry reloads the page where it is', (tester) async {
    final browser = await ChallengeBrowser.create();
    await open(tester, browser);
    await more(tester);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(host.callsOf('evaluate').map((args) => args.last), contains('location.reload()'));
  }, variant: desktop);
}

/// The sheet's visible card.
final _card = find.descendant(of: find.byType(Dialog), matching: find.byType(Material)).first;

/// The focused control's label, or its tooltip: "page" for the page.
String _focused() {
  final node = FocusManager.instance.primaryFocus;
  final context = node?.context;
  if (node == null || context == null) return '-';
  if (context.findAncestorWidgetOfExactType<ChallengeBrowserView>() != null) return 'page';
  String? text;
  void visit(Element element) {
    if (text != null) return;
    final widget = element.widget;
    if (widget is Text) {
      text = widget.data;
      return;
    }
    element.visitChildren(visit);
  }

  (context as Element).visitChildren(visit);
  return text ?? context.findAncestorWidgetOfExactType<Tooltip>()?.message ?? node.debugLabel ?? '-';
}
