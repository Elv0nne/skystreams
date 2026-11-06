import 'dart:async';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_pages.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_ui_session.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/extension_page_view.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/ui_node_view.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../core/cloudstream/extension_ui/fake_page_browser.dart';

class _Api implements ExtensionUiApi {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  Future<int> openSettings(String plugin) async => 1;

  @override
  Future<int> openPopups(String plugin) async => 1;

  @override
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) async => {'done': true};

  @override
  Future<void> closeUi(int session, {bool force = false}) async {}
}

UiWindow _window(String id, List<Map<String, Object?>> children) => UiWindow.fromJson({
  'id': id,
  'kind': 'dialog',
  'cancelable': true,
  'root': {'id': id == 'w1' ? 1 : 100, 'kind': 'column', 'children': children},
});

const _page = {'id': 7, 'kind': 'page'};

void main() {
  late ExtensionPages pages;
  late FakePageBrowser browser;
  final appPages = ExtensionPages.shared;

  setUp(() {
    browser = FakePageBrowser();
    pages = ExtensionPages(create: () async => browser);
    // UiNodeView's page views read the shared pages.
    ExtensionPages.shared = pages;
  });

  tearDown(() => ExtensionPages.shared = appPages);

  Future<void> show(WidgetTester tester, ExtensionUiSession session, UiNode node, {Size size = const Size(400, 800)}) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ExtensionPageView(node: node, session: session, pages: pages, android: false),
          ),
        ),
      ),
    );
  }

  Future<void> open(int session) =>
      pages.open({'rid': 3, 'session': session, 'node': 7, 'url': 'https://site.test/'}, PageReports().call);

  testWidgets("a JVM page shows where its node is once the app has it, a spinner until then", (tester) async {
    final session = ExtensionUiSession.test(
      _Api(),
      windows: [
        _window('w1', [_page]),
      ],
    );
    await show(tester, session, UiNode.fromJson(_page));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.runAsync(() => open(session.id));
    await tester.pump();
    expect(find.byKey(const ValueKey('extension-page-3')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets("the page takes half the screen's height, between 300 and 440", (tester) async {
    expect(ExtensionPageView.heightFor(const Size(400, 800)), 400);
    expect(ExtensionPageView.heightFor(const Size(400, 400)), 300);
    expect(ExtensionPageView.heightFor(const Size(1920, 1080)), 440);
    final session = ExtensionUiSession.test(
      _Api(),
      windows: [
        _window('w1', [_page]),
      ],
    );
    await show(tester, session, UiNode.fromJson(_page));
    expect(
      tester.getSize(find.byType(ExtensionPageView)).height,
      400 + 16,
      reason: 'its height, and 8 above and below',
    );
  });

  testWidgets("a page under a window on top isn't shown: Windows' and Linux's would cover that window", (tester) async {
    final session = ExtensionUiSession.test(
      _Api(),
      windows: [
        _window('w1', [_page]),
        _window('w2', [
          {'id': 101, 'kind': 'text', 'text': 'Are you sure?'},
        ]),
      ],
    );
    await tester.runAsync(() => open(session.id));
    await show(tester, session, UiNode.fromJson(_page));
    expect(find.byKey(const ValueKey('extension-page-3')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets("on Windows and Linux a page shows only while it's wholly in view: its native window isn't clipped", (
    tester,
  ) async {
    // StreamPlay's FebBox page sits mid-list in its settings (the final review, 2026-10-07): a native window there
    // would hang below the dialog, then slide over the sheet's header as the person scrolls.
    final session = ExtensionUiSession.test(
      _Api(),
      windows: [
        _window('w1', [_page]),
      ],
    );
    await tester.runAsync(() => open(session.id));
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            // Stretched, as the sheet's rows are: the stand-in page here is a box with no size of its own.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 600),
                ExtensionPageView(
                  node: UiNode.fromJson(_page),
                  session: session,
                  pages: pages,
                  android: false,
                  nativeWindow: true,
                ),
                const SizedBox(height: 600),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('extension-page-3')), findsNothing, reason: 'partly below the fold');
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -500));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('extension-page-3')), findsOneWidget, reason: 'wholly in view');
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('extension-page-3')), findsNothing, reason: 'scrolled partly over the top');
  });

  testWidgets(
    "on Windows and Linux every page steps aside while SkyStream shows a page's dialog, which it would cover",
    (tester) async {
      // Phase 7c's §8: a page that is a window of its own is drawn over anything Flutter shows.
      final person = Completer<({bool accept, String? text})>();
      pages.dialogs = (dialog, gone) => person.future;
      final reports = PageReports()..answers['dialog'] = {'show': true};
      final session = ExtensionUiSession.test(
        _Api(),
        windows: [
          _window('w1', [_page]),
        ],
      );
      await tester.runAsync(
        () => pages.open({'rid': 3, 'session': session.id, 'node': 7, 'url': 'https://site.test/'}, reports.call),
      );
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ExtensionPageView(
              node: UiNode.fromJson(_page),
              session: session,
              pages: pages,
              android: false,
              nativeWindow: true,
              fill: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('extension-page-3')), findsOneWidget);
      await tester.runAsync(() async {
        browser.controller.add(const PageDialog(id: 1, kind: DialogKind.alert, message: 'Hi'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('extension-page-3')), findsNothing, reason: 'stepped aside');
      await tester.runAsync(() async {
        person.complete((accept: true, text: null));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('extension-page-3')), findsOneWidget, reason: 'back once it closed');
    },
  );

  testWidgets("a page that couldn't open says it can't show", (tester) async {
    final failing = ExtensionPages(create: () async => throw StateError('no WebView2'));
    pages = failing;
    final session = ExtensionUiSession.test(
      _Api(),
      windows: [
        _window('w1', [_page]),
      ],
    );
    await tester.runAsync(
      () => failing.open({'rid': 3, 'session': session.id, 'node': 7, 'url': 'x'}, PageReports().call),
    );
    await show(tester, session, UiNode.fromJson(_page));
    expect(find.text("This part can't be shown in SkyStream yet."), findsOneWidget);
  });

  testWidgets('the page view is kept across trees while its node stays', (tester) async {
    final session = ExtensionUiSession.test(
      _Api(),
      windows: [
        _window('w1', [_page]),
      ],
    );
    await tester.runAsync(() => open(session.id));
    Widget tree(List<Map<String, Object?>> children) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: UiNodeView(node: UiNode.fromJson({'id': 1, 'kind': 'column', 'children': children}), session: session),
        ),
      ),
    );
    // UiNodeView builds the JVM's page, as the host it runs on isn't Android.
    await tester.pumpWidget(tree([_page]));
    final before = tester.element(find.byKey(const ValueKey('extension-page-3')));
    // StreamPlay's sign-in puts a line above the page as it goes.
    session.receive({
      'event': 'ui',
      'session': session.id,
      'windows': [
        {
          'id': 'w1',
          'kind': 'dialog',
          'root': {
            'id': 1,
            'kind': 'column',
            'children': [
              {
                'id': 8,
                'kind': 'column',
                'children': [
                  {'id': 9, 'kind': 'text', 'text': 'Signing in…'},
                ],
              },
              _page,
            ],
          },
        },
      ],
    });
    await tester.pumpWidget(
      tree([
        {
          'id': 8,
          'kind': 'column',
          'children': [
            {'id': 9, 'kind': 'text', 'text': 'Signing in…'},
          ],
        },
        _page,
      ]),
    );
    expect(identical(tester.element(find.byKey(const ValueKey('extension-page-3'))), before), isTrue);
  });

  testWidgets("Android's page in the full-screen view keeps the D-pad and the keyboard; the sheet's lets them go on", (
    tester,
  ) async {
    final made = <Map<Object?, Object?>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      if (call.method == 'create') {
        final params = (call.arguments as Map<Object?, Object?>)['params'] as Uint8List;
        made.add(const StandardMessageCodec().decodeMessage(ByteData.sublistView(params)) as Map<Object?, Object?>);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform_views, null));
    final session = ExtensionUiSession.test(
      _Api(),
      windows: [
        _window('w1', [_page]),
      ],
    );
    for (final fullScreen in [true, false]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExtensionPageView(
              key: ValueKey(fullScreen),
              node: UiNode.fromJson(_page),
              session: session,
              android: true,
              fill: fullScreen,
              autofocus: fullScreen,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }
    expect(made.map((params) => params['keepFocus']), [true, false]);
  });
}
