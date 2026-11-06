/// A Stremio title's own add-on's links while its details page is open
/// (Stremio direct play): its Play button shows only once there is one. The
/// rules for which add-on and how it is asked are the core's.
library;

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/data/addon_own_links.dart';
import '../../../core/addons/data/addon_repository.dart';
import '../../../core/addons/data/addon_stream_service.dart';
import '../../../core/addons/models/addon_manifest.dart';
import '../../../core/addons/models/addon_stream_source.dart';

export '../../../core/addons/data/addon_own_links.dart';

/// [ownLinksProvider]'s key: an install by its URL, and a request by value -
/// a record, so a page that rebuilds with an equal request asks nothing again.
typedef OwnLinksKey = ({
  String addonUrl,
  String type,
  String contentId,
  String? videoId,
  int? season,
  int? episode,
  String? imdbId,
  int? tmdbId,
  String? title,
  int? year,
});

OwnLinksKey ownLinksKey(ManagedAddon addon, AddonStreamRequest request) => (
  addonUrl: addon.manifestUrl,
  type: request.type,
  contentId: request.contentId,
  videoId: request.videoId,
  season: request.season,
  episode: request.episode,
  imdbId: request.imdbId,
  tmdbId: request.tmdbId,
  title: request.title,
  year: request.year,
);

/// The own add-on's playable links, asked in the background while a details
/// page is open. Nobody is waiting on it, so a bot check that wants a click
/// does not open its sheet; the page's sources card is still there for that.
final ownLinksProvider = FutureProvider.autoDispose
    .family<List<AddonStreamSource>, OwnLinksKey>((ref, key) async {
      final addon = ref
          .read(addonRepositoryProvider)
          .enabled
          .firstWhereOrNull((a) => a.manifestUrl == key.addonUrl);
      if (addon == null) return const [];
      return ownPlayableLinks(
        ref.read(addonStreamServiceProvider),
        addon,
        AddonStreamRequest(
          type: key.type,
          contentId: key.contentId,
          videoId: key.videoId,
          season: key.season,
          episode: key.episode,
          imdbId: key.imdbId,
          tmdbId: key.tmdbId,
          title: key.title,
          year: key.year,
        ),
      );
    });
