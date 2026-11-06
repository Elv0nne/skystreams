/// The Audio and Subtitles tabs.
///
/// Subtitles come from two owners, listed one after the other: the tracks
/// inside the video, which libVLC draws, and subtitle files, which SkyStream
/// reads and draws itself ([SideCarSubtitles]). At most one of them is on, so
/// picking from either side takes the other side's off first.
///
/// The engine owns its track list and its selection: nothing here caches,
/// mirrors or merges either. `VlcPlayerValue.activeAudioTrackId` and
/// `activeSubtitleTrackId` say which track is rendering right now, every
/// native re-sends its snapshot after a set/disable/add, and the tick is read
/// straight off the controller, so a set the engine refuses never moves it.
/// `null` is "none" - libVLC's `-1` is normalised in the package.
///
/// A row's `onTap` is unawaited, so every engine call goes through `_setTrack`
/// or `_step`, which absorb the refusal rather than throw it into the zone. A
/// refused set also re-reads the list, because a refusal is the engine saying
/// the row should not have been there. Nothing re-reads after `addSubtitle` -
/// see [PlayerTracksTab.onTracksChanged].
///
/// What this adds over the engine is naming. libVLC hands back `Track 3` far
/// more often than it hands back anything a viewer could choose between, so
/// the language and codec from `getMediaInfo` are folded in beside the
/// description — see [trackLabel].
///
/// Focus lands once, on open, on the row that is active then: Flutter applies
/// an autofocus only while the scope has no focused child, so a row that
/// autofocuses on a later rebuild is harmless and needs no bookkeeping. That
/// row also has to be on screen, and a lazily-inflated list never runs its
/// builder for a row twenty down, so both lists go through
/// [PanelAnchoredList], which seeds the opening offset from the anchor,
/// centres it against real geometry a frame later and rescues focus into the
/// list if no row took it. The tab's job is to say which flattened child index
/// the anchor is - see `_list`.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../l10n/generated/app_localizations.dart';
import '../../../../settings/presentation/player_settings_provider.dart';
import '../../../../settings/presentation/widgets/subtitle_appearance_settings.dart';
import '../../../domain/side_car_subtitles.dart';
import '../../../domain/subtitle_search_target.dart';
import '../../../domain/track_language.dart';
import '../../../domain/track_memory.dart';
import '../player_value_selector.dart';
import 'player_anchored_list.dart';
import 'player_panel_labels.dart';
import 'player_panel_page.dart';
import 'player_panel_row.dart';
import 'player_subtitle_search_page.dart';
import 'player_subtitle_style_page.dart';

/// Which list a tab is showing. The two differ by more than a title: only
/// subtitles have an Off and two ways to add a track from outside.
enum PlayerTrackKind { audio, subtitle }

/// How far one press of a delay stepper moves. A tenth of a second is the
/// finest a viewer can judge against the picture, and the same step serves
/// audio and subtitle delay alike.
const Duration kSubtitleDelayStep = Duration(milliseconds: 100);

/// How far a held key moves per repeat. Half a second is the largest step
/// that cannot overshoot a badly muxed track in one go, and at a remote's
/// repeat rate it crosses two seconds in one lean.
const Duration kSubtitleDelayCoarseStep = Duration(milliseconds: 500);

Duration delayStepFor(PanelStep step) => switch (step) {
  PanelStep.fine => kSubtitleDelayStep,
  PanelStep.coarse => kSubtitleDelayCoarseStep,
};

/// The stepper's read-out for a delay: whole milliseconds under a second
/// (`+100ms`, `-500ms`), one decimal of seconds from there (`+1.5s`). Always
/// signed, so `+0ms` reads as a state and not a blank.
String delayLabel(Duration delay) {
  final ms = delay.inMilliseconds;
  final sign = ms < 0 ? '-' : '+';
  final magnitude = ms.abs();
  if (magnitude < 1000) return '$sign${magnitude}ms';
  return '$sign${(magnitude / 1000).toStringAsFixed(1)}s';
}

class PlayerTracksTab extends StatelessWidget {
  const PlayerTracksTab({
    required this.controller,
    required this.kind,
    required this.tracks,
    required this.trackInfo,
    required this.onTracksChanged,
    required this.onOpenPage,
    this.onTrackAdded,
    this.sideCars,
    this.target,
    this.searchFocusNode,
    this.subtitleStyle,
    this.styleFocusNode,
    this.isTv = false,
    this.autofocus = false,
    this.onAudioPicked,
    super.key,
  });

  final VlcPlayerController controller;
  final PlayerTrackKind kind;

  /// The engine's own descriptions, in the engine's own order.
  final List<VlcTrackDescription> tracks;

  /// `getMediaInfo`'s view of the same tracks, which carries the codec and
  /// channel count the descriptions lack. Correlated by position because that
  /// is the only correlation libVLC offers; a short list simply means the tail
  /// rows show no detail.
  final List<VlcMediaTrackInfo> trackInfo;

  /// Asks the panel to read both track lists from the engine again.
  ///
  /// Not fired after an add, which is the one moment it looks due. libVLC 3's
  /// add-slave is queued to the input thread: `addSubtitle` returns once the
  /// request is posted, not once the ES exists, so a list read in the same
  /// turn is still the pre-add one, and publishing it would re-anchor the list
  /// and the D-pad focus on the wrong row ([PanelAnchoredList] re-centres on
  /// every reload).
  ///
  /// The reload waits for the engine instead. Every native moves
  /// `trackRevision` when the ES actually lands, and the panel re-reads on
  /// that revision without being asked (player_panel.dart, `_onEngine`).
  ///
  /// What is left for this callback is Retry - the manual fallback for an
  /// engine that never said - and a refused set, which means the list on
  /// screen is out of date (see `_setTrack`).
  final VoidCallback onTracksChanged;

  /// Tells the panel a track the viewer brought is on its way to the engine.
  /// The list that first shows it re-anchors on what is playing then, as a
  /// reload does, so the remote lands on the file just picked; every other
  /// revision move keeps the rows where the viewer had them.
  final VoidCallback? onTrackAdded;

  /// Opens a second step in the panel's place: the online search. See
  /// [PanelPage].
  final ValueChanged<PanelPage> onOpenPage;

  /// The Search online row's focus stop, held by the panel so Back from the
  /// search can hand focus back to that row wherever the list has moved it -
  /// a file the search added is listed ahead of it.
  final FocusNode? searchFocusNode;

  /// The viewer's subtitle settings, for the Subtitle style row and the page
  /// it opens. Handed down from the screen rather than read here: the panel
  /// reads no providers. Null where there is no screen behind the panel, and
  /// then there is no row.
  final SubtitleStyleBinding? subtitleStyle;

  /// The Subtitle style row's focus stop, held by the panel for the same
  /// reason as [searchFocusNode].
  final FocusNode? styleFocusNode;

  /// The subtitle files SkyStream draws, listed after the video's own tracks.
  /// Null only where there is no screen behind the panel to draw them; files
  /// the viewer adds then go to libVLC.
  final SideCarSubtitles? sideCars;

  /// What the online search is about: the screen's title, ids and episode.
  /// Null for media the catalogue knows nothing of, where the engine's own
  /// metadata seeds a title-only search instead.
  final SubtitleSearchTarget? target;

  final bool isTv;
  final bool autofocus;

  /// The audio track the viewer just picked from this tab, with the language
  /// its media info gives - see [withTrackLanguage].
  ///
  /// The engine selects audio too - as media opens, on a reopen, for the audio
  /// language setting - and a row tap is the one selection that is the
  /// viewer's own, which the screen keeps for the rest of the content.
  ///
  /// Reported before the engine is asked, so that nothing the screen still
  /// had due can be sent after it: a look of its own, already past its last
  /// check when the viewer's set went out, would otherwise follow it to the
  /// engine and win. A pick the engine refuses is reported all the same - it
  /// is still what the viewer asked for.
  final ValueChanged<VlcTrackDescription>? onAudioPicked;

  bool get _isAudio => kind == PlayerTrackKind.audio;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // libVLC's own `Disable` pseudo-track. Subtitles get a real Off row below
    // and audio has no use for one, so it is never a row of its own.
    final listed = tracks.where((track) => track.id >= 0).toList();

    // The active id and the revision are the only two things in the value
    // this list draws from; a position tick every 250 ms is not a rebuild.
    Widget engineList() => PlayerValueSelector<(int?, int)>(
      controller: controller,
      selector: (value) => (
        _isAudio ? value.activeAudioTrackId : value.activeSubtitleTrackId,
        value.trackRevision,
      ),
      builder: (context, selected) => _list(context, l10n, listed, selected.$1),
    );

    final files = sideCars;
    if (_isAudio || files == null) return engineList();
    return ListenableBuilder(
      listenable: files,
      builder: (context, _) => engineList(),
    );
  }

  Widget _list(
    BuildContext context,
    AppLocalizations l10n,
    List<VlcTrackDescription> listed,
    int? active,
  ) {
    final files = _isAudio
        ? const <SideCarTrack>[]
        : sideCars?.tracks ?? const <SideCarTrack>[];
    final activeFile = _isAudio ? null : sideCars?.active;
    // The engine's tick stands only while no file is on: the two are never on
    // together, and for the moment it takes libVLC to drop its own after a
    // file goes on, the file is the one on screen.
    final engineActive = activeFile == null ? active : null;

    // Focus has to land somewhere: the active row, or - when nothing is on or
    // the engine names a track the list has not caught up with - Off for
    // subtitles and the first row for audio. The tick is stricter and follows
    // the engine alone.
    final known =
        engineActive != null && listed.any((track) => track.id == engineActive);

    // The same answers as positions in the flattened child list, which is what
    // [PanelAnchoredList] scrolls to. Only subtitles have an Off row ahead of
    // the tracks, and an empty list puts a note where they were.
    final leading = _isAudio ? 0 : 1;
    final empty = listed.isEmpty && files.isEmpty;
    final filesStart = leading + listed.length;
    final retryIndex = empty ? leading + 1 : filesStart + files.length;
    final activeFileIndex = activeFile == null ? -1 : files.indexOf(activeFile);
    final anchor = activeFileIndex >= 0
        ? filesStart + activeFileIndex
        : known
        ? leading + listed.indexWhere((track) => track.id == engineActive)
        : (_isAudio ? (listed.isEmpty ? retryIndex : 0) : 0);

    // Each row keeps its element, and the focus on it, while rows above it
    // come and go: HLS with WebVTT makes its subtitle track again at every
    // segment, and for a while the list holds one track more. A track is
    // known by its label, the n-th row of that label, as the viewer reads the
    // list, so one made again under a new id keeps its row.
    Widget keyed(Object id, Widget row) =>
        KeyedSubtree(key: ValueKey<Object>(id), child: row);
    final labels = [
      for (final (index, track) in listed.indexed)
        trackLabel(track, _infoFor(index), l10n),
    ];
    final seen = <String, int>{};
    final trackIds = <Object>[
      for (final label in labels)
        ('track', label, seen[label] = (seen[label] ?? -1) + 1),
    ];

    final children = <Widget>[
      if (!_isAudio)
        keyed(
          'off',
          PanelRow(
            label: l10n.off,
            icon: Icons.subtitles_off_outlined,
            selected: engineActive == null && activeFile == null,
            autofocus: autofocus && anchor == 0,
            onTap: () => unawaited(
              _setTrack(context, () async {
                await sideCars?.select(null);
                await controller.disableSubtitle();
              }),
            ),
          ),
        ),
      if (empty)
        keyed(
          'none',
          PanelEmpty(
            text: _isAudio ? l10n.noAudioTracksReported : l10n.noSubtitlesFound,
          ),
        )
      else ...[
        for (final (index, track) in listed.indexed)
          keyed(
            trackIds[index],
            PanelRow(
              label: labels[index],
              detail: trackDetail(_infoFor(index)),
              selected: engineActive == track.id,
              autofocus: autofocus && anchor == leading + index,
              onTap: () => unawaited(
                _setTrack(context, () async {
                  if (_isAudio) {
                    onAudioPicked?.call(
                      withTrackLanguage(track, _infoFor(index)),
                    );
                    await controller.setAudioTrack(track.id);
                    return;
                  }
                  await sideCars?.select(null);
                  await controller.setSubtitleTrack(track.id);
                }),
              ),
            ),
          ),
        for (final (index, file) in files.indexed)
          keyed(
            ('file', file),
            PanelRow(
              label: sideCarLabel(file, index, l10n),
              detail: switch (sideCars!.statusOf(file)) {
                SideCarStatus.loading => l10n.loading,
                SideCarStatus.failed => l10n.failed,
                _ => null,
              },
              selected: activeFile == file,
              autofocus: autofocus && anchor == filesStart + index,
              onTap: () => unawaited(_showFile(file)),
            ),
          ),
      ],
      // Tracks can arrive after the panel opened. The panel re-reads the list
      // when the engine's revision moves; this is the manual fallback for an
      // engine that did not say, and the only row an empty Audio tab has.
      keyed(
        'retry',
        PanelRow(
          label: l10n.retry,
          icon: Icons.refresh_rounded,
          autofocus: autofocus && anchor == retryIndex,
          onTap: onTracksChanged,
        ),
      ),
      if (_isAudio)
        for (final (n, row) in _audioExtras(l10n).indexed)
          keyed(('extra', n), row)
      else
        for (final (n, row) in _subtitleExtras(context, l10n).indexed)
          keyed(('extra', n), row),
    ];

    // The widget objects are built eagerly; handing them to the builder keeps
    // the elements lazy, which is why the anchor has to be scrolled to.
    return PanelAnchoredList(
      anchorIndex: anchor,
      // A one-line row is ~46 px and one carrying a codec detail ~60; the
      // middle keeps the anchor inside the viewport's 800 px cache for a far
      // longer list than either end would, and the frame-one centring corrects
      // it against real geometry anyway.
      estimatedRowExtent: 53,
      autofocus: autofocus,
      itemCount: children.length,
      itemBuilder: (context, index) => children[index],
      findChildIndexCallback: (key) {
        final index = children.indexWhere((row) => row.key == key);
        return index < 0 ? null : index;
      },
    );
  }

  VlcMediaTrackInfo? _infoFor(int index) =>
      index < trackInfo.length ? trackInfo[index] : null;

  /// Runs the engine call behind a row tap - a set, or Off.
  ///
  /// Nothing here is optimistic, so a refusal needs no rollback; what it needs
  /// is somewhere to land. A row's `onTap` is unawaited and the app installs
  /// no `PlatformDispatcher.onError`, so a bare `controller.setAudioTrack(id)`
  /// hands its failure to the zone and it is a console trace and nothing else.
  ///
  /// A refusal also means the list has moved on - a stream renegotiated, a
  /// language dropped - since the id came from a list read once and held
  /// since. So the list is read again.
  ///
  /// A switch only selects: nothing seeks. libVLC plays the new track one
  /// caching interval later, a second on demand; the seek that used to
  /// follow cost a rebuffer and could land on top of a seek of the viewer's.
  Future<void> _setTrack(
    BuildContext context,
    Future<void> Function() call,
  ) async {
    try {
      await call();
    } on VlcPlayerException catch (_) {
      // The panel can be closed, or the list already re-read under us, while
      // the call is in flight; a reload then belongs to nobody.
      if (context.mounted) onTracksChanged();
    }
  }

  /// Puts a subtitle file on screen - at once, filling in as it arrives - and
  /// takes libVLC's own subtitle off. Completes with whether the file could
  /// be read, which for one handed to libVLC means handed over.
  Future<bool> _showFile(SideCarTrack file) async {
    final files = sideCars!;
    final shown = files.select(file, from: controller.value.position);
    try {
      await controller.disableSubtitle();
    } on VlcPlayerException catch (_) {
      // The screen keeps libVLC's subtitle off under a file anyway; this only
      // saves the wait for its next tick.
    }
    return await shown || !files.tracks.contains(file);
  }

  /// A file the viewer brought, from the device or a search: SkyStream draws
  /// it when there is a screen to, libVLC otherwise.
  Future<bool> _addFile(Uri file, {String? label, String? language}) async {
    final files = sideCars;
    if (files == null) {
      await controller.addSubtitle(file);
      onTrackAdded?.call();
      return true;
    }
    return _showFile(
      files.addViewerTrack(file, label: label, language: language),
    );
  }

  /// Runs a delay call. Same absorption as [_setTrack], and for the same
  /// reason, but no reload: the stepper reads
  /// `value.audioDelay`/`value.subtitleDelay`, so a refused delay is a
  /// read-out that does not move.
  Future<void> _step(Future<void> Function() call) async {
    try {
      await call();
    } on VlcPlayerException catch (_) {
      // Absorbed on purpose: see above.
    }
  }

  /// The one runtime adjustment libVLC exposes for audio: a delay against the
  /// picture, for a stream muxed out of step.
  List<Widget> _audioExtras(AppLocalizations l10n) {
    return <Widget>[
      PanelSubheader(title: l10n.audioDelay),
      _delayStepper(
        label: l10n.audioDelay,
        select: (value) => value.audioDelay,
        apply: controller.setAudioDelay,
      ),
    ];
  }

  /// The two ways a subtitle the stream does not carry gets on screen, the
  /// delay, which moves files and the video's own tracks alike, and how they
  /// look.
  ///
  /// Both entry points end at [_addFile], which lists the file and turns it
  /// on, so neither needs anywhere to put its result.
  List<Widget> _subtitleExtras(BuildContext context, AppLocalizations l10n) {
    final style = subtitleStyle;
    return <Widget>[
      PanelSubheader(title: l10n.subtitleOptions),
      PanelRow(
        label: l10n.loadSubtitleFile,
        icon: Icons.file_open_outlined,
        onTap: () => unawaited(_loadFromDevice()),
      ),
      PanelRow(
        label: l10n.searchSubtitlesOnline,
        icon: Icons.search_rounded,
        focusNode: searchFocusNode,
        onTap: () => unawaited(_searchOnline(context, l10n)),
      ),
      _delayStepper(
        label: l10n.subtitleDelay,
        select: (value) => value.subtitleDelay,
        apply: controller.setSubtitleDelay,
      ),
      if (style != null) _styleRow(l10n, style),
    ];
  }

  /// Opens the Subtitle style page, and says what the size and the colour
  /// are now.
  Widget _styleRow(AppLocalizations l10n, SubtitleStyleBinding style) {
    return ValueListenableBuilder<PlayerSettings>(
      valueListenable: style.settings,
      builder: (context, settings, _) => PanelRow(
        label: l10n.subtitleStyle,
        icon: Icons.text_format_rounded,
        detail: l10n.subtitleStyleSummary(
          settings.subtitleSize.round(),
          subtitleColorLabel(l10n, settings.subtitleColor),
        ),
        focusNode: styleFocusNode,
        onTap: () => onOpenPage(
          PanelPage(
            title: l10n.subtitleStyle,
            builder: (context, close) => SubtitleStylePage(style: style),
          ),
        ),
      ),
    );
  }

  /// A delay stepper that follows the engine's own value - the natives echo a
  /// delay on the next snapshot - and rebuilds on that alone, not on every
  /// position tick.
  Widget _delayStepper({
    required String label,
    required Duration Function(VlcPlayerValue value) select,
    required Future<void> Function(Duration delay) apply,
  }) {
    return PlayerValueSelector<Duration>(
      controller: controller,
      selector: select,
      builder: (context, delay) => PanelStepperRow(
        label: label,
        value: delayLabel(delay),
        increasedValue: delayLabel(delay + delayStepFor(PanelStep.fine)),
        decreasedValue: delayLabel(delay - delayStepFor(PanelStep.fine)),
        onDecrease: (step) =>
            unawaited(_step(() => apply(delay - delayStepFor(step)))),
        onIncrease: (step) =>
            unawaited(_step(() => apply(delay + delayStepFor(step)))),
        onReset: delay == Duration.zero
            ? null
            : () => unawaited(_step(() => apply(Duration.zero))),
      ),
    );
  }

  Future<void> _loadFromDevice() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa', 'sub'],
    );
    final path = picked?.path;
    if (path == null) return;
    try {
      await _addFile(Uri.file(path), label: picked?.name);
    } on VlcPlayerException catch (_) {
      // A file the engine will not take. Absorbed like every other engine
      // call here (see [_setTrack]): the handler is unawaited, and the list is
      // about to say the track is not there.
    }
    // Deliberately no reload here - see the note on [onTracksChanged].
  }

  /// Opens the search as the panel's second step. Done or backed out of, it
  /// ends on this list again: a viewer who backed out still wants the tracks
  /// they opened it from, and one who picked a result sees it ticked here.
  /// Nothing is re-read when it closes: a pick ends at the same queued
  /// `addSubtitle`, with the problem described on [onTracksChanged].
  Future<void> _searchOnline(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final seed = await _searchSeed();
    if (!context.mounted) return;
    final files = sideCars;
    onOpenPage(
      PanelPage(
        title: l10n.searchSubtitlesOnline,
        builder: (context, close) => SubtitleSearchPage(
          controller: controller,
          target: seed,
          isTv: isTv,
          onFile: files == null
              ? null
              : (file, subtitle) => _addFile(
                  file,
                  label: subtitle.name.isEmpty ? null : subtitle.name,
                  language: subtitle.language,
                ),
          onDone: close,
        ),
      ),
    );
  }

  /// The screen's target when it has one; otherwise the engine's title alone,
  /// so a local file keeps its filename as the seed and nothing fires on open.
  Future<SubtitleSearchTarget?> _searchSeed() async {
    final given = target;
    if (given != null) return given;
    try {
      final title = (await controller.getMediaInfo()).title;
      return SubtitleSearchTarget(title: title ?? '');
    } catch (_) {
      // A seed is a convenience; an engine that will not answer is not a
      // reason to refuse to open the search.
      return null;
    }
  }
}

/// A subtitle file's row: what the source or the viewer called it, else its
/// language, else the file's own name - and a number only when there is none
/// of those.
String sideCarLabel(SideCarTrack file, int index, AppLocalizations l10n) {
  final label = file.label?.trim();
  if (label != null && label.isNotEmpty) return label;
  final language = languageNameForCode(file.languageCode ?? '');
  if (language != null) return language;
  final name = file.url.pathSegments.lastOrNull;
  if (name != null && name.isNotEmpty) return Uri.decodeComponent(name);
  return l10n.playerTrackNumber(index + 1);
}
