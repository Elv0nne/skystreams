import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/network/clearance/clearance.dart';
import 'package:skystream/core/network/clearance/clearance_solver.dart';
import 'package:skystream/core/network/clearance/clearance_store.dart';
import 'package:skystream/core/network/clearance/site_checks.dart';
import 'package:skystream/core/network/clearance/site_keys.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/check_line.dart';

/// Every site a set of extensions met a check on, a line each: Nuvio's
/// scrapers in the sources dialog, the add-ons a sources sheet asked.
void main() {
  late DateTime now;
  late SiteChecks checks;

  setUp(() {
    now = DateTime(2026, 10, 3, 9);
    checks = SiteChecks(clock: () => now);
    final keys = SiteKeys.parse(
      File('assets/clearance/public_suffix_list.dat').readAsStringSync(),
    );
    final store = ClearanceStore();
    Clearance.instance.debugUse(
      store: store,
      siteKeys: keys,
      checks: checks,
      solver: ClearanceSolver(store: store, siteKeys: keys, checks: checks),
    );
  });

  tearDown(() => Clearance.instance.solver.dispose());

  Widget host(Widget child) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );

  testWidgets(
    'a line for each site the sources met, Verify where a person is wanted',
    (tester) async {
      final cleared = <String>[];
      await tester.pumpWidget(
        host(
          CheckLines(
            sources: const {'nuvio:a', 'nuvio:b'},
            since: now,
            onCleared: (check) => cleared.add(check.site),
          ),
        ),
      );
      checks
        ..met('a.com', source: 'nuvio:a')
        ..met('b.com', source: 'nuvio:b')
        ..update('b.com', CheckState.needsYou)
        ..met('c.com', source: 'js:other');
      await tester.pump();

      expect(
        find.textContaining('Checking a.com automatically'),
        findsOneWidget,
      );
      expect(find.text('b.com needs a quick check'), findsOneWidget);
      expect(find.textContaining('c.com'), findsNothing);
      expect(find.text('Verify'), findsOneWidget);

      checks.update('b.com', CheckState.cleared);
      // The checks' change arrives after the first frame.
      await tester.pump();
      await tester.pump();
      expect(cleared, ['b.com']);
      expect(find.text('b.com needs a quick check'), findsNothing);

      // Told once.
      checks.update('b.com', CheckState.cleared);
      await tester.pump();
      expect(cleared, ['b.com']);

      // Its seconds tick while a.com is tried: gone with the widget.
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('checks from before the wait aren\'t its lines', (tester) async {
    checks
      ..met('old.com', source: 'nuvio:a')
      ..update('old.com', CheckState.needsYou);
    now = now.add(const Duration(minutes: 1));
    await tester.pumpWidget(
      host(CheckLines(sources: const {'nuvio:a'}, since: now)),
    );
    await tester.pump();
    expect(find.textContaining('old.com'), findsNothing);
  });
}
