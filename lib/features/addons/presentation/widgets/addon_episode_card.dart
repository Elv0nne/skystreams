import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/addons/models/addon_meta.dart';
import '../../../../core/storage/episode_watch_repository.dart';
import '../../../../core/storage/history_repository.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/cards_wrapper.dart';
import '../../../../shared/widgets/thumbnail_error_placeholder.dart';
import '../../../library/presentation/history_provider.dart';

/// A Stremio show's episode, drawn as a CloudStream title's is (`EpisodeCard`):
/// its thumbnail with progress and a play icon, its number and name, when it
/// aired, its overview (Stremio direct play). A tap plays it; a long press,
/// or OK held on a remote, searches every add-on for it.
class AddonEpisodeCard extends ConsumerWidget {
  const AddonEpisodeCard({
    super.key,
    required this.video,
    required this.showUrl,
    required this.onTap,
    this.onLongPress,
    this.loading = false,
  });

  final AddonVideo video;

  /// The show's id: what history files the episode's progress under.
  final String showUrl;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Its links are being asked for: a spinner stands in for the play icon.
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final episode = video.toEpisode();

    // Not out yet: the card says when it airs and shows a schedule icon, as a
    // CloudStream title's does. A tap still asks: the date can be the
    // broadcast's while the add-on already has the episode.
    final aired = DateTime.tryParse(video.released ?? '');
    final upcoming = aired != null && aired.isAfter(DateTime.now());
    final date = aired == null
        ? null
        : MaterialLocalizations.of(context).formatShortDate(aired.toLocal());
    final when = date == null
        ? null
        : upcoming
        ? l10n.episodeAirsOn(date)
        : date;

    final history = ref.watch(historyRepositoryProvider);
    final last = ref.watch(
      watchHistoryProvider.select(
        (list) => list.firstWhereOrNull((h) => h.item.url == showUrl),
      ),
    );
    ref.watch(episodeWatchRevisionProvider);
    final watchedRepo = ref.watch(episodeWatchRepositoryProvider);
    final position = history.getEpisodePosition(
      video.id,
      mainUrl: showUrl,
      season: episode.season,
      episode: episode.episode,
    );
    final duration = history.getEpisodeDuration(
      video.id,
      mainUrl: showUrl,
      season: episode.season,
      episode: episode.episode,
    );
    final progress = duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0;
    final watched = watchedRepo.isWatched(showUrl, episode);

    String? badge;
    if (watched) {
      badge = l10n.watched.toUpperCase();
    } else if (progress > 0.02) {
      badge = l10n.watching.toUpperCase();
    } else if (last != null &&
        watchedRepo.getExplicitState(showUrl, episode) != false &&
        (last.season ?? 1) == episode.season &&
        (last.episode ?? 1) == episode.episode) {
      badge = l10n.lastWatched.toUpperCase();
    }

    final dark = theme.brightness == Brightness.dark;
    final fill = theme.colorScheme.surfaceContainerLow;
    final radius = BorderRadius.circular(12);
    final number = video.episode;

    return CardsWrapper(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: radius,
      child: Container(
        decoration: BoxDecoration(
          color: watched
              ? Color.alphaBlend(
                  Colors.black.withValues(alpha: dark ? 0.30 : 0.14),
                  fill,
                )
              : fill,
          borderRadius: radius,
          border: Border.all(
            color: theme.dividerColor.withValues(alpha: dark ? 0.1 : 0.5),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.all(LayoutConstants.spacingSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _thumbnail(
                  context,
                  watched ? 1.0 : progress,
                  badge,
                  watched: watched,
                  upcoming: upcoming,
                ),
                const SizedBox(width: LayoutConstants.spacingMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        number == null
                            ? video.title.toUpperCase()
                            : '$number. ${video.title.toUpperCase()}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: watched
                              ? theme.colorScheme.onSurface.withValues(
                                  alpha: 0.65,
                                )
                              : theme.colorScheme.onSurface,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (when != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          when,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: upcoming
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (video.overview != null && video.overview!.isNotEmpty) ...[
              const SizedBox(height: LayoutConstants.spacingSm),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: Text(
                  video.overview!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.8,
                    ),
                    height: 1.4,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _thumbnail(
    BuildContext context,
    double progress,
    String? badge, {
    required bool watched,
    required bool upcoming,
  }) {
    final theme = Theme.of(context);
    final thumbnail = video.thumbnail;
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 140,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: thumbnail == null || thumbnail.isEmpty
                  ? ColoredBox(color: theme.colorScheme.surfaceContainerHighest)
                  : CachedNetworkImage(
                      imageUrl: thumbnail,
                      fit: BoxFit.cover,
                      errorWidget: (context, url, error) =>
                          const ThumbnailErrorPlaceholder(),
                      placeholder: (context, url) => ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
            ),
          ),
        ),
        if (watched)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.black.withValues(alpha: 0.28),
                ),
              ),
            ),
          ),
        if (progress > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: Colors.black26,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
            ),
          ),
        if (badge != null)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                badge,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: loading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(
                      upcoming
                          ? Icons.schedule_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
            ),
          ),
        ),
      ],
    );
  }
}
