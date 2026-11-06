import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../../shared/focus/app_focus.dart';
import '../../../../../shared/focus/text_field_keys.dart';
import '../../../../../shared/widgets/desktop_scroll_wrapper.dart';
import '../../../domain/entity/subtitle_model.dart';
import '../../../domain/subtitle_search_target.dart';
import '../../../domain/track_language.dart';
import '../../subtitle_search_provider.dart';
import '../../widgets/hotstar_player_style.dart';
import 'player_panel_metrics.dart';
import 'player_panel_row.dart';

/// Online subtitle search for what is playing, as the side panel's second
/// step: the Subtitles tab's "Search online" opens it in the panel's place -
/// see `PanelPage`.
///
/// The page is handed a [SubtitleSearchTarget] — the title the player is
/// showing and, when the catalogue knew them, its IMDb/TMDb id and the episode.
/// With an id it searches the moment it opens, because an id match is exact and
/// a title match is a guess. The field shows the title, and the moment the
/// viewer edits it the next search is by that text alone: every provider
/// prefers an id over the query when both are sent, so an edited title with the
/// ids still attached would be silently ignored. Restoring the exact title
/// turns the ids back on.
///
/// A downloaded result goes to [onFile] - the Subtitles tab lists it and puts
/// it on screen - or, with no [onFile], to the engine as an ordinary side-car.
/// Either way [onDone] then takes the panel back to the tab.
///
/// The shape the search had as a page of its own, narrowed to the drawer: a
/// search field, a row of languages, and one row per result. Every control is
/// one focus stop wearing the panel's ring - the field, its two buttons, each
/// language, each result - and every one of them also answers a tap, a click
/// and the keyboard.
class SubtitleSearchPage extends ConsumerStatefulWidget {
  const SubtitleSearchPage({
    required this.controller,
    required this.onDone,
    this.target,
    this.isTv = false,
    this.onFile,
    super.key,
  });

  final VlcPlayerController controller;

  /// Takes a downloaded result, as a file on this device, and says whether it
  /// could be used. Null hands the file to [controller] instead.
  final Future<bool> Function(Uri file, OnlineSubtitle subtitle)? onFile;

  /// A result is on: the page is done.
  final VoidCallback onDone;

  /// What the player already knows the viewer is watching. The title seeds
  /// the field; an id, when there is one, makes the search fire on open.
  final SubtitleSearchTarget? target;

  /// A remote starts in the field when there is nothing to search for yet,
  /// even before its first key press - see [_SubtitleSearchPageState._focusIn].
  final bool isTv;

  @override
  ConsumerState<SubtitleSearchPage> createState() => _SubtitleSearchPageState();
}

class _SubtitleSearchPageState extends ConsumerState<SubtitleSearchPage> {
  late final TextEditingController _query = TextEditingController(
    text: widget.target?.title ?? '',
  );
  final ScrollController _languageScroll = ScrollController();

  /// Up and down leave the field while the keyboard is put away, and Select
  /// brings it back - see [remoteTextFieldKeys].
  final FocusNode _fieldNode = FocusNode(
    debugLabel: 'subtitle search field',
    onKeyEvent: remoteTextFieldKeys,
  );
  final FocusNode _searchButton = FocusNode(
    debugLabel: 'subtitle search button',
  );

  /// One node per language chip, for the life of the page: the row is entered
  /// on the one searched in, and a node never moves between chips - one that
  /// did would take focus with it.
  final Map<String, FocusNode> _languageNodes = {
    for (final code in playerLanguages.values)
      code: FocusNode(debugLabel: 'subtitle language $code'),
  };

  FocusNode? get _selectedLanguage =>
      _languageNodes[ref.read(subtitleLanguageProvider)];

  /// Whether the next search sends the target's ids. On while the field
  /// still reads the target's own title; off the moment it says anything
  /// else, so the viewer's words are what gets searched.
  bool _idSearch = false;

  /// The result being fetched and unpacked, while one is. Downloads take
  /// seconds over a slow link, and a second press would race the first.
  String? _downloadingId;
  String? _error;

  bool get _downloading => _downloadingId != null;

  @override
  void initState() {
    super.initState();
    _idSearch = widget.target?.hasId ?? false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusIn();
      // The language searched in is in view from the start, not off the end
      // of the row.
      _revealLanguage();
      // An id is worth a search nobody asked for; a bare title is not, or a
      // local file's filename would hit the network on every open. A search
      // already in flight (the notifier outlives this page) is left to finish.
      if (_idSearch && !ref.read(subtitleSearchProvider).isLoading) _search();
    });
  }

  @override
  void dispose() {
    _query.dispose();
    _languageScroll.dispose();
    _fieldNode.dispose();
    _searchButton.dispose();
    for (final node in _languageNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Where focus starts, which is always somewhere on this page: the page
  /// replaced the row that held it, and a remote with nothing focused has
  /// nowhere for its arrows to go.
  ///
  /// With something to search for, the search button - the results arrive one
  /// press below it. With nothing, the field, for a remote or a keyboard that
  /// has typing to do anyway; under a thumb that would raise a keyboard nobody
  /// asked for, so the language searched in takes it instead, where no ring
  /// shows until a key is pressed.
  void _focusIn() {
    final seeded = _query.text.trim().isNotEmpty;
    final keys =
        widget.isTv ||
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    if (seeded) {
      _searchButton.requestFocus();
    } else if (keys) {
      _fieldNode.requestFocus();
    } else {
      _selectedLanguage?.requestFocus();
    }
  }

  void _onEdited(String text) {
    final target = widget.target;
    setState(() {
      _idSearch =
          target != null && target.hasId && text.trim() == target.title.trim();
    });
  }

  void _search() {
    final query = _query.text.trim();
    final target = widget.target;
    final byId = _idSearch && target != null;
    if (query.isEmpty && !byId) return;
    setState(() => _error = null);
    // Season and episode ride along in both modes: a title search for a
    // series is still a search for *this* episode's file.
    ref
        .read(subtitleSearchProvider.notifier)
        .search(
          query: query,
          imdbId: byId ? target.imdbId : null,
          tmdbId: byId ? target.tmdbId : null,
          season: target?.season,
          episode: target?.episode,
          language: ref.read(subtitleLanguageProvider),
        );
  }

  /// Empties the field and puts focus in it, for the title that comes next.
  /// The Clear button goes with the text, so focus left on it would have
  /// nowhere to be.
  void _clear() {
    _query.clear();
    _onEdited('');
    _fieldNode.requestFocus();
  }

  void _pickLanguage(String code) {
    if (code == ref.read(subtitleLanguageProvider)) return;
    ref.read(subtitleLanguageProvider.notifier).set(code);
    _search();
  }

  void _revealLanguage() {
    final context = _selectedLanguage?.context;
    if (!mounted || context == null) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: HotstarPlayerStyle.fastMotionDuration,
    );
  }

  Future<void> _apply(OnlineSubtitle subtitle) async {
    // Every result stays pressable while one downloads - a row that went
    // disabled would drop a remote's focus out of the list - so the press is
    // what is refused.
    if (_downloading) return;
    setState(() {
      _downloadingId = subtitle.id;
      _error = null;
    });
    // The episode on screen, which picks the right file out of a season pack.
    final path = await ref
        .read(subtitleSearchProvider.notifier)
        .downloadAndPrepare(
          subtitle,
          season: widget.target?.season,
          episode: widget.target?.episode,
        );
    if (!mounted) return;
    if (path == null) {
      setState(() {
        _downloadingId = null;
        _error = AppLocalizations.of(context)!.subtitleDownloadFailed;
      });
      return;
    }
    // The engine refuses side-cars for reasons the page cannot see: a disposed
    // controller, a URI the platform will not take, an addSlave that comes back
    // false. Unguarded the throw escapes an unawaited press and the download
    // never ends, leaving every result refusing presses.
    //
    // [SubtitleSearchPage.onFile] can say no as well: a file that downloaded
    // but will not read.
    var used = false;
    try {
      final onFile = widget.onFile;
      if (onFile != null) {
        used = await onFile(Uri.file(path), subtitle);
      } else {
        await widget.controller.addSubtitle(Uri.file(path));
        used = true;
      }
    } catch (_) {
      used = false;
    }
    if (!mounted) return;
    if (!used) {
      setState(() {
        _downloadingId = null;
        _error = AppLocalizations.of(context)!.subtitleDownloadFailed;
      });
      return;
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final metrics = PlayerPanelMetrics.of(context);
    final language = ref.watch(subtitleLanguageProvider);
    final results = ref.watch(subtitleSearchProvider);
    // Read beside the state it describes: the notifier assigns the mode
    // before every state write, so the pair is always of the same pass.
    final mode = ref.watch(subtitleSearchProvider.notifier).lastMode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _field(context, l10n, metrics),
        ),
        const SizedBox(height: 10),
        _languages(language, metrics),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: Text(
              error,
              style: TextStyle(
                color: const Color(0xFFEF9A9A),
                fontSize: metrics.rowDetailSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(child: _results(l10n, metrics, results, mode)),
      ],
    );
  }

  Widget _field(
    BuildContext context,
    AppLocalizations l10n,
    PlayerPanelMetrics metrics,
  ) {
    final seeded = _query.text.trim().isNotEmpty;
    // No leading search icon: the text starts at the field's left edge, in
    // line with the panel's Back button, so a remote's Down from Back lands
    // in the field rather than passing it for the languages.
    return TextField(
      controller: _query,
      focusNode: _fieldNode,
      textInputAction: TextInputAction.search,
      onChanged: _onEdited,
      // The keyboard's search key takes focus out of the field; it waits on
      // the search button, as it does when the page opens, with the results
      // one press below - not nowhere, where a remote has nothing to move.
      onSubmitted: (_) {
        _search();
        _searchButton.requestFocus();
      },
      style: TextStyle(
        color: HotstarPlayerStyle.primaryText,
        fontSize: metrics.rowLabelSize,
        fontWeight: FontWeight.w600,
      ),
      decoration: InputDecoration(
        hintText: l10n.searchSubtitleNameHint,
        hintStyle: TextStyle(
          color: metrics.mutedText,
          fontSize: metrics.rowLabelSize,
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        contentPadding: const EdgeInsets.fromLTRB(14, 14, 4, 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(
            color: HotstarPlayerStyle.focusRing,
            width: HotstarPlayerStyle.focusRingWidth,
          ),
        ),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Keyed, so Clear coming and going never moves the search button
            // to another element - and its focus with it.
            if (seeded)
              IconButton(
                key: const ValueKey<String>('clear'),
                icon: const Icon(Icons.clear_rounded),
                iconSize: metrics.iconSize,
                color: metrics.secondaryText,
                tooltip: MaterialLocalizations.of(context).clearButtonTooltip,
                style: _ringed,
                onPressed: _clear,
              ),
            IconButton(
              key: const ValueKey<String>('search'),
              icon: const Icon(Icons.search_rounded),
              iconSize: metrics.iconSize,
              color: HotstarPlayerStyle.primaryText,
              tooltip: l10n.search,
              focusNode: _searchButton,
              style: _ringed,
              onPressed: _search,
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }

  /// One chip per language, in a row that scrolls sideways - by swipe, by
  /// wheel and by the desktop arrows. Focus arriving from above or below lands
  /// on the language searched in, not on whichever chip happens to be nearest.
  Widget _languages(String selected, PlayerPanelMetrics metrics) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (inRow) {
        final selected = _selectedLanguage;
        if (!inRow || selected == null || selected.hasFocus) return;
        selected.requestFocus();
      },
      child: SizedBox(
        // The chip, plus the ring drawn outside it.
        height: metrics.chipMinHeight + 8,
        child: DesktopScrollWrapper(
          controller: _languageScroll,
          isCompact: true,
          child: SingleChildScrollView(
            controller: _languageScroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                for (final MapEntry(key: name, value: code)
                    in playerLanguages.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _LanguageChip(
                      label: name,
                      selected: code == selected,
                      focusNode: _languageNodes[code],
                      onPressed: () => _pickLanguage(code),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _results(
    AppLocalizations l10n,
    PlayerPanelMetrics metrics,
    AsyncValue<List<OnlineSubtitle>?> results,
    SubtitleSearchMode mode,
  ) {
    return switch (results) {
      AsyncLoading() => const _LoadingResults(),
      // The search reports per-provider failures through its own logging and
      // still resolves, so an error here is the provider list itself failing
      // to build - worth showing rather than swallowing.
      AsyncError(:final error) => _Empty(
        icon: Icons.error_outline_rounded,
        text: l10n.subtitleSearchFailed('$error'),
      ),
      AsyncData(value: null) => _Empty(
        icon: Icons.subtitles_rounded,
        text: l10n.subtitleSearchPrompt,
      ),
      // Empty is empty, not a missing account: OpenSubtitles runs on a
      // bundled key, so a fresh install really did search.
      AsyncData(value: final found) when found!.isEmpty => _Empty(
        icon: Icons.subtitles_off_rounded,
        text: l10n.noSubtitlesFoundTryAnother,
      ),
      AsyncData(value: final found) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // These are not what was asked for: the exact match missed and the
          // notifier widened the search on its own. Said once, above the
          // list, as text - not a stop a remote has to step over.
          if (_fallbackNote(l10n, mode) case final note?)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: Text(
                note,
                style: TextStyle(
                  color: metrics.mutedText,
                  fontSize: metrics.rowDetailSize,
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 12),
              // A remote can only move to a row that is built, and the
              // default cache runs out two rows below the fold.
              scrollCacheExtent: const ScrollCacheExtent.pixels(800),
              itemCount: found!.length,
              itemBuilder: (context, index) {
                final subtitle = found[index];
                return _ResultRow(
                  subtitle: subtitle,
                  busy: _downloadingId == subtitle.id,
                  dimmed: _downloading && _downloadingId != subtitle.id,
                  onPressed: () => _apply(subtitle),
                );
              },
            ),
          ),
        ],
      ),
    };
  }

  /// What to say above results the notifier widened to on its own, or null when
  /// they are what was asked for.
  ///
  /// The two widenings are different news and cannot share a string. An id that
  /// missed leaves title matches for this episode. The season pass is reachable
  /// with no id ever sent, and what matters there is that the list now spans
  /// the whole season, so the viewer has to find their own episode in it. An
  /// exhaustive switch, so a new mode cannot silently inherit either note.
  static String? _fallbackNote(
    AppLocalizations l10n,
    SubtitleSearchMode mode,
  ) => switch (mode) {
    SubtitleSearchMode.byId || SubtitleSearchMode.byTitle => null,
    SubtitleSearchMode.byTitleAfterIdMiss => l10n.subtitleSearchTitleFallback,
    SubtitleSearchMode.bySeasonAfterEpisodeMiss =>
      l10n.subtitleSearchSeasonFallback,
  };
}

/// A ring round an icon button while it holds focus from a remote or a
/// keyboard, bright enough to find from across a room. Never under a thumb:
/// the page puts focus on its search button as it opens, touch or not.
final ButtonStyle _ringed = ButtonStyle(
  side: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.focused) && FocusVisibility.visible
        ? const BorderSide(
            color: HotstarPlayerStyle.focusRing,
            width: HotstarPlayerStyle.focusRingWidth,
          )
        : null,
  ),
);

/// Whether [event] is one of the four presses every stop in the panel takes
/// as "activate": Select on a remote, Enter and Space on a keyboard, and A on
/// the remotes that are also game controllers.
bool _activates(KeyEvent event) {
  if (event is! KeyDownEvent) return false;
  final key = event.logicalKey;
  return key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.gameButtonA;
}

/// A language to search in.
class _LanguageChip extends StatefulWidget {
  const _LanguageChip({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.focusNode,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  State<_LanguageChip> createState() => _LanguageChipState();
}

class _LanguageChipState extends State<_LanguageChip> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final metrics = PlayerPanelMetrics.of(context);
    final focused = showFocusIndicator(context, _focused);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: Focus(
        focusNode: widget.focusNode,
        onFocusChange: (focused) {
          setState(() => _focused = focused);
          // A remote moving along the row takes the row with it - once focus
          // has settled. Focus arriving from above or below passes through
          // whichever language is nearest and is handed on to the one
          // searched in; a reveal started by the one it passed through would
          // carry the row, and the language that now holds focus, off the
          // screen.
          if (focused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted || !_focused) return;
              Scrollable.ensureVisible(
                context,
                alignment: 0.5,
                duration: HotstarPlayerStyle.fastMotionDuration,
              );
            });
          }
        },
        onKeyEvent: (node, event) {
          if (!_activates(event)) return KeyEventResult.ignored;
          widget.onPressed();
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: HotstarPlayerStyle.fastMotionDuration,
              constraints: BoxConstraints(minHeight: metrics.chipMinHeight),
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(
                horizontal: metrics.chipHorizontalPadding,
              ),
              decoration: BoxDecoration(
                color: widget.selected
                    ? HotstarPlayerStyle.accent
                    : Colors.white.withValues(alpha: _hovered ? 0.12 : 0.06),
                borderRadius: BorderRadius.circular(metrics.chipMinHeight / 2),
                border: Border.all(
                  color: focused
                      ? HotstarPlayerStyle.focusRing
                      : Colors.transparent,
                  width: HotstarPlayerStyle.focusRingWidth,
                ),
              ),
              child: Text(
                widget.label,
                style: TextStyle(
                  fontSize: metrics.chipLabelSize,
                  fontWeight: FontWeight.w700,
                  color: widget.selected ? Colors.white : metrics.secondaryText,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One result: its release name, then the language badge in its provider's
/// colour, the provider, and whether it is for the hard of hearing. One focus
/// stop, drawn like the panel's own rows.
class _ResultRow extends StatefulWidget {
  const _ResultRow({
    required this.subtitle,
    required this.busy,
    required this.dimmed,
    required this.onPressed,
  });

  final OnlineSubtitle subtitle;

  /// This result is the one downloading.
  final bool busy;

  /// Another result is downloading.
  final bool dimmed;
  final VoidCallback onPressed;

  @override
  State<_ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends State<_ResultRow> {
  bool _focused = false;
  bool _hovered = false;

  /// SubSource blue and OpenSubtitles orange, as they always were; the rest in
  /// the accent.
  Color get _providerColour {
    final source = widget.subtitle.source.toLowerCase();
    if (source.contains('subsource')) return Colors.blueAccent;
    if (source.contains('opensubtitles')) return Colors.orangeAccent;
    return HotstarPlayerStyle.accent;
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.subtitle;
    final metrics = PlayerPanelMetrics.of(context);
    return AnimatedOpacity(
      duration: HotstarPlayerStyle.fastMotionDuration,
      opacity: widget.dimmed ? 0.45 : 1,
      child: Semantics(
        button: true,
        label: subtitle.name,
        child: Focus(
          onFocusChange: (value) => setState(() => _focused = value),
          onKeyEvent: (node, event) {
            if (!_activates(event)) return KeyEventResult.ignored;
            widget.onPressed();
            return KeyEventResult.handled;
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed,
              child: AnimatedContainer(
                duration: HotstarPlayerStyle.fastMotionDuration,
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                padding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: metrics.rowVerticalPadding,
                ),
                decoration: panelRowDecoration(
                  focused: showFocusIndicator(context, _focused),
                  selected: false,
                  hovered: _hovered,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subtitle.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: HotstarPlayerStyle.primaryText,
                        fontSize: metrics.rowLabelSize,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        PanelBadge(
                          text: subtitle.language.toUpperCase(),
                          color: _providerColour,
                        ),
                        const SizedBox(width: 8),
                        // Takes the room, so the icons sit at the row's edge.
                        Expanded(
                          child: Text(
                            subtitle.source,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: metrics.secondaryText,
                              fontSize: metrics.rowDetailSize,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (subtitle.isHearingImpaired)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Tooltip(
                              message: 'SDH',
                              child: Icon(
                                Icons.hearing,
                                size: metrics.iconSize - 4,
                                color: metrics.mutedText,
                              ),
                            ),
                          ),
                        if (widget.busy)
                          SizedBox.square(
                            dimension: metrics.iconSize - 2,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        else
                          Icon(
                            Icons.download_for_offline_outlined,
                            size: metrics.iconSize,
                            color: metrics.mutedText,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the results will be, while they load.
class _LoadingResults extends StatelessWidget {
  const _LoadingResults();

  @override
  Widget build(BuildContext context) {
    final metrics = PlayerPanelMetrics.of(context);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
    );
    return Shimmer.fromColors(
      baseColor: Colors.white.withValues(alpha: 0.08),
      highlightColor: Colors.white.withValues(alpha: 0.2),
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        itemBuilder: (context, index) => Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 18,
            vertical: metrics.rowVerticalPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bar(double.infinity, metrics.rowLabelSize),
              const SizedBox(height: 8),
              Row(
                children: [
                  bar(34, metrics.rowDetailSize + 4),
                  const SizedBox(width: 8),
                  bar(70, metrics.rowDetailSize),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A state with nothing to list: an icon and what to do next.
class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final metrics = PlayerPanelMetrics.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: metrics.iconSize * 2.2, color: metrics.mutedText),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: metrics.secondaryText,
                fontSize: metrics.emptySize,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
