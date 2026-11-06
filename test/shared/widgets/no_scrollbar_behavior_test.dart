/// What the scrollbar-less screens - Home, Explore, the add-on catalogues -
/// look like at the ends of a list.
///
/// Each of them used to carry its own copy of a behaviour built on the bare
/// [ScrollBehavior], which predates Material 3 and gives Android the pre-12
/// glow. Every other screen gets the stretch from [MaterialApp]'s
/// [MaterialScrollBehavior], so the app's three busiest screens were the odd
/// ones out. The shared behaviour keeps the one thing they wanted - no
/// scrollbar - and takes everything else from the Material behaviour.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/shared/widgets/no_scrollbar_behavior.dart';

Widget _list() => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: ScrollConfiguration(
    behavior: const NoScrollbarBehavior(),
    child: ListView(
      children: [for (var i = 0; i < 60; i++) Text('Row $i')],
    ),
  ),
);

void main() {
  testWidgets(
    'Android stretches at the ends of a list instead of glowing',
    (tester) async {
      await tester.pumpWidget(_list());

      expect(find.byType(StretchingOverscrollIndicator), findsOneWidget);
      expect(find.byType(GlowingOverscrollIndicator), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'desktop still gets no scrollbar',
    (tester) async {
      await tester.pumpWidget(_list());

      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byType(RawScrollbar), findsNothing);
    },
    variant: TargetPlatformVariant.desktop(),
  );
}
