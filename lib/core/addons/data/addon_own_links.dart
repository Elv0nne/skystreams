/// A Stremio title's own add-on and its links (Stremio direct play).
///
/// Bridges such as CNCVerse publish a catalog, their titles' meta and their
/// streams, so a title one of them described plays from its page the way a
/// CloudStream title does, and its next episode comes from the same add-on in
/// the player. A title Cinemeta described (meta, no links) keeps the search
/// over every add-on, which is also how a stream-only add-on such as Torrentio
/// is reached.
library;

import 'package:riverpod_annotation/riverpod_annotation.dart'
    show ProviderListenable;

import '../models/addon_manifest.dart';
import '../models/addon_meta.dart';
import '../models/addon_stream_source.dart';
import 'addon_stream_service.dart';
import 'debrid_service.dart';

/// The install that described [meta]: of two installs of one add-on (one
/// manifest id, two configurations), the one at [routeAddonUrl] - whose
/// catalog listed the title - when it is one of them, else the first enabled
/// one. Null when no enabled install is that add-on.
ManagedAddon? describingAddon({
  required List<ManagedAddon> enabled,
  required AddonMeta meta,
  String? routeAddonUrl,
}) {
  ManagedAddon? describer;
  for (final addon in enabled) {
    if (addon.id != meta.addonId) continue;
    if (addon.manifestUrl == routeAddonUrl) return addon;
    describer ??= addon;
  }
  return describer;
}

/// The install that described [meta] (see [describingAddon]), when it serves
/// the title's streams. Without [routeAddonUrl] - a title reopened from
/// Continue Watching with no add-on named - the first enabled install of that
/// add-on is taken.
ManagedAddon? ownStreamAddon({
  required List<ManagedAddon> enabled,
  required AddonMeta meta,
  String? routeAddonUrl,
}) {
  final describer = describingAddon(
    enabled: enabled,
    meta: meta,
    routeAddonUrl: routeAddonUrl,
  );
  final manifest = describer?.manifest;
  if (manifest == null || !manifest.hasResource('stream')) return null;
  if (!manifest.supportsId('stream', meta.id)) return null;
  if (manifest.requestTypesFor('stream', meta.streamRequestType).isEmpty) {
    return null;
  }
  return describer;
}

/// [addon]'s playable links for [request], best first: direct links and
/// torrents, not what only opens elsewhere (a donation page, a trailer).
///
/// Asked by the ids the add-on published; only when those have no playable
/// link, and the add-on did answer, by the IMDb or TMDB id the title came
/// with. Never by name: given a title and no IMDb id, the service looks one up
/// on Cinemeta, whose first match can be another show's - fine for a list the
/// viewer picks from, not for a Play button. Ranked as the sources sheet ranks
/// them, so links to another film that the add-on mixed in go last. Empty when
/// the add-on fails or runs out of time.
Future<List<AddonStreamSource>> ownPlayableLinks(
  AddonStreamService service,
  ManagedAddon addon,
  AddonStreamRequest request, {
  bool personWaiting = false,
}) async {
  /// One ask's playable links, and whether the add-on failed it.
  Future<({List<AddonStreamSource> links, bool failed})> ask({
    String? imdbId,
    int? tmdbId,
  }) async {
    var last = const AddonStreamProgress();
    await for (final progress in service.resolve(
      addons: [addon],
      request: AddonStreamRequest(
        type: request.type,
        contentId: request.contentId,
        videoId: request.videoId,
        season: request.season,
        episode: request.episode,
        imdbId: imdbId,
        tmdbId: tmdbId,
      ),
      personWaiting: personWaiting,
    )) {
      last = progress;
    }
    return (
      links: [
        for (final stream in last.streams)
          if (stream.isPlayable) stream,
      ],
      failed: last.statuses.any(
        (status) => status.outcome == AddonQueryOutcome.failed,
      ),
    );
  }

  List<AddonStreamSource> ranked(List<AddonStreamSource> links) =>
      rankAddonStreams(links, title: request.title, year: request.year);

  try {
    final published = await ask();
    if (published.links.isNotEmpty || published.failed) {
      return ranked(published.links);
    }
    final imdbId = request.imdbId?.trim();
    final hasImdb = imdbId != null && imdbId.isNotEmpty;
    if (!hasImdb && request.tmdbId == null) return const [];
    final universal = await ask(
      imdbId: hasImdb ? imdbId : null,
      tmdbId: request.tmdbId,
    );
    return ranked(universal.links);
  } catch (_) {
    return const [];
  }
}

/// [source] through the debrid service, when it is a torrent and one is set
/// up: the same file as a direct link, or [source] itself when that fails, as
/// the sources sheet always did. [onStatus] hears how it goes, and null when
/// it is over.
Future<AddonStreamSource> viaDebrid(
  T Function<T>(ProviderListenable<T> provider) read,
  AddonStreamSource source, {
  void Function(String? status)? onStatus,
}) async {
  if (!source.isTorrent || !read(debridSettingsProvider).isConfigured) {
    return source;
  }
  onStatus?.call('Checking debrid…');
  try {
    final link = await read(debridServiceProvider).resolveMagnet(
      source.magnetUri ?? '',
      preferredFilename: source.filename,
      onStatus: onStatus,
    );
    if (link == null) return source;
    return AddonStreamSource(
      addonId: source.addonId,
      addonName: source.addonName,
      url: link.url,
      name: source.name,
      title: source.title,
      description: source.description,
      videoSize: link.sizeBytes ?? source.videoSize,
      filename: link.filename ?? source.filename,
      bingeGroup: source.bingeGroup,
      subtitles: source.subtitles,
    );
  } catch (_) {
    // Fall through to the magnet.
    return source;
  } finally {
    onStatus?.call(null);
  }
}
