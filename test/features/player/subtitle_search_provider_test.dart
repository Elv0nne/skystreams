/// The subtitle search notifier: id -> title -> season fallback chain, the
/// exposed mode, late-result discipline and the repeat-search no-op.
///
/// The three real providers are replaced through `SubtitleSearch.debugProviders`
/// with recording fakes, so nothing here touches Dio.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/entity/subtitle_model.dart';
import 'package:skystream/features/player/presentation/subtitle_search_provider.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

typedef _Call = ({
  String query,
  String? imdbId,
  int? tmdbId,
  int? season,
  int? episode,
  String? language,
  CancelToken? cancelToken,
});

/// Records every `search` call; answers through [respond] (default: empty).
class _RecordingProvider extends SubtitleProvider {
  _RecordingProvider(this.name);

  @override
  final String name;

  @override
  String get idPrefix => name.toLowerCase();

  final List<_Call> calls = [];

  /// Called once per `search` with the 1-based call number.
  Future<List<OnlineSubtitle>> Function(int callNumber, _Call call)? respond;

  /// Snapshot of the notifier at the moment each call arrived (test f).
  void Function(_Call call)? onCall;

  @override
  Future<List<OnlineSubtitle>> search({
    required String query,
    String? imdbId,
    int? tmdbId,
    int? season,
    int? episode,
    String? language,
    CancelToken? cancelToken,
  }) {
    final call = (
      query: query,
      imdbId: imdbId,
      tmdbId: tmdbId,
      season: season,
      episode: episode,
      language: language,
      cancelToken: cancelToken,
    );
    calls.add(call);
    onCall?.call(call);
    return respond?.call(calls.length, call) ?? Future.value(const []);
  }

  @override
  Future<String?> getDownloadUrl(OnlineSubtitle subtitle) async => null;
}

OnlineSubtitle _sub(String id, String source) => OnlineSubtitle(
  id: id,
  name: 'Show.S02E05.$id',
  language: 'en',
  source: source,
  downloadUrl: '',
);

/// Lets the unawaited provider futures and the chained passes run.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _RecordingProvider a;
  late _RecordingProvider b;
  late ProviderContainer container;
  late SubtitleSearch notifier;

  /// Every state the listener saw, paired with `lastMode` read in the same
  /// callback, i.e. what a widget doing `ref.watch` + `ref.read(notifier)`
  /// in one build would see.
  late List<(AsyncValue<List<OnlineSubtitle>?>, SubtitleSearchMode)> seen;

  setUp(() {
    a = _RecordingProvider('A');
    b = _RecordingProvider('B');
    SubtitleSearch.debugProviders = [a, b];
    container = ProviderContainer.test(
      overrides: [
        playerSettingsProvider.overrideWithBuild(
          (_, _) => const PlayerSettings(),
        ),
      ],
    );
    seen = [];
    // Keeps the auto-dispose notifier alive for the whole test.
    container.listen(subtitleSearchProvider, (_, next) {
      seen.add((
        next,
        container.read(subtitleSearchProvider.notifier).lastMode,
      ));
    });
    notifier = container.read(subtitleSearchProvider.notifier);
  });

  tearDown(() {
    SubtitleSearch.debugProviders = null;
  });

  group('(a) ids present', () {
    test(
      'each provider receives imdbId/tmdbId/season/episode; mode byId',
      () async {
        b.respond = (_, _) async => [_sub('1', 'B')];

        await notifier.search(
          query: 'The Show',
          imdbId: 'tt0903747',
          tmdbId: 1396,
          season: 2,
          episode: 5,
          language: 'en',
        );
        await _settle();

        for (final provider in [a, b]) {
          expect(provider.calls, hasLength(1), reason: provider.name);
          final call = provider.calls.single;
          expect(call.query, 'The Show');
          expect(call.imdbId, 'tt0903747');
          expect(call.tmdbId, 1396);
          expect(call.season, 2);
          expect(call.episode, 5);
          expect(call.language, 'en');
          expect(call.cancelToken, isNotNull);
        }
        expect(notifier.lastMode, SubtitleSearchMode.byId);
        final state = container.read(subtitleSearchProvider);
        expect(state.value?.map((s) => s.id), ['1']);
      },
    );

    test('no ids -> mode byTitle and providers get null ids', () async {
      a.respond = (_, _) async => [_sub('1', 'A')];
      await notifier.search(query: 'The Show', language: 'en');
      await _settle();

      expect(a.calls.single.imdbId, isNull);
      expect(a.calls.single.tmdbId, isNull);
      expect(notifier.lastMode, SubtitleSearchMode.byTitle);
    });

    test('language falls back to subtitleLanguageProvider (en)', () async {
      a.respond = (_, _) async => [_sub('1', 'A')];
      await notifier.search(query: 'The Show');
      await _settle();
      expect(a.calls.single.language, 'en');
    });
  });

  group('(b) id miss -> title pass', () {
    test('pass 2 drops ids, keeps query/season/episode/language', () async {
      // A is empty on both passes; B finds something on the title pass only.
      b.respond = (n, call) async =>
          call.imdbId == null ? [_sub('title-hit', 'B')] : const [];

      await notifier.search(
        query: 'The Show',
        imdbId: 'tt0903747',
        tmdbId: 1396,
        season: 2,
        episode: 5,
        language: 'hi',
      );
      await _settle();

      for (final provider in [a, b]) {
        expect(provider.calls, hasLength(2), reason: provider.name);
        final second = provider.calls[1];
        expect(second.imdbId, isNull);
        expect(second.tmdbId, isNull);
        expect(second.query, 'The Show');
        expect(second.season, 2);
        expect(second.episode, 5);
        expect(second.language, 'hi');
      }
      expect(notifier.lastMode, SubtitleSearchMode.byTitleAfterIdMiss);
      expect(container.read(subtitleSearchProvider).value?.map((s) => s.id), [
        'title-hit',
      ]);
    });

    test(
      'an id miss with an empty query has no title pass to fall to',
      () async {
        // Nothing to type-search with; the chain skips straight to the
        // season-only pass, keeping the ids.
        await notifier.search(
          query: '',
          imdbId: 'tt0903747',
          season: 2,
          episode: 5,
        );
        await _settle();

        expect(a.calls, hasLength(2));
        expect(a.calls[1].imdbId, 'tt0903747');
        expect(a.calls[1].season, 2);
        expect(a.calls[1].episode, isNull);
        expect(notifier.lastMode, SubtitleSearchMode.bySeasonAfterEpisodeMiss);
      },
    );
  });

  group('(c) title miss -> season-only pass', () {
    test('pass 3 keeps season, drops episode, then AsyncData([])', () async {
      await notifier.search(
        query: 'The Show',
        imdbId: 'tt0903747',
        season: 2,
        episode: 5,
        language: 'en',
      );
      await _settle();

      expect(a.calls, hasLength(3), reason: 'exactly three passes');
      final third = a.calls[2];
      expect(third.imdbId, isNull);
      expect(third.tmdbId, isNull);
      expect(third.query, 'The Show');
      expect(third.season, 2);
      expect(third.episode, isNull);
      expect(notifier.lastMode, SubtitleSearchMode.bySeasonAfterEpisodeMiss);

      final state = container.read(subtitleSearchProvider);
      expect(state, isA<AsyncData<List<OnlineSubtitle>?>>());
      expect(state.value, isEmpty);
    });

    test(
      'season-only hit is published with mode bySeasonAfterEpisodeMiss',
      () async {
        a.respond = (n, call) async =>
            call.episode == null ? [_sub('pack', 'A')] : const [];

        await notifier.search(
          query: 'The Show',
          imdbId: 'tt0903747',
          season: 2,
          episode: 5,
        );
        await _settle();

        expect(a.calls, hasLength(3));
        expect(notifier.lastMode, SubtitleSearchMode.bySeasonAfterEpisodeMiss);
        expect(container.read(subtitleSearchProvider).value?.map((s) => s.id), [
          'pack',
        ]);
      },
    );

    test('no season -> no pass 3 (film or unknown episode)', () async {
      await notifier.search(
        query: 'The Film',
        imdbId: 'tt0111161',
        language: 'en',
      );
      await _settle();

      expect(a.calls, hasLength(2));
      expect(b.calls, hasLength(2));
      expect(notifier.lastMode, SubtitleSearchMode.byTitleAfterIdMiss);
      final state = container.read(subtitleSearchProvider);
      expect(state, isA<AsyncData<List<OnlineSubtitle>?>>());
      expect(state.value, isEmpty);
    });

    test('episode without season is not enough for a season pass', () async {
      await notifier.search(query: 'The Show', imdbId: 'tt1', episode: 5);
      await _settle();
      expect(a.calls, hasLength(2));
      expect(notifier.lastMode, SubtitleSearchMode.byTitleAfterIdMiss);
    });

    test(
      'title-only search with S/E goes straight to the season pass',
      () async {
        await notifier.search(query: 'The Show', season: 2, episode: 5);
        await _settle();

        expect(a.calls, hasLength(2));
        expect(a.calls[0].episode, 5);
        expect(a.calls[1].episode, isNull);
        expect(a.calls[1].season, 2);
        expect(notifier.lastMode, SubtitleSearchMode.bySeasonAfterEpisodeMiss);
        expect(container.read(subtitleSearchProvider).value, isEmpty);
      },
    );

    test('a hit on pass 1 never widens', () async {
      a.respond = (_, _) async => [_sub('1', 'A')];
      await notifier.search(
        query: 'The Show',
        imdbId: 'tt1',
        season: 2,
        episode: 5,
      );
      await _settle();
      expect(a.calls, hasLength(1));
      expect(b.calls, hasLength(1));
      expect(notifier.lastMode, SubtitleSearchMode.byId);
    });
  });

  group('(d) late results', () {
    test(
      'a pass-1 result arriving after a new search began is discarded',
      () async {
        final late = Completer<List<OnlineSubtitle>>();
        a.respond = (n, call) =>
            n == 1 ? late.future : Future.value(const <OnlineSubtitle>[]);
        b.respond = (n, call) async =>
            call.query == 'Second' ? [_sub('second', 'B')] : const [];

        unawaited(notifier.search(query: 'First', imdbId: 'tt1'));
        await _settle();
        expect(container.read(subtitleSearchProvider).isLoading, isTrue);

        unawaited(notifier.search(query: 'Second', imdbId: 'tt2'));
        await _settle();
        expect(container.read(subtitleSearchProvider).value?.map((s) => s.id), [
          'second',
        ]);

        late.complete([_sub('stale', 'A')]);
        await _settle();

        expect(container.read(subtitleSearchProvider).value?.map((s) => s.id), [
          'second',
        ], reason: 'the stale pass-1 result must not be merged');
        expect(notifier.lastMode, SubtitleSearchMode.byId);
      },
    );

    test(
      'starting pass 2 cancels the pass-1 token and issues a fresh one',
      () async {
        b.respond = (n, call) async =>
            call.imdbId == null ? [_sub('title-hit', 'B')] : const [];

        await notifier.search(query: 'The Show', imdbId: 'tt1');
        await _settle();

        expect(a.calls, hasLength(2));
        expect(a.calls[0].cancelToken!.isCancelled, isTrue);
        expect(a.calls[1].cancelToken!.isCancelled, isFalse);
        expect(a.calls[1].cancelToken, isNot(same(a.calls[0].cancelToken)));
      },
    );

    test('a new search cancels the in-flight pass', () async {
      final never = Completer<List<OnlineSubtitle>>();
      a.respond = (n, call) => n == 1 ? never.future : Future.value(const []);

      unawaited(notifier.search(query: 'First'));
      await _settle();
      unawaited(notifier.search(query: 'Second'));
      await _settle();

      expect(a.calls[0].cancelToken!.isCancelled, isTrue);
      expect(a.calls[1].cancelToken!.isCancelled, isFalse);
    });
  });

  group('(e) repeat search', () {
    test('an identical tuple after completion is a no-op', () async {
      a.respond = (_, _) async => [_sub('1', 'A')];
      await notifier.search(
        query: 'The Show',
        imdbId: 'tt1',
        tmdbId: 2,
        season: 2,
        episode: 5,
        language: 'en',
      );
      await _settle();
      expect(a.calls, hasLength(1));
      final transitions = seen.length;

      await notifier.search(
        query: 'The Show',
        imdbId: 'tt1',
        tmdbId: 2,
        season: 2,
        episode: 5,
        language: 'en',
      );
      await _settle();

      expect(a.calls, hasLength(1), reason: 'no network for a repeat');
      expect(b.calls, hasLength(1));
      expect(seen, hasLength(transitions), reason: 'no state churn either');
      expect(container.read(subtitleSearchProvider).isLoading, isFalse);
    });

    test('an identical tuple that ended empty runs again', () async {
      await notifier.search(query: 'The Film', imdbId: 'tt1');
      await _settle();
      final passes = a.calls.length;
      expect(passes, 2, reason: 'id, then title: the chain ran out');
      expect(container.read(subtitleSearchProvider).value, isEmpty);

      // The sheet's search button is its only Retry, and every provider
      // turns its own network failure into `[]` - so an empty outcome is
      // exactly the one a viewer asks again for, and must reach the network.
      a.respond = (_, _) async => [_sub('1', 'A')];
      await notifier.search(query: 'The Film', imdbId: 'tt1');
      await _settle();

      expect(a.calls, hasLength(passes + 1), reason: 'the retry searched');
      expect(container.read(subtitleSearchProvider).value, hasLength(1));
      expect(container.read(subtitleSearchProvider).value!.single.id, '1');
    });

    test('an identical tuple whose providers all threw runs again', () async {
      // What a dead link really looks like from here: the providers swallow
      // their own errors in production, but even one that throws is caught,
      // counted as complete and ends the chain on `AsyncData([])`. That must
      // not latch, or the button the viewer presses when the link comes back
      // does nothing at all.
      DioException down() => DioException(
        requestOptions: RequestOptions(path: '/subtitles'),
        type: DioExceptionType.connectionError,
        message: 'Network is unreachable',
      );
      a.respond = (_, _) => Future.error(down());
      b.respond = (_, _) => Future.error(down());

      await notifier.search(query: 'The Film', imdbId: 'tt1');
      await _settle();
      final passes = a.calls.length;
      expect(passes, 2);
      expect(
        container.read(subtitleSearchProvider).value,
        isEmpty,
        reason: 'a swallowed failure is indistinguishable from a miss',
      );

      a.respond = (_, _) async => [_sub('1', 'A')];
      b.respond = (_, _) async => const [];
      await notifier.search(query: 'The Film', imdbId: 'tt1');
      await _settle();

      expect(a.calls, hasLength(passes + 1), reason: 'the retry searched');
      expect(container.read(subtitleSearchProvider).value, hasLength(1));
    });

    test('the same query in another language runs again', () async {
      a.respond = (_, _) async => [_sub('1', 'A')];
      await notifier.search(query: 'The Show', imdbId: 'tt1', language: 'en');
      await _settle();
      await notifier.search(query: 'The Show', imdbId: 'tt1', language: 'hi');
      await _settle();
      expect(a.calls, hasLength(2));
      expect(a.calls[1].language, 'hi');
    });

    test('a changed episode runs again', () async {
      a.respond = (_, _) async => [_sub('1', 'A')];
      await notifier.search(query: 'S', imdbId: 'tt1', season: 1, episode: 1);
      await _settle();
      await notifier.search(query: 'S', imdbId: 'tt1', season: 1, episode: 2);
      await _settle();
      expect(a.calls, hasLength(2));
    });

    test(
      'an identical tuple while still loading restarts (not deduped)',
      () async {
        final never = Completer<List<OnlineSubtitle>>();
        a.respond = (n, call) => n == 1 ? never.future : Future.value(const []);

        unawaited(notifier.search(query: 'The Show', imdbId: 'tt1'));
        await _settle();
        unawaited(notifier.search(query: 'The Show', imdbId: 'tt1'));
        await _settle();

        expect(a.calls.length, greaterThanOrEqualTo(2));
        expect(a.calls[0].cancelToken!.isCancelled, isTrue);
      },
    );
  });

  group('(f) lastMode is assigned before state on every pass', () {
    test('listener sees the pass mode with every state it is handed', () async {
      // Pass 1 (ids) and pass 2 (title) miss; pass 3 (season) hits.
      b.respond = (n, call) async =>
          call.episode == null ? [_sub('pack', 'B')] : const [];

      await notifier.search(
        query: 'The Show',
        imdbId: 'tt1',
        season: 2,
        episode: 5,
      );
      await _settle();

      // Equal AsyncLoading writes do not re-notify, so the listener sees the
      // first loading and the final data; both must carry their pass's mode.
      expect(seen.first.$1.isLoading, isTrue);
      expect(seen.first.$2, SubtitleSearchMode.byId);
      expect(seen.last.$1.value?.map((s) => s.id), ['pack']);
      expect(seen.last.$2, SubtitleSearchMode.bySeasonAfterEpisodeMiss);
      for (final (state, mode) in seen) {
        if (state.value?.isNotEmpty ?? false) {
          expect(mode, SubtitleSearchMode.bySeasonAfterEpisodeMiss);
        }
      }
    });

    test(
      'mode is already the pass mode when the providers are called',
      () async {
        final modesAtCall = <SubtitleSearchMode>[];
        final loadingAtCall = <bool>[];
        a.onCall = (_) {
          modesAtCall.add(notifier.lastMode);
          loadingAtCall.add(container.read(subtitleSearchProvider).isLoading);
        };

        await notifier.search(
          query: 'The Show',
          imdbId: 'tt1',
          season: 2,
          episode: 5,
        );
        await _settle();

        expect(modesAtCall, [
          SubtitleSearchMode.byId,
          SubtitleSearchMode.byTitleAfterIdMiss,
          SubtitleSearchMode.bySeasonAfterEpisodeMiss,
        ]);
        expect(loadingAtCall, everyElement(isTrue));
      },
    );

    test(
      'data from a title hit after an id miss carries byTitleAfterIdMiss',
      () async {
        b.respond = (n, call) async =>
            call.imdbId == null ? [_sub('title-hit', 'B')] : const [];
        await notifier.search(query: 'The Show', imdbId: 'tt1');
        await _settle();

        final data = seen.where((s) => s.$1.value?.isNotEmpty ?? false);
        expect(data, isNotEmpty);
        for (final (_, mode) in data) {
          expect(mode, SubtitleSearchMode.byTitleAfterIdMiss);
        }
      },
    );

    test('empty final data carries the mode of the last pass', () async {
      await notifier.search(query: 'The Show', imdbId: 'tt1');
      await _settle();
      final (state, mode) = seen.last;
      expect(state.value, isEmpty);
      expect(mode, SubtitleSearchMode.byTitleAfterIdMiss);
    });
  });

  test('initial mode is byTitle', () {
    expect(notifier.lastMode, SubtitleSearchMode.byTitle);
  });

  test(
    'debugProviders seam: an empty list ends in AsyncData([]) at once',
    () async {
      SubtitleSearch.debugProviders = const [];
      final local = ProviderContainer.test(
        overrides: [
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
        ],
      );
      local.listen(subtitleSearchProvider, (_, _) {});
      await local.read(subtitleSearchProvider.notifier).search(query: 'x');
      await _settle();
      expect(local.read(subtitleSearchProvider).value, isEmpty);
    },
  );
}
