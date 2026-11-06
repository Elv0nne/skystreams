/// The qualities an HLS stream offers, as the player's Quality tab lists
/// them, and which of them plays.
///
/// Pure, so the arithmetic is tested without an engine: the screen reads the
/// playlist, and the panel draws the rows.
library;

import '../../../core/network/link_probe_service.dart' show HlsVariant;

/// The heights [variants] offer, tallest first, each once: of several
/// variants at one height libVLC plays the highest bitrate, so one row says
/// it. A variant with no RESOLUTION says nothing about its height and is left
/// out, so a master without them offers no choice.
List<int> qualityLadderOf(Iterable<HlsVariant> variants) {
  final heights = <int>{
    for (final variant in variants)
      if (variant.height case final height? when height > 0) height,
  }.toList();
  heights.sort((a, b) => b.compareTo(a));
  return heights;
}

/// The height of [ladder] (tallest first) that plays under a cap of [cap]:
/// the tallest at or below it, or the lowest when every height is taller -
/// what libVLC and VLCKit do, measured. Null for an empty ladder.
int? heightUnderCap(int cap, List<int> ladder) {
  if (ladder.isEmpty) return null;
  for (final height in ladder) {
    if (height <= cap) return height;
  }
  return ladder.last;
}

/// The height of [ladder] nearest [videoHeight], the picture's height as the
/// engine reports it: a 1088-line decode is the 1080p rendition. Null when
/// either is unknown.
int? nearestLadderHeight(double? videoHeight, List<int> ladder) {
  if (videoHeight == null || videoHeight <= 0 || ladder.isEmpty) return null;
  var nearest = ladder.first;
  for (final height in ladder) {
    if ((height - videoHeight).abs() < (nearest - videoHeight).abs()) {
      nearest = height;
    }
  }
  return nearest;
}
