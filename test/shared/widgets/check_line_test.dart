import 'dart:io';

import 'package:challenge_browser/challenge_browser.dart';
import 'package:flutter/material.dart' hide Step;
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/check_line.dart';

import '../../core/network/clearance/fakes.dart';

/// One site's check under a spinner: being tried, or wanting a person.
void main() {
  late DateTime now;
  late SiteChecks checks;
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() {
    now = DateTime(2026, 10, 3, 9);
    checks = SiteChecks(clock: () => now);
  });

  test('while it is tried: the site and the seconds', () {
    final began = now;
    checks.met('a.com', source: 'js:a');
    now = now.add(const Duration(seconds: 3));
    expect(
      checkLineText(checks, 'js:a', began, l10n),
      'Checking a.com automatically… 3 s',
    );
  });

  test('wanting a person; nothing once cleared, or for another extension', () {
    final began = now;
    checks
      ..met('a.com', source: 'js:a')
      ..update('a.com', CheckState.needsYou);
    expect(
      checkLineText(checks, 'js:a', began, l10n),
      'a.com needs a quick check',
    );
    expect(checkLineText(checks, 'js:b', began, l10n), isNull);
    checks.update('a.com', CheckState.cleared);
    expect(checkLineText(checks, 'js:a', began, l10n), isNull);
  });

  test(
    'an outdated browser, a refusing site and one that keeps asking: why',
    () {
      final began = now;
      checks
        ..met('a.com', source: 'js:a')
        ..update('a.com', CheckState.outdated);
      expect(
        checkLineText(checks, 'js:a', began, l10n),
        "Update Android System WebView to clear this site's check",
      );
      checks.update('a.com', CheckState.ineffective);
      expect(
        checkLineText(checks, 'js:a', began, l10n),
        'The check passed, but this site still refuses SkyStream. Trying again '
        'in a few minutes.',
      );
      checks.update('a.com', CheckState.keepsAsking);
      expect(
        checkLineText(checks, 'js:a', began, l10n),
        'This site keeps asking. Try later, or without a VPN.',
      );
    },
  );

  test('while Verify opens the page: the site, and that it is opening', () {
    final began = now;
    checks
      ..met('a.com', source: 'js:a')
      ..update('a.com', CheckState.opening);
    expect(
      checkLineText(checks, 'js:a', began, l10n),
      'Opening a.com\'s check…',
    );
  });

  // The window a line looks back over is on the checks' clock, as the checks'
  // own times are: a line built far from it in wall time still finds them.
  testWidgets('a line looks back on the checks\' own clock', (tester) async {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    final old = SiteChecks(clock: () => DateTime(2020));
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: old,
      solver: ClearanceSolver(store: store, siteKeys: keys, checks: old),
    );
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: CheckLine(source: 'js:a')),
      ),
    );
    old
      ..met('a.com', source: 'js:a')
      ..update('a.com', CheckState.needsYou);
    await tester.pump();
    expect(find.text('a.com needs a quick check'), findsOneWidget);
  });

  testWidgets('Verify where offered; the screen hears when it clears', (
    tester,
  ) async {
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    final live = SiteChecks();
    final solver =
        ClearanceSolver(
            store: store,
            siteKeys: keys,
            checks: live,
            openPage: PageFactory([
              FakePage(const [Step('Example')]),
            ]).call,
          )
          ..presenter = ({
            required page,
            required site,
            required cleared,
          }) async => ChallengeSheetResult.done;
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: live,
      solver: solver,
    );
    var cleared = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CheckLine(
            source: 'js:a',
            offerVerify: true,
            onCleared: () => cleared++,
          ),
        ),
      ),
    );
    live
      ..met('example.com', source: 'js:a')
      ..update('example.com', CheckState.needsYou);
    await tester.pump();
    expect(find.text('example.com needs a quick check'), findsOneWidget);
    await tester.tap(find.text('Verify'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(cleared, 1);
    expect(find.text('Verify'), findsNothing);
    // The sheet's watcher stops at its next look.
    await tester.pump(const Duration(seconds: 1));
  });
}
