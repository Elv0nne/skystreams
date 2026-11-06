import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/addons/data/addon_stream_service.dart';
import '../../../../core/addons/models/addon_manifest.dart';
import '../../../../core/addons/models/addon_meta.dart';
import '../../../../core/addons/models/addon_stream_source.dart';
import '../../../../core/storage/history_repository.dart';
import '../../../../core/utils/layout_constants.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../../shared/widgets/custom_widgets.dart';
import '../../../details/presentation/widgets/source_section_card.dart';
import '../../../library/presentation/history_provider.dart';
import '../addon_direct_play.dart';
import '../addon_own_links.dart';
import 'stremio_sources_card.dart';

/// A Stremio title's Play button (Stremio direct play).
///
/// There only once the add-on that described the title has answered with a
/// link that plays here, the way a CloudStream title's Play is: a button that
/// opened a list, or found nothing, is what the sources card replaced. "Resume"
/// with saved progress, and a show's names the episode it plays.
class AddonPlayButton extends ConsumerStatefulWidget {
  const AddonPlayButton({
    super.key,
    required this.meta,
    required this.addon,
    required this.target,
    this.compact = false,
  });

  final AddonMeta meta;

  /// The install that described [meta] and serves its links.
  final ManagedAddon addon;

  /// The episode it plays, or null for a movie.
  final AddonVideo? target;

  /// In a desktop hero's column: capped, as the sources card's action is.
  final bool compact;

  @override
  ConsumerState<AddonPlayButton> createState() => _AddonPlayButtonState();
}

class _AddonPlayButtonState extends ConsumerState<AddonPlayButton> {
  final FocusNode _focus = FocusNode(debugLabel: 'stremio play');
  bool _launching = false;

  /// Whether Play was on screen at the last build: it takes the remote each
  /// time it comes back, as when a finished episode moved it to the next.
  bool _shown = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  AddonStreamRequest get _request {
    final meta = widget.meta;
    final target = widget.target;
    return AddonStreamRequest(
      type: meta.streamRequestType,
      contentId: meta.id,
      videoId: target?.id,
      season: target?.season,
      episode: target?.episode,
      imdbId: meta.imdbId,
      tmdbId: meta.moviedbId,
      title: meta.name,
      year: meta.year,
    );
  }

  /// Takes the remote when Play shows up while the page's start - the sources
  /// card, or nothing at all - still holds it: Play is the page's first
  /// choice now. Somewhere the viewer moved to keeps it, and so does whatever
  /// covers the page: a sheet the viewer opened, the player.
  void _offerFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      final primary = FocusManager.instance.primaryFocus;
      // A sheet over the page can be on the app's navigator while the page
      // is on its tab's, where the page's route is still the current one.
      final holder = primary?.context;
      if (holder != null) {
        final holderRoute = ModalRoute.of(holder);
        if (holderRoute != null && holderRoute != route) return;
      }
      final atStart =
          primary == null ||
          primary is FocusScopeNode ||
          primary.context
                  ?.findAncestorWidgetOfExactType<StremioSourcesCard>() !=
              null;
      if (atStart) _focus.requestFocus();
    });
  }

  Future<void> _play(List<AddonStreamSource> links) async {
    // Pressed again while it works: one player is enough. Play stays enabled
    // meanwhile, because a disabled button cannot hold a remote's focus, and
    // then nothing would have it when the player closes.
    if (_launching) return;
    setState(() => _launching = true);
    // Asked again: a link from when the page opened may have expired since,
    // and within the add-on client's cache the answer is the same one. Should
    // the add-on have nothing now, the links from before are still worth a
    // try.
    final now = await ownPlayableLinks(
      ref.read(addonStreamServiceProvider),
      widget.addon,
      _request,
      personWaiting: true,
    );
    if (!mounted) return;
    await playAddonLinks(
      context,
      ref,
      item: widget.meta.toMultimediaItem(addonUrl: widget.addon.manifestUrl),
      request: _request,
      links: now.isNotEmpty ? now : links,
      episode: widget.target?.toEpisode(),
    );
    if (!mounted) return;
    setState(() => _launching = false);
    // Back from the player: a remote picks up where it left.
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final links =
        ref
            .watch(ownLinksProvider(ownLinksKey(widget.addon, _request)))
            .asData
            ?.value ??
        const <AddonStreamSource>[];
    if (links.isEmpty) {
      _shown = false;
      return const SizedBox.shrink();
    }
    if (!_shown) {
      _shown = true;
      _offerFocus();
    }

    // Rebuilt when a play is saved, so a title watched part-way says Resume.
    ref.watch(watchHistoryProvider);
    final history = ref.watch(historyRepositoryProvider);
    final meta = widget.meta;
    final target = widget.target;
    final position = target == null
        ? history.getPosition(meta.id)
        : history.getEpisodePosition(
            target.id,
            mainUrl: meta.id,
            season: target.season,
            episode: target.episode,
          );

    final l10n = AppLocalizations.of(context)!;
    var label = position > 5000 ? l10n.resume : l10n.play;
    if (target != null) {
      label = meta.seasons.length <= 1
          ? l10n.playEpisodeOnly(label, target.episode ?? 1)
          : l10n.playEpisode(label, target.season ?? 1, target.episode ?? 1);
    }

    final button = CustomButton(
      isPrimary: true,
      focusNode: _focus,
      onPressed: () => _play(links),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: LayoutConstants.spacingMd,
          horizontal: LayoutConstants.spacingMd,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: _launching
              ? [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: LayoutConstants.spacingXs),
                  Text(l10n.resolving),
                ]
              : [
                  const Icon(Icons.play_arrow_rounded),
                  const SizedBox(width: LayoutConstants.spacingXs),
                  Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
                ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: widget.compact
          ? ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: kSourceActionDesktopWidth,
              ),
              child: SizedBox(width: double.infinity, child: button),
            )
          : SizedBox(width: double.infinity, child: button),
    );
  }
}
