/// Reading what a link answered with, for the checks that decide whether a
/// source is worth opening.
///
/// A status code says only that something answered. HubCloud's 10Gbps buttons
/// answer 200 with a link generator - a web page whose script sends a browser
/// on to the file - and a player handed one gets a page, not a video. The
/// first kilobyte of an answer tells the two apart.
library;

import 'dart:convert';

/// How much of an answer the checks read: enough for a page's `<!doctype
/// html>` or a playlist's `#EXTM3U`, which both come first.
const int kProbeSniffBytes = 1024;

/// Whether [contentType] leaves room for a web page, so an answer's first
/// bytes are worth reading. A video type is taken at its word.
bool mayBeWebPage(String? contentType) {
  final type = contentType?.toLowerCase().trim() ?? '';
  return type.isEmpty || type.contains('html') || type.startsWith('text/');
}

/// Whether an answer is a web page rather than something to play.
///
/// Judged on its first bytes, not its type alone: a script that serves an HLS
/// playlist often never sets a type, and the default is text/html.
bool isWebPage(String? contentType, List<int> head) {
  if (!mayBeWebPage(contentType)) return false;
  return _pageStart.hasMatch(_leading(head));
}

/// Whether [url] is an HLS or DASH playlist, which a player seeks in by
/// segment: byte ranges do not matter to it.
bool isPlaylist(Uri url, String? contentType, List<int> head) {
  final path = url.path.toLowerCase();
  if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return true;
  final type = contentType?.toLowerCase() ?? '';
  if (type.contains('mpegurl') || type.contains('dash+xml')) return true;
  final text = _leading(head);
  return text.startsWith('#extm3u') || text.contains('<mpd');
}

/// A document's opening tag, after any leading comments.
final RegExp _pageStart = RegExp(
  r'^(?:<!--[\s\S]*?-->\s*)*<(?:!doctype\s+html|html|head|body)\b',
);

String _leading(List<int> head) => utf8
    .decode(head, allowMalformed: true)
    .replaceFirst('﻿', '')
    .trimLeft()
    .toLowerCase();
