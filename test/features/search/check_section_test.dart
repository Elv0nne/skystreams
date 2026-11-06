import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart' hide Step;
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/features/search/presentation/widgets/check_section.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../core/network/clearance/fakes.dart';

/// The checks a search met, above its results: a line that sums them up, a
/// row per site when opened, and Verify where a person is needed.
class _Plugin extends SkyStreamProvider {
  _Plugin(this.name, [this.source]);

  /// Its bot-check tag, `js:<name>` unless given.
  final String? source;

  @override
  final String name;
  @override
  String get packageName => 'p.$name';
  @override
  String? get checkSource => source ?? 'js:$name';
  @override
  String get mainUrl => '';
  @override
  String get version => '1';
  @override
  List<String> get languages => const ['en'];
  @override
  Set<ProviderType> get supportedTypes => const {ProviderType.movie};
  @override
  Future<List<MultimediaItem>> search(String q, {CancelToken? cancelToken}) =>
      throw UnimplementedError();
  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnimplementedError();
  @override
  Future<MultimediaItem> getDetails(String url) => throw UnimplementedError();
  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnimplementedError();
}

void main() {
  late SiteChecks checks;
  late ClearanceSolver solver;
  late DateTime began;
  final plugins = [_Plugin('Movierulz'), _Plugin('Zinkmovies')];

  // Built inside the test body: futures made in setUp belong to the real
  // zone, and pumping never runs their callbacks.
  Future<void> pump(
    WidgetTester tester, {
    List<FakePage> pages = const [],
    Set<String> rerunning = const {},
    List<SkyStreamProvider>? providers,
  }) {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    solver = ClearanceSolver(
      store: store,
      siteKeys: keys,
      checks: checks,
      openPage: PageFactory([
        ...pages,
        FakePage(const [Step.check()]),
      ]).call,
    );
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: checks,
      solver: solver,
    );
    return tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              CheckSection(
                since: began,
                providers: providers ?? plugins,
                rerunning: rerunning,
              ),
              const Expanded(child: SizedBox.expand(key: ValueKey('results'))),
            ],
          ),
        ),
      ),
    );
  }

  setUp(() {
    checks = SiteChecks();
    began = checks.now;
  });

  testWidgets('hidden until the search meets a check', (tester) async {
    await pump(tester);
    expect(find.byType(Material), findsOneWidget, reason: 'the Scaffold only');
    checks.met('5movierulz.works', source: 'js:Movierulz');
    await tester.pump();
    expect(find.text('Checking 1 site automatically…'), findsOneWidget);
  });

  testWidgets('collapsed, it sums the checks up', (tester) async {
    await pump(tester);
    checks
      ..met('a.com', source: 'js:Movierulz')
      ..met('b.com', source: 'js:Movierulz')
      ..met('c.com', source: 'js:Zinkmovies')
      ..update('a.com', CheckState.needsYou)
      ..update('b.com', CheckState.cleared);
    await tester.pump();
    expect(
      find.text('1 site needs you · 1 cleared · 1 checking'),
      findsOneWidget,
    );
    expect(find.text('Verify'), findsOneWidget);
    expect(find.text('a.com'), findsNothing, reason: 'rows show when opened');
  });

  testWidgets('opened, each site shows its extensions and its state', (
    tester,
  ) async {
    await pump(tester);
    checks
      ..met(
        '5movierulz.works',
        source: 'js:Movierulz',
        movedFrom: '5movierulz.pictures',
      )
      ..update('5movierulz.works', CheckState.needsYou)
      ..met('zinkmovies.foo', source: 'js:Zinkmovies')
      ..update(
        'zinkmovies.foo',
        CheckState.sentElsewhere,
        elsewhere: 'zinkmovies.org',
      );
    await tester.pump();
    await tester.tap(find.byTooltip('Show the sites'));
    await tester.pump();
    expect(
      find.text('5movierulz.works · moved from 5movierulz.pictures'),
      findsOneWidget,
    );
    expect(find.text('Movierulz'), findsOneWidget);
    expect(find.text('Needs a quick check from you'), findsOneWidget);
    expect(
      find.text(
        'Sends the browser to zinkmovies.org; the extension may need updating',
      ),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextButton, 'Verify'),
      findsOneWidget,
      reason: 'only the site a person can clear',
    );
  });

  testWidgets('a row filed under any CloudStream extension says when one '
      'searches again', (tester) async {
    await pump(
      tester,
      rerunning: {'p.Kinoger'},
      providers: [_Plugin('Kinoger', 'cs3:k/Kinoger')],
    );
    checks
      ..met('a.com', source: 'cs3')
      ..update('a.com', CheckState.cleared);
    await tester.pump();
    await tester.tap(find.byTooltip('Show the sites'));
    await tester.pump();
    expect(find.text('Cleared · searching again…'), findsOneWidget);
  });

  testWidgets(
    'outdated, refused and keeps-asking rows say what to do, and only the '
    'last offers Verify',
    (tester) async {
      await pump(tester);
      checks
        ..met('a.com', source: 'js:Movierulz')
        ..update('a.com', CheckState.outdated)
        ..met('b.com', source: 'js:Movierulz')
        ..update('b.com', CheckState.ineffective)
        ..met('c.com', source: 'js:Zinkmovies')
        ..update('c.com', CheckState.keepsAsking);
      await tester.pump();
      await tester.tap(find.byTooltip('Show the sites'));
      await tester.pump();
      expect(
        find.text("Update Android System WebView to clear this site's check"),
        findsOneWidget,
      );
      expect(
        find.text(
          'The check passed, but this site still refuses SkyStream. Trying '
          'again in a few minutes.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('This site keeps asking. Try later, or without a VPN.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Verify'), findsOneWidget);
    },
  );

  testWidgets("a site that doesn't open by itself says so, and Ask again "
      'undoes it', (tester) async {
    await pump(tester);
    Clearance.instance.store.setQuiet('a.com', true);
    checks
      ..met('a.com', source: 'js:Movierulz')
      ..update('a.com', CheckState.needsYou);
    await tester.pump();
    await tester.tap(find.byTooltip('Show the sites'));
    await tester.pump();
    expect(find.text("Won't open by itself"), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Ask again'));
    await tester.pump();
    expect(Clearance.instance.store.isQuiet('a.com'), isFalse);
    expect(find.text('Ask again'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Verify'), findsOneWidget);
  });

  testWidgets('an outdated browser offers Update where Android can update it, '
      'and says it is too old where it can\'t', (tester) async {
    await pump(tester);
    checks
      ..met('a.com', source: 'js:Movierulz')
      ..update('a.com', CheckState.outdated);
    await tester.pump();
    await tester.tap(find.byTooltip('Show the sites'));
    await tester.pump();
    expect(
      find.text("Update Android System WebView to clear this site's check"),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Update'), findsOneWidget);
    solver.engineUpdatable = false;
    checks.update('a.com', CheckState.outdated);
    await tester.pump();
    await tester.pump();
    expect(
      find.text("This device's browser is too old for this site's check"),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Update'), findsNothing);
  });

  testWidgets('a checking row counts the seconds', (tester) async {
    await pump(tester);
    checks.met('a.com', source: 'js:Movierulz');
    await tester.pump();
    await tester.tap(find.byTooltip('Show the sites'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Checking automatically… '), findsOneWidget);
  });

  testWidgets('a row whose extensions search again says so', (tester) async {
    await pump(tester, rerunning: {'p.Movierulz'});
    checks
      ..met('a.com', source: 'js:Movierulz')
      ..update('a.com', CheckState.cleared);
    await tester.pump();
    await tester.tap(find.byTooltip('Show the sites'));
    await tester.pump();
    expect(find.text('Cleared · searching again…'), findsOneWidget);
  });

  testWidgets('Verify all goes on past a site whose check fails to show, '
      'and can be pressed again', (tester) async {
    await pump(tester);
    final shown = <String>[];
    solver.presenter =
        ({required page, required site, required cleared}) async {
          shown.add(site);
          if (site == 'a.com') throw StateError('no sheet');
          return ChallengeSheetResult.closed;
        };
    checks
      ..met('a.com', source: 'js:Movierulz')
      ..update('a.com', CheckState.needsYou)
      ..met('b.com', source: 'js:Zinkmovies')
      ..update('b.com', CheckState.needsYou);
    await tester.pump();
    await tester.tap(find.text('Verify all'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(shown, ['a.com', 'b.com']);
    final button = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Verify all'),
        matching: find.bySubtype<ButtonStyleButton>(),
      ),
    );
    expect(button.onPressed, isNotNull);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('opened with many sites, its rows scroll and the results keep '
      'their room', (tester) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(tester);
    for (var i = 0; i < 25; i++) {
      checks
        ..met('s$i.com', source: 'js:Movierulz')
        ..update('s$i.com', CheckState.needsYou);
    }
    await tester.pump();
    await tester.tap(find.byTooltip('Show the sites'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const ValueKey('results'))).height,
      greaterThan(200),
    );
    await tester.scrollUntilVisible(
      find.text('s24.com'),
      100,
      scrollable: find
          .descendant(
            of: find.byType(CheckSection),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('s24.com'), findsOneWidget);
  });

  testWidgets('Verify all walks every site that needs a person, past a '
      'closed sheet', (tester) async {
    await pump(tester);
    final shown = <String>[];
    solver.presenter =
        ({required page, required site, required cleared}) async {
          shown.add(site);
          return ChallengeSheetResult.closed;
        };
    checks
      ..met('a.com', source: 'js:Movierulz')
      ..update('a.com', CheckState.needsYou)
      ..met('b.com', source: 'js:Zinkmovies')
      ..update('b.com', CheckState.needsYou);
    await tester.pump();
    await tester.tap(find.text('Verify all'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(shown, ['a.com', 'b.com']);
    // Each sheet's watcher stops at its next look.
    await tester.pump(const Duration(seconds: 1));
  });
}
