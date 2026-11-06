/// Playing a Stremio title from its add-ons' links (Stremio direct play):
/// what its Play button, its episodes and the sources sheet's rows share, and
/// which episode a show's Play button plays.
library;

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/addons/data/addon_own_links.dart';
import '../../../core/addons/data/addon_playback_launcher.dart';
import '../../../core/addons/data/addon_repository.dart';
import '../../../core/addons/data/addon_stream_service.dart';
import '../../../core/addons/models/addon_meta.dart';
import '../../../core/addons/models/addon_stream_source.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/storage/episode_watch_repository.dart';
import '../../../core/storage/history_repository.dart';
import '../../details/presentation/playback_launcher.dart';
import '../../settings/presentation/player_settings_provider.dart';

/// Plays [links] - playable ones, best first - for [item]: [selected], or the
/// first, with the rest as the player's other sources.
///
/// A torrent goes through the debrid service first when one is set up, as the
/// sources sheet always did; [onStatus] hears how that goes, and null when it
/// is over. The item handed to the player names the install whose link plays
/// ([MultimediaItem.streamAddonUrl]) and the type it was asked by, so the
/// player asks that add-on for the next episode too; the add-on that described
/// the title stays named as it was. [beforeLaunch] runs just before the player
/// opens: the sheet closes itself there.
///
/// Completes when the player has closed again; false when there was nothing
/// to play.
Future<bool> playAddonLinks(
  BuildContext context,
  WidgetRef ref, {
  required MultimediaItem item,
  required AddonStreamRequest request,
  required List<AddonStreamSource> links,
  AddonStreamSource? selected,
  Episode? episode,
  void Function(String? status)? onStatus,
  VoidCallback? beforeLaunch,
}) async {
  final first = selected ?? links.firstOrNull;
  if (first == null) return false;
  final chosen = await viaDebrid(ref.read, first, onStatus: onStatus);

  final converter = ref.read(addonStreamConverterProvider);
  final streams = converter.toStreamResults(links, selected: chosen);
  if (streams.isEmpty) return false;

  // Which player opens this is a setting, so it is the launcher's call, not
  // the caller's. Resolved here rather than inside the launcher because the
  // sheet is about to pop and a cold settings box would otherwise finish
  // loading after its context is gone.
  final launcher = ref.read(playbackLauncherProvider);
  await ref.read(playerSettingsProvider.future);
  if (!context.mounted) return false;

  // The install whose link plays: the one that described the title when that
  // is the add-on (of two installs of one add-on, the one that listed it).
  final installs = ref.read(addonRepositoryProvider).enabled;
  final named = installs.firstWhereOrNull(
    (a) => a.manifestUrl == item.addonUrl,
  );
  final source = named != null && named.id == chosen.addonId
      ? named
      : installs.firstWhereOrNull((a) => a.id == chosen.addonId);

  beforeLaunch?.call();
  await launcher.playResolved(
    context,
    item: item.copyWith(
      streamAddonUrl: source?.manifestUrl,
      addonType: request.type,
    ),
    videoUrl: converter.videoUrlFor(
      contentId: request.contentId,
      videoId: request.videoId,
    ),
    episode: converter.episodeFor(episode, request.videoId),
    streams: streams,
  );
  return true;
}

/// The episode a show's Play button plays, by the regular details page's rule
/// (`DetailsController`) on the add-on's numbered episodes: the episode last
/// watched while unfinished, the next one once it is finished, else the first
/// not yet watched, else the last. Null for a movie, and for a show whose
/// add-on numbers no episodes.
AddonVideo? addonPlayTarget(
  AddonMeta meta, {
  required HistoryRepository history,
  required EpisodeWatchRepository watched,
  HistoryItem? lastWatched,
}) {
  if (!meta.isShow) return null;
  final episodes = [
    for (final video in meta.videos)
      if ((video.season ?? 0) > 0 && (video.episode ?? 0) > 0) video,
  ];
  if (episodes.isEmpty) return null;
  bool done(AddonVideo video) => watched.isWatched(meta.id, video.toEpisode());

  final last = history.getLastEpisodeUrl(meta.id);
  if (last != null) {
    var index = episodes.indexWhere((v) => v.id == last);
    if (index == -1 &&
        lastWatched?.season != null &&
        lastWatched?.episode != null) {
      index = episodes.indexWhere(
        (v) =>
            v.season == lastWatched!.season && v.episode == lastWatched.episode,
      );
    }
    if (index != -1) {
      final matched = episodes[index];
      if (!done(matched)) return matched;
      return index + 1 < episodes.length ? episodes[index + 1] : matched;
    }
  }
  return episodes.firstWhereOrNull((v) => !done(v)) ?? episodes.last;
}
