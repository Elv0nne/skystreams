/// Watch history keeps where a Stremio title came from: the add-on that
/// described it and the type it published the title as. Continue Watching
/// reopens the title through them, and without them it took the title to a
/// plugin's details page, whose provider has never heard of a `cnc:` id.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skystream/core/addons/models/addon_meta.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/history_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late HistoryRepository history;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('history_addon_item');
    Hive.init(dir.path);
    final storage = StorageService();
    await storage.initHistory();
    history = HistoryRepository(storage);
  });

  tearDown(() async {
    await Hive.close();
    dir.deleteSync(recursive: true);
  });

  final show = AddonMeta.fromJson(
    {
      'id': 'cnc:show',
      'type': 'other',
      'name': 'Money Heist',
      'videos': [
        {'id': 'cnc:s1e1', 'title': 'One', 'season': 1, 'episode': 1},
        {'id': 'cnc:s1e2', 'title': 'Two', 'season': 1, 'episode': 2},
      ],
    },
    addonId: 'com.bridge',
    addonName: 'Bridge',
  ).toMultimediaItem(addonUrl: 'https://bridge.test/manifest.json');

  test(
    'a Stremio show comes back with its add-on and published type',
    () async {
      await history.saveProgress(
        show,
        60000,
        3600000,
        lastEpisodeUrl: 'cnc:s1e1',
        season: 1,
        episode: 1,
      );

      final back = history.getWatchHistory().single.item;
      expect(back.source, kAddonItemSource);
      expect(back.addonUrl, 'https://bridge.test/manifest.json');
      expect(back.addonType, 'other');
      expect(back.contentType, MultimediaContentType.series);
    },
  );

  test('a resumed position keeps them', () async {
    await history.saveProgress(
      show,
      60000,
      3600000,
      lastEpisodeUrl: 'cnc:s1e1',
      season: 1,
      episode: 1,
    );
    await history.updateHistoryItemTimestampAndPosition(
      history.getWatchHistory().single,
      DateTime.now().millisecondsSinceEpoch,
      90000,
    );

    final back = history.getWatchHistory().single;
    expect(back.position, 90000);
    expect(back.item.source, kAddonItemSource);
    expect(back.item.addonUrl, 'https://bridge.test/manifest.json');
    expect(back.item.addonType, 'other');
  });

  test('a plugin title has none of them', () async {
    await history.saveProgress(
      MultimediaItem(
        title: 'A film',
        url: 'https://plugin.test/film',
        posterUrl: '',
        provider: 'Plugin',
      ),
      60000,
      3600000,
    );

    final back = history.getWatchHistory().single.item;
    expect(back.source, isNull);
    expect(back.addonUrl, isNull);
    expect(back.addonType, isNull);
    expect(back.provider, 'Plugin');
  });
}
