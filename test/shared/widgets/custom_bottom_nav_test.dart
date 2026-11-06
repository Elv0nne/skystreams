import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/custom_bottom_nav.dart';
import 'package:skystream/shared/widgets/matte_glass_pill.dart';

/// The bar a phone shows, and a desktop window narrower than 600 dp, where a
/// keyboard moves through it.
void main() {
  Future<void> pump(WidgetTester tester, Brightness brightness) =>
      tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            bottomNavigationBar: CustomBottomNavBar(
              currentIndex: 0,
              onTap: (_) {},
            ),
          ),
        ),
      );

  /// The cells drawing a border: the focus ring.
  Finder rings() => find.byWidgetPredicate(
    (w) =>
        w is AnimatedContainer &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).border != null,
  );

  testWidgets('the focused tab wears the focus ring, the selected one too', (
    tester,
  ) async {
    // WCAG 2.4.7: focus has to show, and not as a colour alone (1.4.1) - the
    // selected tab is already in the accent colour, so a colour change would
    // show nothing on it at all.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await pump(tester, Brightness.dark);
    expect(rings(), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(rings(), findsOne, reason: 'Home: selected and focused');
    final home = tester.getRect(rings());

    // One press, one tab: the next press is on Search.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(rings(), findsOne, reason: 'Search: focused');
    expect(tester.getRect(rings()).left, greaterThan(home.right - 1));
  });

  for (final brightness in Brightness.values) {
    testWidgets('the bar is the ${brightness.name} theme\'s surface at 80%', (
      tester,
    ) async {
      // Over the brightest and darkest posters the icons keep at least 3:1
      // (WCAG 1.4.11) at this opacity - 7.4:1 dark, 3.7:1 light; at the 22% of
      // a glass pill they fell to 1.1:1 and 1.8:1.
      await pump(tester, brightness);
      final pill = find.byType(MatteGlassPill);
      final scheme = Theme.of(tester.element(pill)).colorScheme;

      expect(
        tester.widget<MatteGlassPill>(pill).surfaceColor,
        scheme.surface.withValues(alpha: 0.8),
      );
    });
  }
}
