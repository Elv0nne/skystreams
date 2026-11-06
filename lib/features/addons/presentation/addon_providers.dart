import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/addons/data/addon_client.dart';
import '../../../core/addons/data/addon_repository.dart';
import '../../../core/addons/data/builtin_addons.dart';
import '../../../core/addons/models/addon_manifest.dart';
import '../../../core/addons/models/addon_meta.dart';

part 'addon_providers.g.dart';

/// A catalog the Catalogs tab can render as a row.
class BrowsableCatalog {
  final ManagedAddon addon;
  final AddonCatalog catalog;

  const BrowsableCatalog({required this.addon, required this.catalog});

  String get title {
    // Only the two canonical types get a pretty suffix; unusually typed
    // catalogs (CNCVerse-style 'other'/'tv' rows) already carry their type
    // in the server-provided name — "$name · other" reads as a duplication.
    return switch (catalog.type) {
      'series' => '${catalog.name} · Series',
      'movie' => '${catalog.name} · Movies',
      _ => catalog.name,
    };
  }

  String get subtitle => addon.displayName;
  String get key => '${addon.manifestUrl}|${catalog.key}';
}

/// Every browsable catalog of every enabled add-on — derived from the stored
/// manifests, so it costs no network at all.
///
/// Rows fetch their own items when they scroll into view
/// ([addonCatalogItems]); a catalog add-on that publishes 40 rows therefore
/// costs 3-4 requests on open instead of 40.
@riverpod
List<BrowsableCatalog> browsableCatalogs(Ref ref) {
  final addons = ref.watch(addonRepositoryProvider).enabled;

  final out = <BrowsableCatalog>[];
  for (final addon in addons) {
    final manifest = addon.manifest;
    if (manifest == null || !manifest.hasResource('catalog')) continue;
    for (final catalog in manifest.catalogs) {
      if (catalog.requiresSearch || catalog.requiresOtherExtra) continue;
      out.add(BrowsableCatalog(addon: addon, catalog: catalog));
    }
  }
  return out;
}

/// Outcome of one catalog row. Errors are carried rather than swallowed —
/// a row that silently disappears is impossible to debug from the UI.
class AddonCatalogResult {
  final List<AddonMetaPreview> items;
  final String? error;

  const AddonCatalogResult({this.items = const [], this.error});

  bool get isEmpty => items.isEmpty;
  bool get failed => error != null;
}

/// Items of a single catalog row. Cached by the client for 15 minutes.
@riverpod
Future<AddonCatalogResult> addonCatalogItems(
  Ref ref,
  String addonUrl,
  String type,
  String id, {
  String? genre,
}) async {
  final addons = ref.watch(addonRepositoryProvider).addons;
  ManagedAddon? addon;
  for (final candidate in addons) {
    if (candidate.manifestUrl == addonUrl) addon = candidate;
  }
  addon ??= addonUrl == BuiltInAddons.cinemetaUrl
      ? BuiltInAddons.cinemeta
      : null;
  if (addon == null) {
    return const AddonCatalogResult(error: 'Add-on is no longer installed.');
  }

  try {
    final items = await ref
        .watch(addonClientProvider)
        .catalog(
          addon,
          type: type,
          id: id,
          extra: genre == null ? null : {'genre': genre},
        )
        .timeout(const Duration(seconds: 20));
    return AddonCatalogResult(items: items);
  } on TimeoutException {
    return const AddonCatalogResult(error: 'Timed out');
  } catch (error) {
    return AddonCatalogResult(error: error.toString());
  }
}

/// Search across every catalog that advertises `search`, with Cinemeta as a
/// fallback when no installed add-on can search.
@riverpod
Future<List<AddonMetaPreview>> addonSearch(Ref ref, String query) async {
  final trimmed = query.trim();
  if (trimmed.length < 2) return const [];

  final addons = ref.watch(addonRepositoryProvider).enabled;
  final client = ref.watch(addonClientProvider);

  final searchable = <MapEntry<ManagedAddon, AddonCatalog>>[];
  for (final addon in addons) {
    final manifest = addon.manifest;
    if (manifest == null || !manifest.hasResource('catalog')) continue;
    for (final catalog in manifest.catalogs) {
      if (catalog.supportsSearch) searchable.add(MapEntry(addon, catalog));
    }
  }
  if (searchable.isEmpty) {
    for (final catalog in BuiltInAddons.cinemeta.manifest!.catalogs) {
      if (catalog.supportsSearch) {
        searchable.add(MapEntry(BuiltInAddons.cinemeta, catalog));
      }
    }
  }

  final results = await Future.wait([
    for (final entry in searchable)
      () async {
        try {
          return await client
              .catalog(
                entry.key,
                type: entry.value.type,
                id: entry.value.id,
                extra: {'search': trimmed},
              )
              .timeout(const Duration(seconds: 12));
        } catch (_) {
          return const <AddonMetaPreview>[];
        }
      }(),
  ]);

  final seen = <String>{};
  final out = <AddonMetaPreview>[];
  for (final list in results) {
    for (final item in list) {
      if (seen.add('${item.type}:${item.id}')) out.add(item);
    }
  }
  return rankAddonSearchResults(out, trimmed);
}

/// [results] merged from every searchable catalog, closest to [query] first.
///
/// Each catalog ranks its own answers, but they arrive one catalog after
/// another: "India vs Afghanistan" opened on Cinemeta's loose matches
/// ("India's Got Latent") while the match itself, in a bridge's live-events
/// catalog, sat behind them, past the suggestions shown. So the name itself
/// comes first, then the search as a phrase in a name, then names with every
/// word of it, then names sharing more of its words; the last word may be
/// half typed, and ties keep the catalogs' order.
List<AddonMetaPreview> rankAddonSearchResults(
  List<AddonMetaPreview> results,
  String query,
) {
  final wanted = _searchWords(query);
  if (wanted.isEmpty) return results;
  final phrase = wanted.join(' ');
  final ranks = [
    for (final item in results) _searchRank(item.name, wanted, phrase),
  ];
  final order = [for (var i = 0; i < results.length; i++) i]
    ..sort((a, b) {
      final (tierA, wordsA, lettersA) = ranks[a];
      final (tierB, wordsB, lettersB) = ranks[b];
      if (tierA != tierB) return tierA.compareTo(tierB);
      if (wordsA != wordsB) return wordsB.compareTo(wordsA);
      if (lettersA != lettersB) return lettersB.compareTo(lettersA);
      return a.compareTo(b);
    });
  return [for (final i in order) results[i]];
}

final RegExp _searchSeparators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

List<String> _searchWords(String text) => [
  for (final word in text.toLowerCase().split(_searchSeparators))
    if (word.isNotEmpty) word,
];

/// How closely [name] answers a search for [wanted]: a tier, lower is closer,
/// then how many of the searched words it has and how many letters they are.
(int, int, int) _searchRank(String name, List<String> wanted, String phrase) {
  final words = _searchWords(name);
  final text = words.join(' ');
  var matched = 0;
  var letters = 0;
  for (var i = 0; i < wanted.length; i++) {
    final word = wanted[i];
    final typing = i == wanted.length - 1;
    if (words.any((w) => w == word || (typing && w.startsWith(word)))) {
      matched++;
      letters += word.length;
    }
  }
  final tier = text == phrase
      ? 0
      : ' $text '.contains(' $phrase ')
      ? 1
      : ' $text'.contains(' $phrase')
      ? 2
      : matched == wanted.length
      ? 3
      : matched > 0
      ? 4
      : 5;
  return (tier, matched, letters);
}

/// Meta for one item: the add-on it came from first, then any other meta
/// add-on, then built-in Cinemeta for IMDb ids.
///
/// The fallback is what makes catalog-only add-ons (Streaming Catalogs, Trakt
/// lists, …) usable — they publish posters but no `meta` resource at all.
@riverpod
Future<AddonMeta?> addonMeta(
  Ref ref,
  String type,
  String id, {
  String? preferredAddonUrl,
}) async {
  // Asked again only when the add-ons that could describe the title change:
  // the update check at launch reads every manifest again, unchanged, and an
  // open page - its reload held while the player covered it - met a viewer
  // back from an episode with the loading placeholder, for as long as a
  // bridge takes to describe a title.
  ref.watch(
    addonRepositoryProvider.select(
      (s) => [
        for (final a in s.enabled)
          if (a.manifest?.hasResource('meta') ?? false) a.manifestUrl,
      ].join('\n'),
    ),
  );
  final addons = ref.read(addonRepositoryProvider).enabled;
  final client = ref.watch(addonClientProvider);

  final candidates = addons
      .where((a) => a.manifest?.hasResource('meta') ?? false)
      .toList();

  final ordered = <ManagedAddon>[
    ...candidates.where((a) => a.manifestUrl == preferredAddonUrl),
    ...candidates.where((a) => a.manifestUrl != preferredAddonUrl),
    if (id.startsWith('tt') &&
        !candidates.any((a) => a.manifestUrl == BuiltInAddons.cinemetaUrl))
      BuiltInAddons.cinemeta,
  ];

  for (final addon in ordered) {
    final manifest = addon.manifest!;
    if (!manifest.supportsId('meta', id)) continue;
    // The add-on whose catalog listed the title is the one that knows its
    // id, and a scraping bridge's meta is a scrape: CNCVerse took 9 to 29 s
    // to describe what its own search had listed. The others get the time a
    // plain meta add-on needs.
    final ceiling = addon.manifestUrl == preferredAddonUrl
        ? AddonClient.scrapeTimeout
        : const Duration(seconds: 12);
    for (final requestType in manifest.requestTypesFor('meta', type)) {
      try {
        final meta = await client
            // A person opened the title: a check that wants a click opens
            // the check sheet.
            .meta(addon, type: requestType, id: id, personWaiting: true)
            .timeout(ceiling);
        if (meta != null) return meta;
      } on TimeoutException {
        // A slow host, not a wrong type: asking as the next type would only
        // wait as long again.
        break;
      } catch (_) {
        continue;
      }
    }
  }
  return null;
}

/// Stremio's community add-on directory (Discover tab).
@riverpod
Future<List<CommunityAddon>> communityAddons(Ref ref) {
  return ref.watch(addonClientProvider).communityAddons();
}

/// Outcome of one liveness probe, shown per add-on on the Manage tab — the
/// Nuvio "Working / Unavailable" convention, for Stremio add-ons.
enum AddonHealthStatus { working, unavailable }

class AddonHealth {
  final AddonHealthStatus status;

  /// Manifest round-trip time — only set when [status] is working.
  final int? latencyMs;

  /// Why the probe failed (timeout, HTTP error, …), for debugging.
  final String? message;

  const AddonHealth.working(this.latencyMs)
    : status = AddonHealthStatus.working,
      message = null;

  const AddonHealth.unavailable(this.message)
    : status = AddonHealthStatus.unavailable,
      latencyMs = null;
}

/// Ping every installed add-on's manifest concurrently. One dead host
/// cannot stall the others — the map is always complete within [timeout].
Future<Map<String, AddonHealth>> probeAddonsHealth(
  AddonClient client,
  List<ManagedAddon> addons, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final results = await Future.wait([
    for (final addon in addons)
      () async {
        final stopwatch = Stopwatch()..start();
        try {
          await client
              .fetchManifest(addon.manifestUrl, forceRefresh: true)
              .timeout(timeout);
          return MapEntry(
            addon.manifestUrl,
            AddonHealth.working(stopwatch.elapsedMilliseconds),
          );
        } catch (error) {
          return MapEntry(
            addon.manifestUrl,
            AddonHealth.unavailable(
              error is AddonException ? error.message : error.toString(),
            ),
          );
        }
      }(),
  ]);
  return {for (final entry in results) entry.key: entry.value};
}

/// Liveness of every installed add-on, keyed by manifest URL. Re-probes
/// automatically when an add-on is installed or removed; the manual refresh
/// invalidates it.
///
/// Watches the set of installed hosts rather than the add-on list: switching
/// an add-on off or reordering it replaces the list without changing whether
/// any host answers, and watched whole, either re-fetched every manifest and
/// put every badge back to "Checking".
@riverpod
Future<Map<String, AddonHealth>> addonHealth(Ref ref) {
  ref.watch(
    addonRepositoryProvider.select(
      (state) =>
          ([for (final a in state.addons) a.manifestUrl]..sort()).join('\n'),
    ),
  );
  final addons = ref.read(addonRepositoryProvider).addons;
  final client = ref.watch(addonClientProvider);
  if (addons.isEmpty) return Future.value(const {});
  return probeAddonsHealth(client, addons);
}
