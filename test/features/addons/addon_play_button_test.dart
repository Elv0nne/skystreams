/// A Stremio title's Play button (Stremio direct play): there once the add-on
/// that described the title answered with a link it can play, like a
/// CloudStream title's Play, and nowhere else. The search over every add-on
/// stays beside it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/addons/presentation/addon_sources_sheet.dart';

import 'stremio_page_fakes.dart';

void main() {
  useTestClearance();

  for (final (layout, size) in [
    ('a large layout', const Size(1920, 1080)),
    ('a phone', const Size(430, 932)),
  ]) {
    testWidgets("on $layout, a movie's Play shows once its add-on has a link, "
        'beside the search over every add-on', (tester) async {
      await openStremioPage(tester, kBridgeMovie, size: size);
      expect(find.text('Play', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Search Stremio add-ons', skipOffstage: false),
        findsOneWidget,
      );
    });
  }

  testWidgets('no Play while its links load', (tester) async {
    await openStremioPage(tester, kBridgeMovie, hold: true);
    expect(find.text('Play'), findsNothing);
    expect(find.text('Search Stremio add-ons'), findsOneWidget);
  });

  testWidgets('no Play when its add-on has nothing that plays here', (
    tester,
  ) async {
    await openStremioPage(tester, kBridgeMovie, links: const [kDonate]);
    expect(find.text('Play'), findsNothing);
  });

  testWidgets('no Play for a title its add-on only describes', (tester) async {
    const described = AddonMeta(
      id: 'tt1',
      type: 'movie',
      name: 'Film',
      addonId: 'com.linvo.cinemeta',
      addonName: 'Cinemeta',
    );
    final opened = await openStremioPage(tester, described);
    expect(find.text('Play'), findsNothing);
    expect(opened.service.asked, isEmpty, reason: 'there was nobody to ask');
  });

  testWidgets('Resume, with saved progress', (tester) async {
    await openStremioPage(
      tester,
      kBridgeMovie,
      history: FakeHistory(positions: const {'cnc:film': 600000}),
    );
    expect(find.text('Resume'), findsOneWidget);
  });

  testWidgets("a movie's Play plays its add-on's link at once", (tester) async {
    final opened = await openStremioPage(tester, kBridgeMovie);
    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final played = opened.launcher.played.single;
    expect(played.videoUrl, 'cnc:film');
    expect(played.episode, isNull);
    expect(played.streams.first.url, 'https://cdn.test/a.m3u8');
    expect(played.item.addonUrl, kBridgeUrl);
    expect(played.item.addonType, 'other');
    expect(played.item.contentType, MultimediaContentType.movie);
  });

  testWidgets("a show's Play names the next episode and plays it from its "
      'add-on, with the episode list for the next one', (tester) async {
    final opened = await openStremioPage(
      tester,
      kBridgeShow,
      history: FakeHistory(lastEpisode: 'cnc:s1e1'),
      watched: const {'cnc:s1e1'},
    );
    expect(find.text('Play S1 E2'), findsOneWidget);
    expect(opened.service.asked.last.request.videoId, 'cnc:s1e2');

    await tester.tap(find.text('Play S1 E2'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final played = opened.launcher.played.single;
    expect(played.videoUrl, 'cnc:s1e2');
    expect(played.episode?.url, 'cnc:s1e2');
    expect(played.streams.first.url, 'https://cdn.test/a.m3u8');
    expect(played.item.addonUrl, kBridgeUrl);
    expect(played.item.addonType, 'other');
    expect(played.item.contentType, MultimediaContentType.series);
    expect(played.item.episodes?.map((e) => e.url), [
      'cnc:s1e1',
      'cnc:s1e2',
      'cnc:s2e1',
    ]);
  });

  testWidgets('a show not started plays its first episode', (tester) async {
    await openStremioPage(tester, kBridgeShow);
    expect(find.text('Play S1 E1'), findsOneWidget);
  });

  testWidgets('a show published as `other` says which episode its search is '
      'for', (tester) async {
    // It asked for the first episode, but was labelled as a film's search.
    await openStremioPage(tester, kBridgeShow, links: const []);
    expect(find.text('Search add-ons: S1 E1'), findsOneWidget);
  });

  group('pressed a while after it showed', () {
    const fresh = AddonStreamSource(
      addonId: 'com.bridge',
      addonName: 'Bridge',
      url: 'https://cdn.test/fresh.m3u8',
      name: 'Auto',
    );

    testWidgets('Play asks its add-on again and plays what it answers now: '
        'a link from earlier may have expired', (tester) async {
      final opened = await openStremioPage(tester, kBridgeMovie);
      opened.service.links = const [fresh];
      await tester.tap(find.text('Play'));
      await settle(tester);

      expect(opened.service.asked.last.personWaiting, isTrue);
      final played = opened.launcher.played.single;
      expect(played.streams.first.url, 'https://cdn.test/fresh.m3u8');
    });

    testWidgets('when the add-on has nothing now, Play plays the links it '
        'had', (tester) async {
      final opened = await openStremioPage(tester, kBridgeMovie);
      opened.service.links = const [];
      await tester.tap(find.text('Play'));
      await settle(tester);

      final played = opened.launcher.played.single;
      expect(played.streams.first.url, 'https://cdn.test/a.m3u8');
    });
  });

  testWidgets('on TV, back from the player the remote is on Play again', (
    tester,
  ) async {
    await openStremioPage(tester, kBridgeMovie, opensPlayer: true);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'stremio play');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.text('PLAYER'), findsOneWidget);

    Navigator.of(tester.element(find.text('PLAYER'))).pop();
    await settle(tester);
    expect(find.text('PLAYER'), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'stremio play');
  });

  testWidgets('on TV, Play showing under an open sheet leaves the remote in '
      'the sheet', (tester) async {
    final gate = Completer<void>();
    await openStremioPage(
      tester,
      kBridgeMovie,
      gate: gate.future,
      holdWaiting: true,
    );
    expect(find.text('Play'), findsNothing);

    // OK on the page's start, the add-on search: its sheet opens and asks.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    final sheet = find.byType(AddonSourcesSheet);
    expect(sheet, findsOneWidget);

    // The page's own ask answers: Play shows under the sheet.
    gate.complete();
    await settle(tester);
    expect(find.text('Play', skipOffstage: false), findsOneWidget);

    final primary = FocusManager.instance.primaryFocus;
    expect(primary?.debugLabel, isNot('stremio play'));
    expect(
      ModalRoute.of(primary!.context!),
      same(ModalRoute.of(tester.element(sheet))),
      reason: 'the remote stays in the sheet the viewer opened',
    );
  });

  testWidgets('on TV, the remote moves to Play when it shows', (tester) async {
    await openStremioPage(tester, kBridgeMovie);
    final node = FocusManager.instance.primaryFocus;
    final holder = node is FocusScopeNode ? null : node?.context?.widget;
    expect(holder, isNotNull);
    expect(
      find.descendant(of: find.byWidget(holder!), matching: find.text('Play')),
      findsOneWidget,
    );
  });
}
