import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/theme/app_theme.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart';
import 'package:skystream/features/player/presentation/widgets/player_matte_pill.dart';

/// A button in the bar's pill shows focus the way it does anywhere else: a
/// wash behind it, and on a television a ring - never as the accent colour
/// alone, which already means "on" (Speed off 1x, torrent stats shown) and so
/// would show nothing on those buttons at all.
void main() {
  for (final isTv in [false, true]) {
    testWidgets('focus in the pill: a wash${isTv ? ' and a ring' : ''} on '
        '${isTv ? 'a television' : 'a desktop'}', (tester) async {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlayerMattePill(
                child: PlayerIconButton(
                  icon: Icons.speed_rounded,
                  tooltip: 'Speed',
                  onPressed: () {},
                  isTv: isTv,
                  highlight: true,
                  focusNode: node,
                ),
              ),
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();

      final style = tester.widget<TextButton>(find.byType(TextButton)).style!;
      const focused = {WidgetState.focused};
      final wash = style.backgroundColor?.resolve(focused);
      expect(wash, isNotNull);
      expect(wash!.a, greaterThan(0), reason: 'a visible wash');
      final ring = style.side?.resolve(focused);
      if (isTv) {
        expect(ring, isNot(anyOf(isNull, BorderSide.none)), reason: 'a ring');
      }
    });
  }

  testWidgets('in the light app theme the ring and the wash still read on the '
      'dark chrome', (tester) async {
    // The chrome is dark in either app theme. Drawn in the light theme's own
    // foreground, near-black, the ring was 1.16:1 against the bar and the
    // wash 1.02:1: a remote in the light theme lost its place in the player.
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createLightTheme(null),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: PlayerMattePill(
              child: PlayerIconButton(
                icon: Icons.speed_rounded,
                tooltip: 'Speed',
                onPressed: () {},
                isTv: true,
                focusNode: node,
              ),
            ),
          ),
        ),
      ),
    );
    node.requestFocus();
    await tester.pumpAndSettle();

    final style = tester.widget<TextButton>(find.byType(TextButton)).style!;
    const focused = {WidgetState.focused};
    // The bar's floor: the scrim's bottom stop over a white scene.
    const bar = Color(0xFF1A1A1A);
    final ring = style.side!.resolve(focused)!.color;
    expect(_contrast(ring, bar), greaterThanOrEqualTo(3), reason: 'the ring');
    final washed = Color.alphaBlend(style.backgroundColor!.resolve(focused)!, bar);
    expect(
      _contrast(washed, bar),
      greaterThan(1.2),
      reason: 'the wash lifts the button off the bar, as in the dark theme',
    );
  });
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
