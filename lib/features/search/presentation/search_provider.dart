import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:dio/dio.dart';

import '../../../../core/addons/data/addon_client.dart';
import '../../../../core/addons/data/addon_repository.dart';
import '../../../../core/cloudstream/cloudstream_provider.dart';
import '../../../../core/extensions/extension_manager.dart';
import '../../../../core/extensions/base_provider.dart';
import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/network/clearance/clearance.dart';
import '../../../../core/network/clearance/site_checks.dart';
import '../../../../core/nuvio/data/nuvio_repository.dart';
import '../../explore/data/explore_tmdb_provider.dart';
import '../domain/search_fold.dart';
import 'search_sources.dart';

part 'search_provider.g.dart';

enum SearchFilter { content, live }

class ProviderSearchResult {
  final String providerId;
  final String providerName;
  final List<MultimediaItem> results;
  final String? error;

  /// The system the section comes from, which its tag names.
  final SearchSourceKind kind;

  /// Opens the section's results in their own system's pages; null for an
  /// extension's, which open on the details page.
  final SearchSource? source;

  ProviderSearchResult({
    required this.providerId,
    required this.providerName,
    required this.results,
    this.error,
    SearchSourceKind? kind,
    this.source,
  }) : kind =
           kind ??
           source?.kind ??
           (CloudStreamProvider.isCloudStreamId(providerId)
               ? SearchSourceKind.cloudstream
               : SearchSourceKind.skystream);
}

class SearchAggregateState {
  final List<ProviderSearchResult> results;
  final bool isLoading;

  /// When the search began: the bot checks it met are the ones since.
  final DateTime? startedAt;

  /// Extensions searching again because their site's check cleared.
  final Set<String> rerunning;

  /// The searchers this search ran besides the extensions: Stremio add-ons'
  /// and Nuvio's. Their checks show with the extensions'.
  final List<SkyStreamProvider> others;

  const SearchAggregateState({
    this.results = const [],
    this.isLoading = false,
    this.startedAt,
    this.rerunning = const {},
    this.others = const [],
  });
}

// ---------------------------------------------------------------------------
// Background isolate helper — runs title filtering off the main thread.
// ---------------------------------------------------------------------------
class _FilterParams {
  final List<MultimediaItem> items;
  final List<String> queryParts;
  const _FilterParams(this.items, this.queryParts);
}

/// The extension's results that answer the query, in its order: all of them
/// when it answered in other scripts than the query's.
List<MultimediaItem> _filterItems(_FilterParams params) {
  final items = params.items;
  final titles = items.map((item) => item.title);
  if (answeredInOtherScripts(titles, params.queryParts)) return items;
  final query = _QueryWords(params.queryParts);
  return [
    for (final item in items)
      if (query.foundIn(item.title)) item,
  ];
}

final _wordBreak = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);

/// The words of [text] as search compares them: folded by [foldForSearch],
/// then split at anything that is not a letter, a mark or a digit, so a year
/// in brackets ("(1940)") or a hyphenated name ("Spider-Man") is made of
/// words like any other, and a Hindi or Tamil word keeps its vowel signs.
@visibleForTesting
List<String> searchWords(String text) => _words(foldForSearch(text));

List<String> _words(String folded) => [
  for (final word in folded.split(_wordBreak))
    if (word.isNotEmpty) word,
];

/// Whether [title] has every one of [queryWords], the words [searchWords]
/// makes of a query: a word in a script written without spaces anywhere in
/// it, and any other word at the start of one of its words.
@visibleForTesting
bool titleMatches(String title, List<String> queryWords) =>
    _QueryWords(queryWords).foundIn(title);

/// Whether a provider answered a search for [queryWords] in other scripts
/// only: the query has letters, one of [titles] at least has a letter too,
/// and none has a letter in a script the query is written in. A site may
/// answer an Arabic search with Turkish titles ("Tasacak Bu Deniz", issue
/// #36); none of them can show the query's words, so search keeps such an
/// answer as the site sent it. Blank titles or bare years are in no script,
/// and are held to the query's words.
@visibleForTesting
bool answeredInOtherScripts(Iterable<String> titles, List<String> queryWords) {
  final query = queryWords.join(' ');
  final scripts = [
    for (final script in _scripts)
      if (script.hasMatch(query)) script,
  ];
  return scripts.isNotEmpty &&
      titles.any(_letter.hasMatch) &&
      !titles.any((title) => scripts.any((script) => script.hasMatch(title)));
}

final _letter = RegExp(r'\p{L}', unicode: true);

/// A letter of each script search tells apart, as Unicode names them: so
/// Japanese kana and Chinese characters are scripts of their own.
final _scripts = [
  for (final script in const [
    'Latin',
    'Greek',
    'Cyrillic',
    'Armenian',
    'Georgian',
    'Hebrew',
    'Arabic',
    'Syriac',
    'Thaana',
    'Devanagari',
    'Bengali',
    'Gurmukhi',
    'Gujarati',
    'Oriya',
    'Tamil',
    'Telugu',
    'Kannada',
    'Malayalam',
    'Sinhala',
    'Thai',
    'Lao',
    'Tibetan',
    'Myanmar',
    'Khmer',
    'Mongolian',
    'Ethiopic',
    'Hangul',
    'Hiragana',
    'Katakana',
    'Han',
  ])
    RegExp('(?=\\p{L})\\p{Script=$script}', unicode: true),
];

/// A query's words, sorted once for all the titles of a search: those in a
/// script written without spaces between words (Chinese, Japanese, Korean,
/// Thai, Lao, Khmer, Burmese) are found anywhere in a title, across its
/// spaces too; the others have to begin a word of it.
class _QueryWords {
  _QueryWords(List<String> words) {
    for (final word in words) {
      (_unspaced.hasMatch(word) ? _anywhere : _starts).add(word);
    }
  }

  final _anywhere = <String>[];
  final _starts = <String>[];

  bool foundIn(String title) {
    final folded = foldForSearch(title);
    final words = _words(folded);
    if (_anywhere.isNotEmpty) {
      final joined = words.join();
      if (!_anywhere.every(joined.contains)) return false;
    }
    if (_starts.isEmpty) return true;
    _addOtherSpellings(title, folded, words);
    return _starts.every(
      (query) => words.any((word) => word.startsWith(query)),
    );
  }
}

/// A character of a script written without spaces between words.
final _unspaced = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}'
  r'\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}]',
  unicode: true,
);

/// Adds to the [words] of [title], [folded], the other spellings of them a
/// query may use: each run of them that an apostrophe, hyphen, dot, middle
/// dot or zero-width (non-)joiner links, joined ("grey's" is "greys" too,
/// "s.h.i.e.l.d" "shield"); German words with ae, oe and ue for ä, ö and ü;
/// Hindi words with a nasal and virama as written, which [foldForSearch]
/// writes as an anusvara before a consonant, for a word typed up to the
/// nasal ("गेम" of "गेम्स"); and Arabic words without a leading "and" or
/// article.
void _addOtherSpellings(String title, String folded, List<String> words) {
  _addJoined(folded, words);
  if (_umlaut.hasMatch(title)) {
    final spelledOut = foldForSearch(
      title.toLowerCase().replaceAllMapped(
        _umlaut,
        (m) => _umlautSpellings[m[0]![0]]!,
      ),
    );
    words.addAll(_words(spelledOut));
    _addJoined(spelledOut, words);
  }
  for (final spelling in nasalSpellingsForSearch(title)) {
    words.addAll(_words(spelling));
  }
  for (var i = 0, count = words.length; i < count; i++) {
    _addArabicStems(words[i], words);
  }
}

/// Adds to [words] each run of them in [folded] that a joiner links, joined.
void _addJoined(String folded, List<String> words) {
  if (!_joiner.hasMatch(folded)) return;
  for (final run in _joinedRun.allMatches(folded)) {
    final text = run[0]!;
    if (_joiner.hasMatch(text)) words.add(text.replaceAll(_joiner, ''));
  }
}

/// ä, ö or ü, precomposed or written with a combining diaeresis.
final _umlaut = RegExp(
  '[äöü]|[aou]\u{308}',
  caseSensitive: false,
  unicode: true,
);

/// What German writes for an umlaut, by its first letter, lowercased.
const _umlautSpellings = {
  'ä': 'ae',
  'ö': 'oe',
  'ü': 'ue',
  'a': 'ae',
  'o': 'oe',
  'u': 'ue',
};

/// Adds to [words] the Arabic [word] without a leading "and" (و), when it has
/// four letters or more, and without an article (ال, بال, كال, فال, لل) that
/// leaves two letters or more: "وجيري" is "جيري" too, and "والسلام" both
/// "السلام" and "سلام".
void _addArabicStems(String word, List<String> words) {
  final first = word.codeUnitAt(0);
  if (first < 0x0620 || first > 0x064A) return;
  var rest = word;
  if (rest.length >= 4 && rest.codeUnitAt(0) == 0x0648) {
    rest = rest.substring(1);
    words.add(rest);
  }
  for (final article in _arabicArticles) {
    if (rest.startsWith(article) && rest.length - article.length >= 2) {
      words.add(rest.substring(article.length));
      return;
    }
  }
}

const _arabicArticles = [
  '\u{627}\u{644}', // al-
  '\u{628}\u{627}\u{644}', // bi-al-
  '\u{643}\u{627}\u{644}', // ka-al-
  '\u{641}\u{627}\u{644}', // fa-al-
  '\u{644}\u{644}', // li-al-
];

/// What links the parts of one title word, as [foldForSearch] writes it: an
/// apostrophe, backtick, hyphen, dot, middle dot or zero-width (non-)joiner.
const _joiners = "'`\\-.\u{B7}\u{200C}\u{200D}";

final _joiner = RegExp('[$_joiners]');

/// Words and the joiners between them.
final _joinedRun = RegExp(
  '[\\p{L}\\p{M}\\p{N}]+(?:[$_joiners][\\p{L}\\p{M}\\p{N}]+)*',
  unicode: true,
);

/// Searches [manager]'s extensions for [query], with [others] (Stremio
/// add-ons' and Nuvio's searchers) under the content filter.
Stream<SearchAggregateState> searchAllProviders(
  Ref ref,
  String query,
  ExtensionManager manager, {
  required SearchFilter filter,
  required bool Function() isCancelled,
  List<SkyStreamProvider> others = const [],
}) async* {
  final allProviders = manager.getAllProviders();
  final searchers = filter == SearchFilter.content
      ? others
      : const <SkyStreamProvider>[];
  final providers = [
    ...allProviders.where((p) {
      final isLiveOnly =
          p.supportedTypes.isNotEmpty &&
          p.supportedTypes.every((t) => t == ProviderType.livestream);
      return filter == SearchFilter.live ? isLiveOnly : !isLiveOnly;
    }),
    ...searchers,
  ];
  debugPrint(
    '[SEARCH DBG] searchAllProviders called: query="$query", providers=${providers.length}, cancelled=${isCancelled()}',
  );

  final clearance = Clearance.instance;
  final startedAt = clearance.isReady ? clearance.checks.now : DateTime.now();

  if (query.trim().isEmpty || providers.isEmpty) {
    yield SearchAggregateState(
      results: const [],
      isLoading: false,
      startedAt: startedAt,
      others: searchers,
    );
    return;
  }

  yield SearchAggregateState(
    results: const [],
    isLoading: true,
    startedAt: startedAt,
    others: searchers,
  );

  final results = <ProviderSearchResult>[];
  final queryParts = searchWords(query);

  /// The first pass's extensions still to answer: the search is loading until
  /// they have.
  final initial = {for (final p in providers) p.packageName};

  /// Extensions that came back empty or failed: a check that clears later may
  /// be why.
  final empty = <String>{};

  /// Extensions searching again after their site's check cleared.
  final rerunning = <String>{};

  /// The check sources of this search's extensions; `cs3` too when it has
  /// CloudStream ones, for a check the engine couldn't put a name to.
  final sources = {
    for (final p in providers) ?p.checkSource,
    if (providers.any((p) => p.checkSource?.startsWith('cs3:') ?? false)) 'cs3',
  };

  /// Whether a check this search met may still clear, and send its
  /// extensions searching again.
  bool carriesOn() =>
      clearance.isReady &&
      clearance.checks
          .since(startedAt, sources: sources)
          .any((c) => c.pending || c.wantsPerson);

  final controller = StreamController<SearchAggregateState>();

  // Semaphore sizing based on hardware
  int getSemaphoreSize() {
    int maxSlots = 8;
    try {
      final cores = io.Platform.numberOfProcessors;
      if (io.Platform.isMacOS || io.Platform.isWindows || io.Platform.isLinux) {
        maxSlots = 32;
      } else {
        // Mobile: eval burst queue serializes HTTP callbacks, but CF bypass
        // WebView GPU init is still expensive — cap at 8 to avoid triggering
        // too many concurrent CF solves while the spawn semaphore queues them.
        maxSlots = (cores).clamp(4, 8);
      }
    } catch (_) {}
    return maxSlots;
  }

  final maxSlots = getSemaphoreSize();
  int activeJobs = 0;

  /// Jobs holding a slot: an extension's. Add-ons' and Nuvio's searchers do
  /// no extension engine work, only a request or two, so they start at once
  /// and take no slot an extension waits for.
  int activeSlots = 0;
  bool takesSlot(SkyStreamProvider p) => p is! SearchSource;

  // Livestream-only providers (large M3U playlists) are deprioritized to the
  // back of the queue. They still run and IPTV channel searches work; we just
  // let movie/series providers finish their burst first to reduce peak jank.
  final sortedProviders = List<SkyStreamProvider>.from(providers)
    ..sort((a, b) {
      final aLiveOnly =
          a.supportedTypes.isNotEmpty &&
          a.supportedTypes.every((t) => t == ProviderType.livestream);
      final bLiveOnly =
          b.supportedTypes.isNotEmpty &&
          b.supportedTypes.every((t) => t == ProviderType.livestream);
      if (aLiveOnly == bLiveOnly) return 0;
      return aLiveOnly ? 1 : -1;
    });
  final queue = List<SkyStreamProvider>.from(sortedProviders);
  final List<CancelToken> activeTokens = [];
  final List<SkyStreamProvider> activeProviders = [];
  bool isCompleted = false;
  StreamSubscription<void>? cleared;

  Timer? throttleTimer;
  bool pendingEmit = false;
  // Track what was last emitted so we skip rebuilds when nothing new arrived.
  int lastEmittedResultCount = 0;

  void doEmit({bool force = false}) {
    if (controller.isClosed || isCancelled()) {
      return;
    }
    // Only the first pass loads: an extension searching again shows in its
    // site's row, not as the whole search loading.
    final stillLoading = initial.isNotEmpty;
    // Skip the rebuild if no new results have arrived since the last emit
    // (e.g. a batch of providers all returned empty). Always emit on the
    // final event so isLoading flips to false.
    if (!force && stillLoading && results.length == lastEmittedResultCount) {
      pendingEmit = false;
      return;
    }
    lastEmittedResultCount = results.length;
    final totalItems = results.fold<int>(0, (sum, r) => sum + r.results.length);
    debugPrint(
      '[SEARCH DBG] doEmit — ${results.length} providers, $totalItems items, loading=$stillLoading',
    );
    controller.add(
      SearchAggregateState(
        results: List.from(results),
        isLoading: stillLoading,
        startedAt: startedAt,
        rerunning: Set.of(rerunning),
        others: searchers,
      ),
    );
    pendingEmit = false;
  }

  void scheduleEmit({bool force = false}) {
    if (isCancelled() || controller.isClosed) return;

    if (force) {
      throttleTimer?.cancel();
      throttleTimer = null;
      doEmit(force: true);
      return;
    }

    pendingEmit = true;
    // Mobile gets a wider throttle window to reduce rebuild frequency
    // during high-concurrency search phases (70 providers).
    final throttleDuration = (io.Platform.isAndroid || io.Platform.isIOS)
        ? const Duration(milliseconds: 500)
        : const Duration(milliseconds: 150);
    throttleTimer ??= Timer(throttleDuration, () {
      throttleTimer = null;
      if (pendingEmit) doEmit();
    });
  }

  void processNext() {
    if (isCancelled()) {
      for (final t in activeTokens) {
        if (!t.isCancelled) t.cancel('Search cancelled');
      }
      activeTokens.clear();
      // Drop any IIFE evals still waiting in the JS queue for active providers.
      for (final p in activeProviders) {
        p.cancelInit();
      }
      activeProviders.clear();
      return;
    }

    // Fill up to max slots; searchers start whatever the slots.
    while (queue.isNotEmpty) {
      final next = queue.indexWhere(
        (p) => !takesSlot(p) || activeSlots < maxSlots,
      );
      if (next < 0) break;
      final provider = queue.removeAt(next);
      activeJobs++;
      if (takesSlot(provider)) activeSlots++;
      final token = CancelToken();
      activeTokens.add(token);
      activeProviders.add(provider);

      Future(() async {
        if (isCancelled() || token.isCancelled) {
          debugPrint(
            '[SEARCH DBG] SKIP ${provider.packageName} — cancelled before start',
          );
          return;
        }

        try {
          debugPrint('[SEARCH DBG] START ${provider.packageName}');
          final rawResults = await provider.search(query, cancelToken: token);
          debugPrint(
            '[SEARCH DBG] DONE ${provider.packageName} — rawResults=${rawResults.length}',
          );
          if (isCancelled() || token.isCancelled) {
            debugPrint(
              '[SEARCH DBG] CANCELLED after search ${provider.packageName}',
            );
            return;
          }

          final source = provider is SearchSource
              ? provider as SearchSource
              : null;
          // A searcher's results keep their own fields (ids, kind, source):
          // they open in their own system's pages.
          final providerItems = source != null
              ? rawResults
              : rawResults
                    .map(
                      (item) => MultimediaItem(
                        title: item.title,
                        url: item.url,
                        posterUrl: item.posterUrl,
                        bannerUrl: item.bannerUrl,
                        description: item.description,
                        contentType: item.contentType,
                        episodes: item.episodes,
                        provider: provider.packageName,
                      ),
                    )
                    .toList();

          // For small result sets, skip the compute() isolate overhead
          // (spawn + serialize + deserialize costs more than the filter work).
          // A searcher's results are matched and ranked by its own system
          // (TMDB, the add-on): accents, years and people included.
          final filtered = source != null
              ? providerItems
              : providerItems.length < 30
              ? _filterItems(_FilterParams(providerItems, queryParts))
              : await compute(
                  _filterItems,
                  _FilterParams(providerItems, queryParts),
                );
          debugPrint(
            '[SEARCH DBG] FILTERED ${provider.packageName} — ${filtered.length}/${providerItems.length} items',
          );

          if (isCancelled() || token.isCancelled) {
            debugPrint(
              '[SEARCH DBG] CANCELLED after filter ${provider.packageName}',
            );
            return;
          }

          // Only add to state when there are actual results — empty entries
          // grow the list, force larger List.from() copies in doEmit, and
          // cause needless ListView rebuilds for no visual change.
          if (filtered.isNotEmpty) {
            // A search again replaces what the extension found before.
            results.removeWhere((r) => r.providerId == provider.packageName);
            empty.remove(provider.packageName);
            results.add(
              ProviderSearchResult(
                providerId: provider.packageName,
                providerName: provider.name,
                results: filtered,
                source: source,
              ),
            );
            debugPrint(
              '[SEARCH DBG] ADDED ${provider.packageName} — total results sets=${results.length}',
            );
          } else {
            empty.add(provider.packageName);
          }
        } catch (e) {
          debugPrint('[SEARCH DBG] ERROR ${provider.packageName}: $e');
          if (isCancelled() || token.isCancelled) {
            debugPrint(
              '[SEARCH DBG] CANCELLED during error ${provider.packageName}',
            );
            return;
          }
          if (e is DioException && e.type == DioExceptionType.cancel) return;
          // Don't add error entries with empty results — they add state size
          // with no user-visible benefit.
          empty.add(provider.packageName);
        } finally {
          activeJobs--;
          if (takesSlot(provider)) activeSlots--;
          activeTokens.remove(token);
          activeProviders.remove(provider);
          final wasRerun = rerunning.remove(provider.packageName);
          initial.remove(provider.packageName);

          final isLast = initial.isEmpty && activeJobs == 0 && queue.isEmpty;
          debugPrint(
            '[SEARCH DBG] FINALLY ${provider.packageName} — activeJobs=$activeJobs, queueLeft=${queue.length}, isLast=$isLast, cancelled=${isCancelled()}, controllerClosed=${controller.isClosed}',
          );
          scheduleEmit(force: isLast || wasRerun);

          if (isLast && !isCompleted) {
            isCompleted = true;
            debugPrint(
              '[SEARCH DBG] ALL DONE — total result sets=${results.length}',
            );
            manager.runGC();
          }
          // Kept open while a check this search met may still clear and send
          // its extensions searching again.
          if (isLast && !carriesOn() && !controller.isClosed) {
            unawaited(cleared?.cancel());
            unawaited(
              Future.microtask(() {
                if (!controller.isClosed) controller.close();
              }),
            );
          } else if (!isCancelled()) {
            processNext();
          }
        }
      });
    }
  }

  // A check this search met that clears sends the extensions that met it, and
  // came back empty, searching again: their results take their place.
  final handled = <String>{};
  if (clearance.isReady) {
    cleared = clearance.checks.changes.listen((_) {
      if (isCancelled()) {
        unawaited(cleared?.cancel());
        return;
      }
      for (final check in clearance.checks.since(startedAt, sources: sources)) {
        if (check.state != CheckState.cleared) continue;
        if (!handled.add('${check.site} ${check.since}')) continue;
        for (final p in providers) {
          final id = p.packageName;
          if (!check.metBy(p.checkSource) ||
              !empty.contains(id) ||
              rerunning.contains(id) ||
              activeProviders.contains(p) ||
              queue.contains(p)) {
            continue;
          }
          rerunning.add(id);
          queue.add(p);
        }
      }
      if (rerunning.isNotEmpty) {
        scheduleEmit(force: true);
        processNext();
      } else if (initial.isEmpty &&
          activeJobs == 0 &&
          queue.isEmpty &&
          !carriesOn() &&
          !controller.isClosed) {
        // Every extension has answered, and no check it met can still clear.
        unawaited(cleared?.cancel());
        unawaited(controller.close());
      }
    });
  }
  controller.onCancel = () {
    unawaited(cleared?.cancel());
    // A newer search took its place: its requests stop now, not when one of
    // them next finishes.
    for (final token in activeTokens) {
      if (!token.isCancelled) token.cancel('Search replaced');
    }
  };

  processNext();

  yield* controller.stream;
}

@Riverpod(keepAlive: true)
class SearchQuery extends _$SearchQuery {
  @override
  String build() => '';

  void set(String query) => state = query;
}

@Riverpod(keepAlive: true)
class SearchFilterNotifier extends _$SearchFilterNotifier {
  @override
  SearchFilter build() => SearchFilter.content;

  void set(SearchFilter filter) => state = filter;
}

@Riverpod(keepAlive: true)
Stream<SearchAggregateState> searchResults(Ref ref) {
  final query = ref.watch(searchQueryProvider);
  final filter = ref.watch(searchFilterProvider);
  final manager = ref.read(extensionManagerProvider.notifier);

  debugPrint('[SEARCH DBG] searchResults PROVIDER BUILT — query="$query"');

  var cancelled = false;
  ref.onDispose(() {
    debugPrint('[SEARCH DBG] searchResults DISPOSED — query="$query"');
    cancelled = true;
  });

  return searchAllProviders(
    ref,
    query,
    manager,
    filter: filter,
    isCancelled: () => cancelled,
    others: filter == SearchFilter.content
        ? searchSources(
            addons: ref.read(addonRepositoryProvider).enabled,
            client: ref.read(addonClientProvider),
            nuvioActive: ref
                .read(nuvioRepositoryProvider)
                .activeScrapers
                .isNotEmpty,
            tmdb: ref.read(tmdbServiceProvider),
          )
        : const [],
  );
}

class SearchSuggestionState {
  final List<String> suggestions;
  final bool isLoading;
  final String query;

  const SearchSuggestionState({
    this.suggestions = const [],
    this.isLoading = false,
    this.query = '',
  });

  SearchSuggestionState copyWith({
    List<String>? suggestions,
    bool? isLoading,
    String? query,
  }) {
    return SearchSuggestionState(
      suggestions: suggestions ?? this.suggestions,
      isLoading: isLoading ?? this.isLoading,
      query: query ?? this.query,
    );
  }
}

@riverpod
class SearchSuggestionController extends _$SearchSuggestionController {
  Timer? _debounce;

  @override
  SearchSuggestionState build() {
    ref.onDispose(() {
      _debounce?.cancel();
    });
    return const SearchSuggestionState();
  }

  void onQueryChanged(String query) {
    if (query == state.query) return;

    final trimmed = query.trim();
    if (trimmed.length < 2) {
      _debounce?.cancel();
      state = state.copyWith(
        query: query,
        suggestions: const [],
        isLoading: false,
      );
      return;
    }

    state = state.copyWith(query: query, isLoading: true);

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final tmdb = ref.read(tmdbServiceProvider);
        final suggestions = await tmdb.getSuggestions(
          query: query,
          language: 'en-US',
        );
        if (state.query == query) {
          state = state.copyWith(suggestions: suggestions, isLoading: false);
        }
      } catch (_) {
        if (state.query == query) {
          state = state.copyWith(suggestions: const [], isLoading: false);
        }
      }
    });
  }

  void clear() {
    _debounce?.cancel();
    state = const SearchSuggestionState();
  }
}
