import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/explore_tmdb_provider.dart';
import '../../data/explore_mode_provider.dart';
import '../../data/anilist_repository.dart';
import '../../data/explore_filter_provider.dart';
import '../../../addons/presentation/addon_providers.dart';
import '../../../../core/addons/data/addon_repository.dart';
import '../../../../core/addons/models/addon_meta.dart';
import '../../../../core/domain/entity/multimedia_item.dart';

part 'explore_search_controller.g.dart';

/// The [MultimediaItem.url] of an add-on search result: the type the add-on
/// listed the title as, its id, and the add-on's manifest, so that it opens
/// where it came from. Type and id are escaped - `cnc:…` and `kitsu:…` ids
/// have colons in them.
String addonSearchItemUrl({
  required String type,
  required String id,
  String? addonUrl,
}) =>
    'addon:${Uri.encodeComponent(type)}:${Uri.encodeComponent(id)}:'
    '${addonUrl ?? ''}';

/// Reads an [addonSearchItemUrl] back; null for any other url.
({String type, String id, String? addonUrl})? parseAddonSearchItemUrl(
  String url,
) {
  if (!url.startsWith('addon:')) return null;
  final parts = url.substring('addon:'.length).split(':');
  if (parts.length < 3) return null;
  final addonUrl = parts.skip(2).join(':');
  return (
    type: Uri.decodeComponent(parts[0]),
    id: Uri.decodeComponent(parts[1]),
    addonUrl: addonUrl.isEmpty ? null : addonUrl,
  );
}

class ExploreSearchState {
  final List<MultimediaItem> suggestions;
  final List<MultimediaItem> results;
  final bool isLoading;

  /// What is in the search field: it moves with every keystroke.
  final String query;

  /// The search [results] were asked for. Not [query]: that has moved on to
  /// the next search by the time it is submitted.
  final String resultsQuery;
  final int page;
  final bool hasMore;

  const ExploreSearchState({
    this.suggestions = const [],
    this.results = const [],
    this.isLoading = false,
    this.query = '',
    this.resultsQuery = '',
    this.page = 1,
    this.hasMore = true,
  });

  ExploreSearchState copyWith({
    List<MultimediaItem>? suggestions,
    List<MultimediaItem>? results,
    bool? isLoading,
    String? query,
    String? resultsQuery,
    int? page,
    bool? hasMore,
  }) {
    return ExploreSearchState(
      suggestions: suggestions ?? this.suggestions,
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      query: query ?? this.query,
      resultsQuery: resultsQuery ?? this.resultsQuery,
      page: page ?? this.page,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

@riverpod
class ExploreSearchController extends _$ExploreSearchController {
  Timer? _debounce;

  @override
  ExploreSearchState build() {
    ref.onDispose(() {
      _debounce?.cancel();
    });
    return const ExploreSearchState();
  }

  void onQueryChanged(String query) {
    if (query == state.query) return;

    if (query.trim().isEmpty) {
      _debounce?.cancel();
      state = state.copyWith(query: query, suggestions: [], isLoading: false);
      return;
    }

    state = state.copyWith(query: query, isLoading: true);

    if (_debounce?.isActive ?? false) _debounce!.cancel();

    _debounce = Timer(const Duration(milliseconds: 500), () async {
      try {
        final mode = ref.read(exploreModeProvider);
        final List<MultimediaItem> results;
        if (mode == ExploreModeType.anime) {
          final anilist = ref.read(anilistRepositoryProvider);
          final titleLang = ref.read(animeTitleLanguageProvider);
          results = await anilist.searchAnime(query, titleLang: titleLang);
        } else if (mode == ExploreModeType.stremio) {
          final previews = await ref.read(addonSearchProvider(query).future);
          results = _addonItems(previews);
        } else {
          final tmdb = ref.read(tmdbServiceProvider);
          results = await tmdb.multiSearch(query: query, language: 'en-US');
        }

        if (state.query == query) {
          state = state.copyWith(
            suggestions: results.take(10).toList(),
            isLoading: false,
          );
        }
      } catch (e) {
        if (state.query == query) {
          state = state.copyWith(isLoading: false);
        }
      }
    });
  }

  Future<void> fetchResults(String query) async {
    if (query == state.resultsQuery && state.results.isNotEmpty) return;

    state = state.copyWith(
      query: query,
      resultsQuery: query,
      results: const [],
      isLoading: true,
      page: 1,
      hasMore: true,
    );

    try {
      final mode = ref.read(exploreModeProvider);
      final List<MultimediaItem> results;
      if (mode == ExploreModeType.anime) {
        final anilist = ref.read(anilistRepositoryProvider);
        final titleLang = ref.read(animeTitleLanguageProvider);
        results = await anilist.searchAnime(
          query,
          page: 1,
          titleLang: titleLang,
        );
      } else if (mode == ExploreModeType.stremio) {
        final previews = await ref.read(addonSearchProvider(query).future);
        results = _addonItems(previews);
      } else {
        final tmdb = ref.read(tmdbServiceProvider);
        results = await tmdb.multiSearch(
          query: query,
          language: 'en-US',
          page: 1,
        );
      }

      if (state.resultsQuery == query) {
        state = state.copyWith(
          results: results,
          isLoading: false,
          hasMore: mode != ExploreModeType.stremio && results.isNotEmpty,
        );
      }
    } catch (e) {
      if (state.resultsQuery == query) {
        state = state.copyWith(isLoading: false);
      }
    }
  }

  Future<void> fetchNextPage() async {
    if (state.isLoading || !state.hasMore) return;

    final mode = ref.read(exploreModeProvider);
    if (mode == ExploreModeType.stremio) {
      state = state.copyWith(hasMore: false, isLoading: false);
      return;
    }

    state = state.copyWith(isLoading: true);

    try {
      final nextPage = state.page + 1;
      final List<MultimediaItem> results;
      if (mode == ExploreModeType.anime) {
        final anilist = ref.read(anilistRepositoryProvider);
        final titleLang = ref.read(animeTitleLanguageProvider);
        results = await anilist.searchAnime(
          state.resultsQuery,
          page: nextPage,
          titleLang: titleLang,
        );
      } else {
        final tmdb = ref.read(tmdbServiceProvider);
        results = await tmdb.multiSearch(
          query: state.resultsQuery,
          language: 'en-US',
          page: nextPage,
        );
      }

      if (results.isEmpty) {
        state = state.copyWith(hasMore: false, isLoading: false);
      } else {
        state = state.copyWith(
          results: [...state.results, ...results],
          page: nextPage,
          isLoading: false,
        );
      }
    } catch (e) {
      state = state.copyWith(isLoading: false);
    }
  }

  /// A plain item keeps neither the add-on that listed a title nor the type it
  /// listed it as: a CNCVerse `other` opened as a `movie`, asked of every
  /// add-on in turn, and the bridge's slow description of it was cut off.
  List<MultimediaItem> _addonItems(List<AddonMetaPreview> previews) {
    final addons = ref.read(addonRepositoryProvider).enabled;
    return [
      for (final preview in previews)
        preview.toMultimediaItem().copyWith(
          url: addonSearchItemUrl(
            type: preview.type,
            id: preview.id,
            addonUrl: addons
                .where((addon) => addon.id == preview.addonId)
                .firstOrNull
                ?.manifestUrl,
          ),
        ),
    ];
  }

  void clearSearch() {
    _debounce?.cancel();
    state = const ExploreSearchState();
  }
}
