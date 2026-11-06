/// A title's own tracker ids against a lookup's (CloudStream details, Part 1's
/// review): an extension's MAL and AniList ids name the season it is, where
/// Simkl's lookup by IMDb or TMDB id names the series, so its ids only fill
/// the gaps. A multi-season anime otherwise had the first season's entry
/// written to.
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/secure_token_storage.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/tracking/data/simkl_service.dart';
import 'package:skystream/features/tracking/data/sync_manager.dart';
import 'package:skystream/features/tracking/data/sync_outbox.dart';
import 'package:skystream/features/tracking/data/tracking_service.dart';
import 'package:skystream/features/tracking/domain/sync_ids.dart';

/// No tokens, and no platform storage behind them.
class _NoTokens extends SecureTokenStorage {
  _NoTokens() : super(StorageService());

  @override
  Future<String?> read(String key) async => null;
}

/// Simkl's lookup, answering [ids]; signed out, so it is asked for ids only.
class _LookupSimkl extends SimklService {
  _LookupSimkl(this.ids) : super(Dio(), _NoTokens());

  final Map<String, String> ids;

  @override
  Future<bool> get isLoggedIn async => false;

  @override
  Future<Map<String, String>> syncIds(MultimediaItem item) async => ids;
}

/// A signed-in MAL that records the ids it was handed.
class _RecordingMal extends Fake implements TrackingService {
  Map<String, String>? ids;

  @override
  String get idPrefix => 'mal';

  @override
  String get name => 'MAL';

  @override
  Future<bool> get isLoggedIn async => true;

  @override
  Future<bool> markWatched(
    MultimediaItem item,
    Episode? episode, {
    Map<String, String>? resolvedIds,
  }) async {
    ids = resolvedIds;
    return true;
  }
}

void main() {
  test("a title's own ids win; a lookup's fill the gaps", () {
    expect(
      withLookedUpIds(
        {'mal': '52991', 'anilist': '154587'},
        {'mal': '1', 'anilist': '2', 'simkl': '9'},
      ),
      {'mal': '52991', 'anilist': '154587', 'simkl': '9'},
    );
    expect(withLookedUpIds(null, {'simkl': '9'}), {'simkl': '9'});
  });

  test(
    "a tracker gets the season's MAL id, not Simkl's series-level one",
    () async {
      final mal = _RecordingMal();
      final manager = SyncManager([
        _LookupSimkl({'simkl': '9', 'mal': '1', 'anilist': '2'}),
        mal,
      ]);
      final season2 = MultimediaItem(
        title: 'Frieren Season 2',
        url: 'https://ext.test/frieren-2',
        posterUrl: '',
        contentType: MultimediaContentType.anime,
        imdbId: 'tt22248376',
        syncData: const {'mal': '59978', 'anilist': '182255'},
      );
      await manager.dispatch(SyncOp.markWatched, season2, null, 1.0, const {});
      expect(mal.ids, {'mal': '59978', 'anilist': '182255', 'simkl': '9'});
    },
  );
}
