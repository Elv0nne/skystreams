/// Continue Watching reopens a Stremio title through the add-on and the type
/// it came from (Stremio direct play): a bridge such as CNCVerse describes a
/// show it published as `other` only on that type, so reopening it as
/// `series`, from no add-on in particular, found nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skystream/core/addons/models/addon_meta.dart'
    show kAddonItemSource;
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/features/home/presentation/widgets/continue_watching_card.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Taps the card for [item] - or holds it and picks View details, with
/// [viaDetails] - and returns where it went.
Future<Uri?> _reopen(
  WidgetTester tester,
  MultimediaItem item, {
  bool viaDetails = false,
}) async {
  Uri? opened;
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 200,
              child: ContinueWatchingCard(
                historyItem: HistoryItem(
                  item: item,
                  position: 10 * 60 * 1000,
                  duration: 60 * 60 * 1000,
                  timestamp: 0,
                ),
                width: 360,
                isLarge: true,
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/addon-detail',
        builder: (_, state) {
          opened = state.uri;
          return const SizedBox.shrink();
        },
      ),
      // A plugin's details page.
      GoRoute(
        path: '/details',
        builder: (_, state) {
          opened = state.uri;
          return const SizedBox.shrink();
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (viaDetails) {
    await tester.longPress(find.byType(ContinueWatchingCard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View Details'));
  } else {
    await tester.tap(find.byType(ContinueWatchingCard));
  }
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  testWidgets('a title an add-on published as `other` reopens as `other`, '
      'through that add-on', (tester) async {
    final opened = await _reopen(
      tester,
      MultimediaItem(
        title: 'Money Heist',
        url: 'cnc:show',
        posterUrl: '',
        contentType: MultimediaContentType.series,
        source: kAddonItemSource,
        addonUrl: 'https://bridge.test/u/a/manifest.json',
        addonType: 'other',
      ),
    );
    expect(opened?.queryParameters, {
      'type': 'other',
      'id': 'cnc:show',
      'addon-url': 'https://bridge.test/u/a/manifest.json',
    });
  });

  testWidgets("View details, on a long press, opens the title's Stremio page "
      'too, not a plugin\'s', (tester) async {
    final opened = await _reopen(
      tester,
      MultimediaItem(
        title: 'Money Heist',
        url: 'cnc:show',
        posterUrl: '',
        contentType: MultimediaContentType.series,
        source: kAddonItemSource,
        addonUrl: 'https://bridge.test/u/a/manifest.json',
        addonType: 'other',
      ),
      viaDetails: true,
    );
    expect(opened?.path, '/addon-detail');
    expect(opened?.queryParameters, {
      'type': 'other',
      'id': 'cnc:show',
      'addon-url': 'https://bridge.test/u/a/manifest.json',
    });
  });

  testWidgets('one saved before then reopens as it always did', (tester) async {
    final opened = await _reopen(
      tester,
      MultimediaItem(
        title: 'Game of Thrones',
        url: 'tt0944947',
        posterUrl: '',
        contentType: MultimediaContentType.series,
        source: kAddonItemSource,
      ),
    );
    expect(opened?.queryParameters, {'type': 'series', 'id': 'tt0944947'});
  });
}
