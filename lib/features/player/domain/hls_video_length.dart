/// The length of the video in an HLS stream, read off the video's own
/// playlist.
///
/// libVLC reports a master playlist's length as that of the longest playlist
/// it has loaded, alternative renditions included, selected or not. NetMirror
/// wraps each subtitle file as a playlist of one segment claiming 99,999
/// seconds, so every episode it serves read 27:46:39: the seek bar was
/// useless, the next-episode card never came, and the real ending looked like
/// a stream that died short of its length, which failed over to another
/// source instead of finishing. The video's playlist is the one that tells
/// the truth, and `VlcPlayerController.setDurationCap` takes it from here.
library;

import 'dart:convert';

/// Fetches a playlist's text, or null when it cannot be had.
typedef PlaylistFetcher = Future<String?> Function(Uri url);

/// Whether [uri] names an HLS playlist, directly or through the local proxy,
/// which carries the real address in its query.
bool looksLikeHls(Uri uri) {
  final path = uri.path.toLowerCase();
  return path.endsWith('.m3u8') ||
      path.endsWith('.m3u') ||
      uri.query.toLowerCase().contains('.m3u8');
}

/// Measures the video in the HLS stream at [url].
///
/// Null when there is nothing to correct: a media playlist, whose length is
/// the one libVLC reports anyway; a master with no alternative rendition,
/// which leaves nothing longer to load; a live stream; or a playlist that
/// could not be read. Costs one request for the master and, only when it has
/// renditions, one for the first variant.
Future<Duration?> measureHlsVideoLength(Uri url, PlaylistFetcher fetch) async {
  final master = await fetch(url);
  if (master == null) return null;
  final variant = _firstVariantBehindRenditions(master, url);
  if (variant == null) return null;
  final media = await fetch(variant);
  return media == null ? null : hlsVodLength(media);
}

/// The first variant of the master playlist [text] - resolved against [base],
/// where it came from - when the master also lists a rendition with its own
/// playlist. Null for anything else, a media playlist included.
Uri? _firstVariantBehindRenditions(String text, Uri base) {
  if (!text.trimLeft().startsWith('#EXTM3U')) return null;
  var hasRenditions = false;
  var awaitingVariant = false;
  Uri? variant;
  for (final raw in LineSplitter.split(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-MEDIA:')) {
      if (line.contains('URI="')) hasRenditions = true;
    } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
      awaitingVariant = true;
    } else if (!line.startsWith('#') && awaitingVariant) {
      variant ??= base.resolve(line);
      awaitingVariant = false;
    }
  }
  return hasRenditions ? variant : null;
}

/// The sum of a VOD media playlist's segment lengths, the way libVLC adds
/// them up: a segment without its own `#EXTINF` takes the target duration.
///
/// Null for a playlist that may still grow - no `#EXT-X-ENDLIST` and not
/// declared `VOD`, which is how libVLC tells - and for one with no segments.
Duration? hlsVodLength(String text) {
  if (!text.trimLeft().startsWith('#EXTM3U')) return null;
  var ended = false;
  var targetSeconds = 0.0;
  double? pending;
  var totalSeconds = 0.0;
  var segments = 0;
  for (final raw in LineSplitter.split(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF:')) {
      final value = line.substring('#EXTINF:'.length).split(',').first;
      pending = double.tryParse(value.trim());
    } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      targetSeconds =
          double.tryParse(line.substring('#EXT-X-TARGETDURATION:'.length)) ?? 0;
    } else if (line == '#EXT-X-ENDLIST') {
      ended = true;
    } else if (line.startsWith('#EXT-X-PLAYLIST-TYPE:')) {
      if (line.substring('#EXT-X-PLAYLIST-TYPE:'.length).trim() == 'VOD') {
        ended = true;
      }
    } else if (!line.startsWith('#')) {
      totalSeconds += pending ?? targetSeconds;
      pending = null;
      segments += 1;
    }
  }
  if (!ended || segments == 0) return null;
  return Duration(microseconds: (totalSeconds * 1000000).round());
}
