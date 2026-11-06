/// The Quality tab: which of an HLS stream's qualities plays.
///
/// Auto comes first. It is the player's own choice: the device's rung and the
/// viewer's quality preference (`renditionCapFor`). Its row names the height
/// it plays. Each height the stream offers follows, tallest first, labelled
/// as the source lists label resolutions. A row only reports the pick:
/// reopening the stream under it is the screen's to do.
///
/// One focus stop per row, like Audio's. The row in effect is ticked; the
/// list opens on it and, with [PlayerQualityTab.autofocus], focuses it.
library;

import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../core/network/link_probe_service.dart'
    show resolutionLabelFor;
import '../../../../../l10n/generated/app_localizations.dart';
import '../../../domain/hls_quality.dart';
import '../player_value_selector.dart';
import 'player_anchored_list.dart';
import 'player_panel_row.dart';

/// The row a Quality list opens on for [pick] over [ladder]: 0 for Auto,
/// else the height that plays under the pick, one row down for Auto's.
int qualityAnchorRow(int? pick, List<int> ladder) {
  if (pick == null) return 0;
  final playing = heightUnderCap(pick, ladder);
  final index = playing == null ? -1 : ladder.indexOf(playing);
  return index < 0 ? 0 : index + 1;
}

class PlayerQualityTab extends StatelessWidget {
  const PlayerQualityTab({
    required this.controller,
    required this.ladder,
    required this.onPick,
    this.pick,
    this.anchorRow = 0,
    this.autofocus = false,
    super.key,
  });

  final VlcPlayerController controller;

  /// The heights the stream offers, tallest first, each once.
  final List<int> ladder;

  /// The cap the viewer's pick asks for, or null for Auto. Drives the tick,
  /// and follows live data.
  final int? pick;

  /// The row the list opens on and, with [autofocus], focuses: the one in
  /// effect when the panel opened - see [qualityAnchorRow].
  final int anchorRow;

  /// A height, or null for Auto.
  final ValueChanged<int?> onPick;

  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final picked = pick;
    final ticked = picked == null ? null : heightUnderCap(picked, ladder);
    final anchor = anchorRow <= ladder.length ? anchorRow : 0;
    // The picture's height is the one part of the value this list draws
    // from; a position tick is not a rebuild.
    return PlayerValueSelector<double?>(
      controller: controller,
      selector: (value) => value.videoSize?.height,
      builder: (context, videoHeight) {
        final playing = picked == null
            ? nearestLadderHeight(videoHeight, ladder)
            : null;
        final rows = <Widget>[
          PanelRow(
            label: playing == null
                ? l10n.playerQualityAuto
                : l10n.playerQualityAutoPlaying(resolutionLabelFor(playing)),
            selected: picked == null,
            autofocus: autofocus && anchor == 0,
            onTap: () => onPick(null),
          ),
          for (final (index, height) in ladder.indexed)
            PanelRow(
              label: resolutionLabelFor(height),
              selected: height == ticked,
              autofocus: autofocus && anchor == index + 1,
              onTap: () => onPick(height),
            ),
        ];
        return PanelAnchoredList(
          anchorIndex: anchor,
          // A one-line row, as Audio's are without a codec line.
          estimatedRowExtent: 46,
          autofocus: autofocus,
          itemCount: rows.length,
          itemBuilder: (context, index) => rows[index],
        );
      },
    );
  }
}
