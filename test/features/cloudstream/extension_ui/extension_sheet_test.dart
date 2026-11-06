/// The sheet that holds an extension's windows: its shape on each form factor, a dialog on top for a
/// second window, Back and the close button on the top window, Force close, and closing when the
/// extension's last window goes.
library;

import 'dart:async';

import 'package:cs3_engine/cs3_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_ui_session.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_full_screen.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_settings_flow.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_sheet.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../core/cloudstream/extension_ui/fake_page_browser.dart';

class _Api implements ExtensionUiApi {
  final sent = <String>[];
  Object? failing;

  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  Future<int> openSettings(String plugin) async => 1;

  @override
  Future<int> openPopups(String plugin) async => 1;

  @override
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) async {
    sent.add('$node $action $value');
    final error = failing;
    if (error != null) throw error;
    return {'done': true};
  }

  @override
  Future<void> closeUi(int session, {bool force = false}) async => sent.add('closeUi $force');
}

UiWindow _window(String id, String text, {int root = 1, bool cancelable = true}) => UiWindow.fromJson({
  'id': id,
  'kind': 'dialog',
  'cancelable': cancelable,
  'root': {'id': root, 'kind': 'text', 'text': text},
});

class _QuietDevice implements FullScreenDevice {
  @override
  Future<void> enter({required bool keepScreenOn, List<DeviceOrientation>? orientations}) async {}

  @override
  Future<void> leave() async {}
}

Map<String, Object?> _windowJson(String id, String text, {int root = 1, bool fullScreen = false}) => {
  'id': id,
  'kind': 'dialog',
  'fullScreen': fullScreen,
  'root': {'id': root, 'kind': 'text', 'text': text},
};

/// What the D-pad is on: the focused control's first text, or its kind when it has none.
String? _focused() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return null;
  String? label;
  void visit(Element element) {
    final widget = element.widget;
    if (label == null && widget is Text) label = widget.data;
    if (label == null) element.visitChildren(visit);
  }

  (focused as Element).visitChildren(visit);
  return label ??
      [
        if (focused.findAncestorWidgetOfExactType<EditableText>() != null) 'field',
        if (focused.findAncestorWidgetOfExactType<Slider>() != null) 'slider',
        if (focused.findAncestorWidgetOfExactType<DropdownButtonFormField<int>>() != null) 'dropdown',
      ].firstOrNull;
}

void main() {
  late _Api api;

  Future<ExtensionUiSession> open(
    WidgetTester tester,
    List<UiWindow> windows, {
    Size size = const Size(400, 800),
    bool tv = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = ExtensionUiSession.test(api, windows: windows);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(showExtensionSheet(context, session: session, title: 'CNC Verse', tv: tv)),
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

  setUp(() => api = _Api());

  testWidgets('phones get a bottom sheet, larger screens a dialog, TVs a full screen', (tester) async {
    await open(tester, [_window('w1', 'Studios')]);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Studios'), findsOneWidget);
    expect(find.text('CNC Verse'), findsOneWidget);
  });

  testWidgets("the sheet covers the app's own bars: it opens on the root navigator", (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = ExtensionUiSession.test(api, windows: [_window('w1', 'Studios')]);
    final root = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: root,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // As the app's shell: a nested navigator above a navigation bar.
        home: Scaffold(
          body: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (context) => TextButton(
                onPressed: () =>
                    unawaited(showExtensionSheet(context, session: session, title: 'CNC Verse', tv: false)),
                child: const Text('Open'),
              ),
            ),
          ),
          bottomNavigationBar: const SizedBox(height: 56, child: Text('Bar')),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(Navigator.of(tester.element(find.text('Studios'))), same(root.currentState));
  });

  testWidgets('a tablet or desktop gets a dialog', (tester) async {
    await open(tester, [_window('w1', 'Studios')], size: const Size(1200, 900));
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a TV gets the whole screen', (tester) async {
    await open(tester, [_window('w1', 'Studios')], size: const Size(1920, 1080), tv: true);
    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.insetPadding, EdgeInsets.zero);
  });

  testWidgets('a second window shows on top, and closing closes it first', (tester) async {
    await open(tester, [_window('w1', 'Studios'), _window('w2', 'Restart Required', root: 9)]);
    expect(find.text('Restart Required'), findsOneWidget);
    await tester.tap(find.byTooltip('Close').last);
    await tester.pump();
    expect(api.sent, ['9 close null']);
  });

  testWidgets("a window on top holding a page gets the sheet's height, its buttons in view below the page", (
    tester,
  ) async {
    // AnimeWorldIndia's Cloudflare alert (2026-10-07, the release build): with the page, its Done went below the
    // window's 420 points, out of reach.
    final appPages = ExtensionPages.shared;
    addTearDown(() => ExtensionPages.shared = appPages);
    ExtensionPages.shared = ExtensionPages(create: () async => FakePageBrowser());
    await tester.runAsync(
      () => ExtensionPages.shared.open({
        'rid': 3,
        'session': 1,
        'node': 7,
        'url': 'https://site.test/',
      }, PageReports().call),
    );
    final alert = UiWindow.fromJson({
      'id': 'w2',
      'kind': 'alert',
      'cancelable': true,
      'root': {
        'id': 100,
        'kind': 'column',
        'children': [
          {'id': 101, 'kind': 'text', 'text': 'Cloudflare Bypass'},
          {'id': 102, 'kind': 'text', 'text': 'Solve the CAPTCHA below, then tap Done.'},
          {'id': 7, 'kind': 'page'},
          {'id': 103, 'kind': 'button', 'text': 'Done', 'tappable': true},
        ],
      },
    });
    await open(tester, [_window('w1', 'Anime World India Settings'), alert]);
    expect(find.byKey(const ValueKey('extension-page-3')), findsOneWidget);
    expect(find.text('Done').hitTestable(), findsOneWidget);
    expect(tester.getRect(find.text('Done')).bottom, lessThanOrEqualTo(800));
    await tester.tap(find.text('Done'));
    await tester.pump();
    expect(api.sent, ['103 click null']);
  });

  group("a page window's buttons stay in reach wherever the sheet is a dialog or short", () {
    // AnimeWorldIndia's alert: a heading, a message, its page, and a Cancel/Done row (the final review, 2026-10-07).
    UiWindow alert() => UiWindow.fromJson({
      'id': 'w2',
      'kind': 'alert',
      'cancelable': true,
      'root': {
        'id': 100,
        'kind': 'column',
        'children': [
          {'id': 101, 'kind': 'text', 'text': 'Cloudflare Bypass', 'heading': true},
          {'id': 102, 'kind': 'text', 'text': 'Solve the CAPTCHA below, then tap Done.'},
          {'id': 7, 'kind': 'page'},
          {
            'id': 104,
            'kind': 'row',
            'children': [
              {'id': 105, 'kind': 'button', 'text': 'Cancel', 'tappable': true},
              {'id': 103, 'kind': 'button', 'text': 'Done', 'tappable': true},
            ],
          },
        ],
      },
    });

    Future<void> showAlert(WidgetTester tester, Size size) async {
      final appPages = ExtensionPages.shared;
      addTearDown(() => ExtensionPages.shared = appPages);
      ExtensionPages.shared = ExtensionPages(create: () async => FakePageBrowser());
      await tester.runAsync(
        () => ExtensionPages.shared.open({'rid': 3, 'session': 1, 'node': 7, 'url': 'https://site.test/'}, PageReports().call),
      );
      await open(tester, [_window('w1', 'Anime World India Settings'), alert()], size: size);
    }

    for (final size in const [Size(1280, 720), Size(1440, 900), Size(1920, 1040)]) {
      testWidgets('in a ${size.width.toInt()}×${size.height.toInt()} dialog, Done is in view below the page', (
        tester,
      ) async {
        await showAlert(tester, size);
        final done = find.text('Done');
        final card = tester.getRect(find.ancestor(of: done, matching: find.byType(Scrollable)).first);
        expect(tester.getRect(done).bottom, lessThanOrEqualTo(card.bottom));
        expect(done.hitTestable(), findsOneWidget);
      });
    }

    testWidgets('on a phone held sideways, the page takes at most half the window: the rest scrolls it by touch', (
      tester,
    ) async {
      await showAlert(tester, const Size(800, 360));
      final page = tester.getRect(find.byKey(const ValueKey('extension-page-3')));
      final card = tester.getRect(
        find.ancestor(of: find.byKey(const ValueKey('extension-page-3')), matching: find.byType(Scrollable)).first,
      );
      expect(page.height, lessThanOrEqualTo(card.height / 2 + 0.5));
    });
  });

  testWidgets(
    "Back closes the top window; one that won't close offers no close button, and Force close shuts them all",
    (tester) async {
      await open(tester, [_window('w1', 'Terms', cancelable: false)]);
      expect(find.byTooltip('Close'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(api.sent, ['1 close null']);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Force close'));
      await tester.pump();
      expect(api.sent.last, 'closeUi true');
    },
  );

  testWidgets("the sheet goes once the extension's last window has", (tester) async {
    final session = await open(tester, [_window('w1', 'Studios')]);
    session.receive({'event': 'uiClosed', 'session': session.id, 'reason': 'closed'});
    await tester.pumpAndSettle();
    expect(find.text('Studios'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a screen that ended before the sheet was first built takes the sheet away', (tester) async {
    // A screen the engine opens can end while the app draws no frames (in the background, locked): its
    // sheet is built only afterwards, and no change comes to close it.
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = ExtensionUiSession.test(api, windows: [_window('w1', 'Studios')]);
    session.receive({'event': 'uiClosed', 'session': session.id, 'reason': 'closed'});
    var returned = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(
                showExtensionSheet(
                  context,
                  session: session,
                  title: 'CNC Verse',
                  tv: false,
                ).then((_) => returned = true),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionSheet), findsNothing);
    expect(returned, isTrue);
    expect(api.sent, isEmpty, reason: 'nothing to close: the engine has already ended it');
  });

  testWidgets("an action's error is in words, without the engine's exception class", (tester) async {
    final session = await open(tester, [_window('w1', 'Studios')]);
    api.failing = Cs3EngineException('java.lang.IllegalArgumentException', 'node 3 is gone');
    await session.act(1, 'click');
    await tester.pump();
    expect(find.text("The extension didn't take that: node 3 is gone"), findsOneWidget);
  });

  testWidgets('a screen that ends while the More menu is open takes the menu and the sheet away', (tester) async {
    final session = await open(tester, [_window('w1', 'Studios')]);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Force close'), findsOneWidget);
    session.receive({'event': 'uiClosed', 'session': session.id, 'reason': 'closed'});
    await tester.pumpAndSettle();
    expect(find.text('Force close'), findsNothing);
    expect(find.byType(ExtensionSheet), findsNothing);
  });

  testWidgets('with three windows, the middle one shows too, under the top one, which alone takes taps', (
    tester,
  ) async {
    await open(tester, [
      _window('w1', 'Studios'),
      _window('w2', 'Pick a source', root: 2),
      UiWindow.fromJson({
        'id': 'w3',
        'kind': 'alert',
        'root': {'id': 3, 'kind': 'button', 'text': 'OK', 'tappable': true},
      }),
    ]);
    expect(find.text('Pick a source'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(api.sent, ['3 click null']);
  });

  testWidgets('an action the extension failed on is shown', (tester) async {
    final session = await open(tester, [_window('w1', 'Studios')]);
    api.failing = StateError('node 3 is gone');
    await session.act(1, 'click');
    await tester.pump();
    expect(find.textContaining("The extension didn't take that"), findsOneWidget);
  });

  testWidgets(
    "a swipe down on the phone sheet's header closes its top window, as Back does; the sheet stays for the engine",
    (tester) async {
      await open(tester, [_window('w1', 'Studios')]);
      await tester.fling(find.text('CNC Verse'), const Offset(0, 400), 2000);
      await tester.pumpAndSettle();
      expect(api.sent, ['1 close null']);
      expect(
        find.byType(ExtensionSheet),
        findsOneWidget,
        reason: 'the engine ends the screen, and the sheet goes then',
      );
    },
  );

  testWidgets("a swipe on the sheet's content leaves it, and the screen, alone", (tester) async {
    await open(tester, [_window('w1', 'Studios')]);
    await tester.fling(find.text('Studios'), const Offset(0, 400), 2000);
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionSheet), findsOneWidget);
    expect(api.sent, isEmpty);
  });

  testWidgets("with a window on top that won't close, Force close is still in reach", (tester) async {
    await open(tester, [_window('w1', 'Studios'), _window('w2', 'Please wait', root: 9, cancelable: false)]);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Force close'));
    await tester.pump();
    expect(api.sent, ['closeUi true']);
  });

  testWidgets("a window over a short sheet isn't cut off: its buttons can be pressed", (tester) async {
    await open(tester, [
      _window('w1', 'Studios'),
      UiWindow.fromJson({
        'id': 'w2',
        'kind': 'alert',
        'root': {
          'id': 20,
          'kind': 'column',
          'children': [
            {'id': 21, 'kind': 'text', 'text': 'Restart required', 'heading': true},
            {'id': 22, 'kind': 'text', 'text': 'Restart the app to apply the changes?'},
            {
              'id': 23,
              'kind': 'row',
              'children': [
                {'id': 24, 'kind': 'button', 'text': 'No', 'tappable': true},
                {'id': 25, 'kind': 'button', 'text': 'Yes', 'tappable': true},
              ],
            },
          ],
        },
      }),
    ]);
    await tester.tap(find.text('Yes'));
    await tester.pump();
    expect(api.sent, ['25 click null']);
  });

  testWidgets('on TV, a window over the sheet takes the focus, so the remote acts on it', (tester) async {
    final session = await open(
      tester,
      [
        UiWindow.fromJson({
          'id': 'w1',
          'kind': 'dialog',
          'root': {'id': 1, 'kind': 'button', 'text': 'Save', 'tappable': true},
        }),
      ],
      size: const Size(1920, 1080),
      tv: true,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    session.receive({
      'event': 'ui',
      'session': session.id,
      'windows': [
        {
          'id': 'w1',
          'kind': 'dialog',
          'root': {'id': 1, 'kind': 'button', 'text': 'Save', 'tappable': true},
        },
        {
          'id': 'w2',
          'kind': 'alert',
          'root': {
            'id': 20,
            'kind': 'row',
            'children': [
              {'id': 21, 'kind': 'button', 'text': 'Yes', 'tappable': true},
              {'id': 22, 'kind': 'button', 'text': 'No', 'tappable': true},
            ],
          },
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(api.sent, ['21 click null']);
  });

  testWidgets('on TV the D-pad goes down through every kind of control, past a field and a slider, to Save', (
    tester,
  ) async {
    await open(
      tester,
      [
        UiWindow.fromJson({
          'id': 'w1',
          'kind': 'dialog',
          'root': {
            'id': 1,
            'kind': 'column',
            'children': [
              {'id': 2, 'kind': 'checkbox', 'text': 'Second provider', 'checked': true, 'tappable': true},
              {'id': 3, 'kind': 'field', 'text': '', 'hint': 'Paste a token'},
              {
                'id': 4,
                'kind': 'dropdown',
                'options': ['480p', '720p', '1080p'],
                'selected': 0,
              },
              {'id': 5, 'kind': 'radio', 'text': 'Fast', 'checked': true, 'tappable': true},
              {'id': 6, 'kind': 'slider', 'value': 30, 'max': 60},
              {
                'id': 7,
                'kind': 'list',
                'items': 2,
                'children': [
                  for (var i = 1; i <= 2; i++) {'id': 10 + i, 'kind': 'text', 'text': 'Item $i', 'tappable': true},
                ],
              },
              {'id': 9, 'kind': 'button', 'text': 'Save', 'tappable': true},
            ],
          },
        }),
      ],
      size: const Size(1920, 1080),
      tv: true,
    );
    final visited = <String?>[];
    for (var i = 0; i < 20 && _focused() != 'Save'; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 100));
      if (visited.lastOrNull != _focused()) visited.add(_focused());
    }
    expect(_focused(), 'Save', reason: 'the D-pad went through $visited');
    expect(api.sent.where((s) => s.startsWith('6 ')), isEmpty, reason: "passing the slider doesn't move it");
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(api.sent, ['9 click null']);
  });

  testWidgets("on TV a remote opens an extension's dropdown with OK and picks an option with OK", (tester) async {
    await open(
      tester,
      [
        UiWindow.fromJson({
          'id': 'w1',
          'kind': 'dialog',
          'root': {
            'id': 4,
            'kind': 'dropdown',
            'options': ['480p', '720p', '1080p'],
            'selected': 0,
          },
        }),
      ],
      size: const Size(1920, 1080),
      tv: true,
    );
    for (var i = 0; i < 5 && _focused() != '480p'; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_focused(), '480p');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_focused(), '720p');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(api.sent, ['4 select 1']);
  });

  Future<ExtensionUiSession> openScreen(WidgetTester tester, List<Map<String, Object?>> windows) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = ExtensionUiSession.test(api, windows: [for (final window in windows) UiWindow.fromJson(window)]);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(
                showExtensionScreen(context, session: session, name: 'StreamHubOne', tv: false, device: _QuietDevice()),
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

  testWidgets('a screen whose window asks for the whole screen opens full screen, with no sheet', (tester) async {
    await openScreen(tester, [_windowJson('w1', 'Game', fullScreen: true)]);
    expect(find.byType(ExtensionFullScreen), findsOneWidget);
    expect(find.byType(BottomSheet, skipOffstage: false), findsNothing);
  });

  testWidgets('a full-screen window over the sheet shows over it; the sheet keeps its own, and shows once it goes', (
    tester,
  ) async {
    // Review Focus 4: StreamHubOne's page from its settings.
    final settings = _windowJson('w1', 'Settings');
    final session = await openScreen(tester, [settings]);
    expect(find.byType(BottomSheet), findsOneWidget);
    session.receive({
      'event': 'ui',
      'session': 1,
      'windows': [settings, _windowJson('w2', 'Sign in', root: 2, fullScreen: true)],
    });
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsOneWidget);
    final inSheet = find.descendant(
      of: find.byType(ExtensionSheet, skipOffstage: false),
      matching: find.text('Sign in', skipOffstage: false),
    );
    expect(inSheet, findsNothing, reason: 'shown once, in the view');
    session.receive({
      'event': 'ui',
      'session': 1,
      'windows': [settings],
    });
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsNothing);
    expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Settings')), findsOneWidget);
  });

  testWidgets('once no window asks for the whole screen what is left shows in the sheet, and the end closes it', (
    tester,
  ) async {
    final session = await openScreen(tester, [_windowJson('w1', 'Game', fullScreen: true)]);
    session.receive({
      'event': 'ui',
      'session': 1,
      'windows': [_windowJson('w2', 'Saved!', root: 9)],
    });
    await tester.pumpAndSettle();
    expect(find.byType(ExtensionFullScreen), findsNothing);
    expect(find.descendant(of: find.byType(BottomSheet), matching: find.text('Saved!')), findsOneWidget);
    session.receive({'event': 'uiClosed', 'session': 1, 'reason': 'closed'});
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets(
    "the sheet's bottom window asking for the whole screen hands the screen to the view, with no second view",
    (tester) async {
      final settings = _windowJson('w1', 'Settings');
      final session = await openScreen(tester, [settings]);
      session.receive({
        'event': 'ui',
        'session': 1,
        'windows': [settings, _windowJson('w2', 'Reader', root: 2, fullScreen: true)],
      });
      await tester.pumpAndSettle();
      session.receive({
        'event': 'ui',
        'session': 1,
        'windows': [_windowJson('w2', 'Reader', root: 2, fullScreen: true)],
      });
      await tester.pumpAndSettle();
      expect(find.byType(ExtensionFullScreen), findsOneWidget);
      expect(find.byType(BottomSheet, skipOffstage: false), findsNothing);
    },
  );

  testWidgets('a screen that opens with a full-screen window above the sheet\'s own shows it at once', (tester) async {
    // Its first windows already hold one (an extension that shows its settings and a full-screen page together).
    await openScreen(tester, [_windowJson('w1', 'Settings'), _windowJson('w2', 'Sign in', root: 2, fullScreen: true)]);
    expect(find.byType(ExtensionFullScreen), findsOneWidget);
  });
}
