import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../../core/addons/data/addon_client.dart';
import '../../../core/addons/data/addon_stream_service.dart';
import '../../../core/addons/data/builtin_addons.dart';
import '../../../core/addons/models/addon_manifest.dart';
import '../../../core/addons/models/addon_meta.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/base_provider.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/tmdb_service.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../addons/presentation/addon_providers.dart';
import '../../details/presentation/widgets/episode_picker_sheet.dart';
import '../../sources/presentation/plugin_sources_sheet.dart';

/// The system a search section comes from, which its tag names.
enum SearchSourceKind { skystream, cloudstream, stremio, nuvio }

/// A searcher whose results open in its own system's pages, not SkyStream's
/// details page.
abstract interface class SearchSource {
  SearchSourceKind get kind;

  /// Opens [item], one of this searcher's results.
  Future<void> open(BuildContext context, MultimediaItem item);
}

/// The searchers a search adds to the extensions: a Stremio add-on's for each
/// one that can search, else Cinemeta's for stream add-ons that can't (as
/// Explore's Stremio search does), and Nuvio's while it has scrapers to run.
List<SkyStreamProvider> searchSources({
  required List<ManagedAddon> addons,
  required AddonClient client,
  required bool nuvioActive,
  required TmdbService tmdb,
}) {
  final stremio = [
    for (final addon in addons)
      if (StremioSearcher.catalogsOf(addon).isNotEmpty)
        StremioSearcher(addon, client),
  ];
  return [
    ...stremio,
    if (stremio.isEmpty &&
        AddonStreamService.streamProvidersOf(addons).isNotEmpty)
      StremioSearcher(BuiltInAddons.cinemeta, client),
    if (nuvioActive) NuvioSearcher(tmdb),
  ];
}

/// A Stremio add-on searching its catalogs that take a search; its results
/// open on Stremio's details page, asked of the add-on first.
class StremioSearcher extends SkyStreamProvider implements SearchSource {
  StremioSearcher(this.addon, this._client);

  final ManagedAddon addon;
  final AddonClient _client;

  /// Each catalog's wait, as Explore's Stremio search gives it.
  static const perCatalog = Duration(seconds: 12);

  /// The add-on's own type for each result of its last search: a details
  /// page is asked by it.
  final Map<String, String> _types = {};

  /// [addon]'s catalogs that take a search and nothing else they need.
  static List<AddonCatalog> catalogsOf(ManagedAddon addon) {
    final manifest = addon.manifest;
    if (manifest == null || !manifest.hasResource('catalog')) return const [];
    return [
      for (final catalog in manifest.catalogs)
        if (catalog.supportsSearch && !catalog.requiresOtherExtra) catalog,
    ];
  }

  @override
  SearchSourceKind get kind => SearchSourceKind.stremio;

  @override
  String get packageName => 'stremio:${addon.manifestUrl}';

  @override
  String get name => addon.displayName;

  @override
  String? get checkSource => AddonClient.sourceFor(addon);

  @override
  String get mainUrl => addon.manifestUrl;

  @override
  String get version => addon.manifest?.version ?? '';

  @override
  List<String> get languages => const [];

  @override
  Set<ProviderType> get supportedTypes => const {
    ProviderType.movie,
    ProviderType.series,
  };

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    final trimmed = query.trim();
    final catalogs = catalogsOf(addon);
    Object? failure;
    var failed = 0;
    final answers = await Future.wait([
      for (final catalog in catalogs)
        () async {
          try {
            return await _client
                .catalog(
                  addon,
                  type: catalog.type,
                  id: catalog.id,
                  extra: {'search': trimmed},
                  cancelToken: cancelToken,
                )
                .timeout(perCatalog);
          } catch (error) {
            failure ??= error;
            failed++;
            return const <AddonMetaPreview>[];
          }
        }(),
    ]);
    // Every catalog failing is the add-on failing, which the search notes.
    if (catalogs.isNotEmpty && failed == catalogs.length) throw failure!;

    final seen = <String>{};
    final results = [
      for (final answer in answers)
        for (final preview in answer)
          if (seen.add('${preview.type}:${preview.id}')) preview,
    ];
    _types
      ..clear()
      ..addAll({for (final preview in results) preview.id: preview.type});
    return [
      for (final preview in rankAddonSearchResults(results, trimmed))
        preview.toMultimediaItem(),
    ];
  }

  @override
  Future<void> open(BuildContext context, MultimediaItem item) =>
      AddonDetailRoute(
        type:
            _types[item.url] ??
            (item.contentType == MultimediaContentType.movie
                ? 'movie'
                : 'series'),
        id: item.url,
        addonUrl: addon.manifestUrl,
      ).push<void>(context);

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnsupportedError('A search source has no home');

  @override
  Future<MultimediaItem> getDetails(String url) =>
      throw UnsupportedError('A search source opens its own page');

  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnsupportedError('A search source opens its own page');
}

/// Nuvio's scrapers can't search: they take a TMDB id. Nuvio's section is
/// TMDB's films and series, each opening Nuvio's sources dialog (a series
/// asks for its episode first), where the scrapers run.
class NuvioSearcher extends SkyStreamProvider implements SearchSource {
  NuvioSearcher(this._tmdb);

  final TmdbService _tmdb;

  @override
  SearchSourceKind get kind => SearchSourceKind.nuvio;

  @override
  String get packageName => 'nuvio';

  @override
  String get name => 'Nuvio';

  @override
  String get mainUrl => 'https://www.themoviedb.org';

  @override
  String get version => '';

  @override
  List<String> get languages => const [];

  @override
  Set<ProviderType> get supportedTypes => const {
    ProviderType.movie,
    ProviderType.series,
  };

  @override
  Future<List<MultimediaItem>> search(
    String query, {
    CancelToken? cancelToken,
  }) async {
    final items = await _tmdb.multiSearch(query: query.trim());
    return [
      for (final item in items)
        if (item.tmdbId != null &&
            (item.contentType == MultimediaContentType.movie ||
                item.contentType == MultimediaContentType.series))
          item,
    ];
  }

  @override
  Future<void> open(BuildContext context, MultimediaItem item) async {
    if (item.contentType != MultimediaContentType.series) {
      await PluginSourcesSheet.open(context, item);
      return;
    }
    // The picker opens the sources dialog from its host once an episode is
    // picked: the app's navigator outlives a result card, which a rotation
    // or a resize can rebuild away.
    final host = Navigator.of(context, rootNavigator: true).context;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = AppLocalizations.of(context)!.searchNuvioSeriesFailed;
    final details = await _tmdb.getTvDetails(item.tmdbId!);
    final seasons = details?['seasons'];
    if (!host.mounted) return;
    if (seasons is! List) {
      messenger?.showSnackBar(SnackBar(content: Text(failed)));
      return;
    }
    await EpisodePickerSheet.open(
      host,
      movieId: item.tmdbId!,
      seasons: seasons,
      target: item,
    );
  }

  @override
  Future<Map<String, List<MultimediaItem>>> getHome() =>
      throw UnsupportedError('A search source has no home');

  @override
  Future<MultimediaItem> getDetails(String url) =>
      throw UnsupportedError('A search source opens its own page');

  @override
  Future<List<StreamResult>> loadStreams(String url) =>
      throw UnsupportedError('A search source opens its own page');
}
