/// A Stremio show's episodes, laid out as a CloudStream title's are (Stremio
/// direct play): a tap plays the episode from the title's add-on, a long
/// press searches every add-on for it, and each card says how far it was
/// watched.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/addons/presentation/addon_sources_sheet.dart';

import 'stremio_page_fakes.dart';

Finder _card(String title) => find.text(title, skipOffstage: false);

/// The title the open sources sheet plays links for.
MultimediaItem _sheetItem(WidgetTester tester) =>
    tester.widget<AddonSourcesSheet>(find.byType(AddonSourcesSheet)).item;

Future<void> _reach(WidgetTester tester, String title) async {
  await tester.ensureVisible(_card(title));
  await settle(tester);
}

void main() {
  useTestClearance();

  testWidgets('a tap plays the episode from its add-on', (tester) async {
    final opened = await openStremioPage(tester, kBridgeShow);
    await _reach(tester, '2. TWO');
    await tester.tap(_card('2. TWO'));
    await settle(tester);

    final asked = opened.service.asked.where(
      (a) => a.request.videoId == 'cnc:s1e2',
    );
    expect(asked, isNotEmpty);
    expect(
      asked.last.personWaiting,
      isTrue,
      reason: 'someone is waiting: a check that wants a click may open',
    );
    final played = opened.launcher.played.single;
    expect(played.videoUrl, 'cnc:s1e2');
    expect(played.episode?.url, 'cnc:s1e2');
    expect(played.item.addonUrl, kBridgeUrl);
    expect(find.byType(AddonSourcesSheet), findsNothing);
  });

  testWidgets("a tap its add-on has no link for opens every add-on's list", (
    tester,
  ) async {
    final opened = await openStremioPage(
      tester,
      kBridgeShow,
      byVideo: const {'cnc:s1e2': []},
    );
    await _reach(tester, '2. TWO');
    await tester.tap(_card('2. TWO'));
    await settle(tester);

    expect(opened.launcher.played, isEmpty);
    expect(find.byType(AddonSourcesSheet), findsOneWidget);
    expect(_sheetItem(tester).addonUrl, kBridgeUrl);
  });

  testWidgets('a long press searches every add-on for that episode', (
    tester,
  ) async {
    final opened = await openStremioPage(tester, kBridgeShow);
    await _reach(tester, '2. TWO');
    await tester.longPress(_card('2. TWO'));
    await settle(tester);

    expect(find.byType(AddonSourcesSheet), findsOneWidget);
    expect(opened.launcher.played, isEmpty);
    // A link picked there plays with the title still naming its add-on, for
    // Continue Watching.
    expect(_sheetItem(tester).addonUrl, kBridgeUrl);
  });

  testWidgets("the page's add-on search names the add-on that described the "
      'title', (tester) async {
    await openStremioPage(tester, kBridgeMovie, links: const []);
    await tester.tap(find.text('Search Stremio add-ons'));
    await settle(tester);

    expect(_sheetItem(tester).addonUrl, kBridgeUrl);
  });

  testWidgets("without its add-on's links, a tap opens the list as before", (
    tester,
  ) async {
    const described = AddonMeta(
      id: 'tt0944947',
      type: 'series',
      name: 'Game of Thrones',
      addonId: 'com.linvo.cinemeta',
      addonName: 'Cinemeta',
      videos: [
        AddonVideo(
          id: 'tt0944947:1:1',
          title: 'Winter Is Coming',
          season: 1,
          episode: 1,
        ),
        AddonVideo(
          id: 'tt0944947:1:2',
          title: 'The Kingsroad',
          season: 1,
          episode: 2,
        ),
      ],
    );
    final opened = await openStremioPage(tester, described);
    await _reach(tester, '2. THE KINGSROAD');
    await tester.tap(_card('2. THE KINGSROAD'));
    await settle(tester);

    expect(find.byType(AddonSourcesSheet), findsOneWidget);
    expect(opened.launcher.played, isEmpty);
  });

  testWidgets('a card shows how far it was watched, and when it is done', (
    tester,
  ) async {
    await openStremioPage(
      tester,
      kBridgeShow,
      history: FakeHistory(positions: const {'cnc:s1e1': 1800000}),
      watched: const {'cnc:s1e2'},
    );
    final bars = tester.widgetList<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator, skipOffstage: false),
    );
    expect(bars.map((b) => b.value), containsAll(<double>[0.5, 1.0]));
    expect(find.text('WATCHING', skipOffstage: false), findsOneWidget);
    expect(find.text('WATCHED', skipOffstage: false), findsOneWidget);
  });

  testWidgets('a wide page lays episodes side by side', (tester) async {
    await openStremioPage(tester, kBridgeShow);
    expect(
      tester.getTopLeft(_card('2. TWO')).dy,
      tester.getTopLeft(_card('1. ONE')).dy,
    );
  });

  testWidgets('a phone lays them one under another', (tester) async {
    await openStremioPage(tester, kBridgeShow, size: const Size(430, 932));
    expect(
      tester.getTopLeft(_card('2. TWO')).dy,
      greaterThan(tester.getTopLeft(_card('1. ONE')).dy),
    );
  });
}
