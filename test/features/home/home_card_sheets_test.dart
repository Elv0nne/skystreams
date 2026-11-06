/// The Home rails' long-press menus: over the app's bottom bar, as its dialogs
/// are, and clear of the system's navigation bar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/features/home/presentation/widgets/continue_watching_card.dart';
import 'package:skystream/features/home/presentation/widgets/synced_progress_card.dart';
import 'package:skystream/features/tracking/domain/sync_progress_item.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const Size _screen = Size(412, 915);

/// [card] in a tab of its own under the app's bottom bar, as Home's rails are.
Future<void> _pumpInTab(
  WidgetTester tester,
  Widget card, {
  double systemBar = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _screen;
  tester.view.padding = FakeViewPadding(bottom: systemBar);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          extendBody: true,
          body: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) =>
                  Center(child: SizedBox(width: 280, height: 150, child: card)),
            ),
          ),
          bottomNavigationBar: const ColoredBox(
            key: Key('bottom bar'),
            color: Color(0xFF2196F3),
            child: SizedBox(height: 64, width: double.infinity),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final cards = <String, Widget Function()>{
    'Continue Watching': () => ContinueWatchingCard(
      historyItem: HistoryItem(
        item: MultimediaItem(
          title: 'Test Show',
          url: 'https://example.test/show',
          posterUrl: '',
          contentType: MultimediaContentType.series,
        ),
        position: 15 * 60 * 1000,
        duration: 60 * 60 * 1000,
        season: 2,
        episode: 5,
        timestamp: 0,
      ),
      width: 280,
      isLarge: false,
    ),
    'Synced progress': () => SyncedProgressCard(
      item: SyncProgressItem(
        title: 'Test Show',
        progressPercentage: 25,
        pausedAt: DateTime(2026),
        type: MultimediaContentType.series,
      ),
      width: 280,
      isLarge: false,
      onTap: () {},
    ),
  };

  for (final MapEntry(key: name, value: card) in cards.entries) {
    testWidgets('$name: a long press opens its menu over the bottom bar', (
      tester,
    ) async {
      final widget = card();
      await _pumpInTab(tester, widget);
      await tester.longPress(find.byWidget(widget));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.byKey(const Key('bottom bar')).hitTestable(),
        findsNothing,
        reason: 'under the menu and its barrier',
      );
    });

    testWidgets('$name: its menu clears the system\'s navigation bar', (
      tester,
    ) async {
      final widget = card();
      await _pumpInTab(tester, widget, systemBar: 48);
      await tester.longPress(find.byWidget(widget));
      await tester.pumpAndSettle();

      expect(
        tester.getRect(find.byType(ListTile).last).bottom,
        lessThanOrEqualTo(_screen.height - 48),
      );
    });
  }
}
