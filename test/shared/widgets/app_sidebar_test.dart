/// The side rail of a tablet, desktop or television layout: its enlarged,
/// labelled item belongs to a mouse hovering it or to a remote or keyboard
/// steering focus to it - never to a finger that tapped it (on an iPad the
/// tapped item stayed enlarged, as if hovered, until a mouse came by).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/focus/app_focus.dart';
import 'package:skystream/shared/widgets/app_sidebar.dart';

/// The rail as the app installs it: under the root's [FocusVisibilityScope].
Future<List<FocusNode>> _pump(
  WidgetTester tester, {
  bool television = false,
}) async {
  final nodes = List.generate(
    kSidebarDestinationCount,
    (i) => FocusNode(debugLabel: 'rail $i'),
  );
  addTearDown(() {
    for (final node in nodes) {
      node.dispose();
    }
  });
  var index = 0;
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) =>
            FocusVisibilityScope(television: television, child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Align(
              alignment: Alignment.centerLeft,
              child: AppSidebar(
                currentIndex: index,
                onItemTapped: (i) => setState(() => index = i),
                focusNodes: nodes,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return nodes;
}

/// Item [i]'s side: 40 at rest, 80 enlarged.
double _size(WidgetTester tester, int i) => tester
    .widget<AnimatedPositioned>(find.byKey(ValueKey('dock_item_$i')))
    .width!;

/// Whether any item's label shows.
bool _labelShows(WidgetTester tester) => tester
    .widgetList<AnimatedOpacity>(
      find.descendant(
        of: find.byType(AppSidebar),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .any((label) => label.opacity > 0);

void main() {
  testWidgets('a tap leaves the rail at rest: nothing enlarged, no label', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byIcon(Icons.explore_outlined));
    await tester.pumpAndSettle();
    for (var i = 0; i < kSidebarDestinationCount; i++) {
      expect(_size(tester, i), 40, reason: 'item $i');
    }
    expect(_labelShows(tester), isFalse);
  });

  testWidgets('a key steering focus still enlarges the item it lands on', (
    tester,
  ) async {
    final nodes = await _pump(tester);
    nodes.first.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_size(tester, 1), 80);
    expect(_labelShows(tester), isTrue);
  });

  testWidgets('on a television, focus enlarges its item from the start', (
    tester,
  ) async {
    final nodes = await _pump(tester, television: true);
    nodes.first.requestFocus();
    await tester.pumpAndSettle();
    expect(_size(tester, 0), 80);
  });
}
