/// Side-car subtitle files: the ones a source ships beside its video, and the
/// ones a viewer brings - a file from the device, a result found online.
///
/// SkyStream reads and draws these itself (subtitle_cues.dart says why), so
/// they are tracks of this list rather than of libVLC's. Tracks embedded in
/// the video stay in libVLC's list, and the two never show at once: the
/// player screen turns libVLC's subtitle off while one of these is on.
///
/// A file is fetched when it is first put on screen, not when it is listed.
/// A source can list thirty languages, and a viewer reads one.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'subtitle_cues.dart';
import 'track_language.dart';

/// Fetches a side-car's bytes with the headers it came with, or null when
/// they cannot be had.
typedef SideCarFetch = Future<List<int>?> Function(
  Uri url,
  Map<String, String>? headers,
);

/// A side-car as a source describes it, before it is a track.
typedef SideCarSource = ({
  Uri url,
  String? label,
  String? language,
  Map<String, String>? headers,
});

/// Where a side-car came from, which decides how long it stays.
enum SideCarOrigin {
  /// Shipped with the source. Replaced whenever media is opened, since another
  /// source - or the same one, resolved again - ships its own.
  source,

  /// Brought by the viewer. Kept across a reopen of the same content - a
  /// failover, a recovery - and dropped with the content.
  viewer,
}

/// How far a side-car's cues have got.
enum SideCarStatus { idle, loading, ready, failed }

/// A side-car subtitle file.
@immutable
class SideCarTrack {
  const SideCarTrack._({
    required this.id,
    required this.url,
    required this.origin,
    this.label,
    this.language,
    this.headers,
  });

  /// Unique within its [SideCarSubtitles] for as long as that lives.
  final int id;
  final Uri url;
  final SideCarOrigin origin;

  /// What the source or the viewer called it: `English`, `movie.en.srt`.
  final String? label;

  /// The language the source declared, as it declared it.
  final String? language;

  /// Sent with every request for the file, which often sits behind the same
  /// checks as the video it came with.
  final Map<String, String>? headers;

  /// The track's language as an ISO 639-1 code, from its declared language
  /// or, when that says nothing, from its label - many sources declare none
  /// and call the file `English`.
  String? get languageCode => languageCodeOf(language) ?? languageCodeOf(label);

  @override
  String toString() => 'SideCarTrack($id, ${label ?? url})';
}

/// The side-cars of whatever is playing, and the one on screen.
class SideCarSubtitles extends ChangeNotifier {
  SideCarSubtitles({
    required SideCarFetch fetch,
    this.onUnreadable,
    String encoding = '',
  }) : _fetch = fetch,
       _encoding = encoding;

  final SideCarFetch _fetch;

  /// The code page a file that is not Unicode is read in, by libVLC's name -
  /// the viewer's setting, empty for Auto.
  ///
  /// A change reads every file already fetched again, from the bytes kept
  /// when it arrived rather than from the network, so the line on screen
  /// changes at once: a file showing as gibberish is what the setting is for.
  /// A file still on its way is read again once it has arrived.
  String get encoding => _encoding;
  set encoding(String value) {
    if (value == _encoding || _disposed) return;
    _encoding = value;
    for (final track in List.of(_tracks)) {
      if (statusOf(track) == SideCarStatus.ready) unawaited(_reread(track));
    }
  }

  String _encoding;

  /// What was fetched for each track - a file, or a playlist and its
  /// segments - by URL, for [encoding] to read again.
  final Map<int, Map<Uri, List<int>>> _bytes = {};

  /// Takes a side-car that arrived in no format read here - MicroDVD,
  /// VobSub, TTML - so libVLC can have a go at it instead. The track has
  /// left this list by the time this is called.
  final void Function(SideCarTrack track)? onUnreadable;

  final List<SideCarTrack> _tracks = [];
  final Map<int, SideCarStatus> _status = {};
  final Map<int, SubtitleTimeline> _timelines = {};
  final Map<int, Future<bool>> _loads = {};
  SideCarTrack? _active;
  int _nextId = 1;
  bool _disposed = false;

  /// Every side-car: the source's first, in its order, then the viewer's.
  List<SideCarTrack> get tracks => List.unmodifiable(_tracks);

  /// The side-car on screen, or null when none is.
  SideCarTrack? get active => _active;

  SideCarStatus statusOf(SideCarTrack track) =>
      _status[track.id] ?? SideCarStatus.idle;

  /// The active side-car's cues, as many as have arrived; empty while none is
  /// on.
  SubtitleTimeline get timeline {
    final active = _active;
    if (active == null) return SubtitleTimeline.empty;
    return _timelines[active.id] ?? SubtitleTimeline.empty;
  }

  /// Replaces the source's side-cars with [sources], for media that has just
  /// been opened, and returns the new tracks in order.
  ///
  /// The viewer's own side-cars stay, and stay on if one was. A source track
  /// that was on goes with its source, so nothing is on after this unless a
  /// viewer's track was.
  List<SideCarTrack> replaceSourceTracks(Iterable<SideCarSource> sources) {
    _tracks.removeWhere((track) {
      if (track.origin != SideCarOrigin.source) return false;
      _forget(track);
      return true;
    });
    if (_active?.origin == SideCarOrigin.source) _active = null;
    final added = [
      for (final source in sources) _create(source, SideCarOrigin.source),
    ];
    _tracks.insertAll(0, added);
    _notify();
    return added;
  }

  /// Adds a file the viewer brought.
  SideCarTrack addViewerTrack(Uri url, {String? label, String? language}) {
    final track = _create((
      url: url,
      label: label,
      language: language,
      headers: null,
    ), SideCarOrigin.viewer);
    _tracks.add(track);
    _notify();
    return track;
  }

  /// Drops every side-car, for other content.
  void clear() {
    for (final track in _tracks) {
      _forget(track);
    }
    _tracks.clear();
    _active = null;
    _notify();
  }

  /// Puts [track] on screen - or takes the side-car off, for null - fetching
  /// it first if that has not been done, from [from] outward for a playlist.
  ///
  /// It is on as soon as this is called, showing cues as they arrive.
  /// Completes with whether it could be read: when it could not, it is off
  /// again by then - and out of the list, handed to [onUnreadable], when it
  /// arrived in a format not read here.
  Future<bool> select(SideCarTrack? track, {Duration from = Duration.zero}) {
    if (track != null && !_tracks.contains(track)) return Future.value(false);
    if (_active != track) {
      _active = track;
      _notify();
    }
    if (track == null) return Future.value(true);
    return switch (statusOf(track)) {
      SideCarStatus.ready => Future.value(true),
      SideCarStatus.loading => _loads[track.id] ?? Future.value(false),
      SideCarStatus.idle || SideCarStatus.failed => _load(track, from),
    };
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  SideCarTrack _create(SideCarSource source, SideCarOrigin origin) =>
      SideCarTrack._(
        id: _nextId++,
        url: source.url,
        origin: origin,
        label: source.label,
        language: source.language,
        headers: source.headers,
      );

  void _forget(SideCarTrack track) {
    _status.remove(track.id);
    _timelines.remove(track.id);
    _loads.remove(track.id);
    _bytes.remove(track.id);
  }

  Future<bool> _load(SideCarTrack track, Duration from) {
    _status[track.id] = SideCarStatus.loading;
    _notify();
    final load = _read(track, from);
    _loads[track.id] = load;
    return load;
  }

  Future<bool> _read(SideCarTrack track, Duration from) async {
    // Gone once it has left the list: replaced by another source's, cleared
    // for other content, or the whole screen gone.
    bool gone() => _disposed || !_tracks.contains(track);

    final encoding = _encoding;
    final result = await loadSubtitleCues(
      track.url,
      (url) => _fetchKept(track, url),
      encoding: encoding,
      from: from,
      onProgress: (cues) {
        if (gone()) return;
        _timelines[track.id] = SubtitleTimeline(cues);
        if (_active == track) _notify();
      },
      cancelled: gone,
    );
    // This very load, done with: nothing to wait for.
    unawaited(_loads.remove(track.id));
    if (gone()) return false;

    if (result.failure == null) {
      _status[track.id] = SideCarStatus.ready;
      _timelines[track.id] = SubtitleTimeline(result.cues);
      _notify();
      // The viewer changed the encoding while it was on its way.
      if (_encoding != encoding) await _reread(track);
      return true;
    }

    final handOff = onUnreadable;
    if (result.failure == SubtitleLoadFailure.unreadable && handOff != null) {
      _tracks.remove(track);
      _forget(track);
      if (_active == track) _active = null;
      _notify();
      handOff(track);
      return false;
    }

    _status[track.id] = SideCarStatus.failed;
    _timelines.remove(track.id);
    if (_active == track) _active = null;
    _notify();
    return false;
  }

  /// Fetches [url] for [track], keeping what arrives for [encoding].
  Future<List<int>?> _fetchKept(SideCarTrack track, Uri url) async {
    final bytes = await _fetch(url, track.headers);
    if (bytes != null && !_disposed && _tracks.contains(track)) {
      (_bytes[track.id] ??= <Uri, List<int>>{})[url] = bytes;
    }
    return bytes;
  }

  /// Reads [track] again in [encoding], from the bytes kept for it and
  /// nothing else: a segment that never arrived stays missing, as it was.
  Future<void> _reread(SideCarTrack track) async {
    bool gone() => _disposed || !_tracks.contains(track);
    final encoding = _encoding;
    final result = await loadSubtitleCues(
      track.url,
      (url) async => _bytes[track.id]?[url],
      encoding: encoding,
      cancelled: gone,
    );
    // A later change has its own read under way.
    if (gone() || result.failure != null || encoding != _encoding) return;
    _timelines[track.id] = SubtitleTimeline(result.cues);
    if (_active == track) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

/// Index of the first entry in [languages] in the language [preferred]
/// names, or `null` when nothing matches.
///
/// Both sides are read by [languageCodeOf], so a `pt-BR` side-car satisfies
/// a `pt` preference and `eng` satisfies `en`. `und`, the code sources give
/// an unknown language, matches nothing.
int? preferredSubtitleIndex(List<String?> languages, String? preferred) {
  final want = languageCodeOf(preferred);
  if (want == null) return null;
  for (var i = 0; i < languages.length; i++) {
    if (languageCodeOf(languages[i]) == want) return i;
  }
  return null;
}

/// The track in [available] that stands for [previous] - the side-car that was
/// on before media was opened again - or null when none does.
///
/// Tried in order of how much each signal proves: the same file, which a
/// recovery of the same source gives back; the same language and label; the
/// same language, which is what a failover to another source's copy can
/// offer; and, for a source that declares no language at all, the same label.
/// A language that was known and is gone from [available] answers null rather
/// than an unrelated file that shares a label.
SideCarTrack? matchSideCar(
  List<SideCarTrack> available,
  SideCarTrack previous,
) {
  for (final track in available) {
    if (track.url == previous.url) return track;
  }
  final language = previous.languageCode;
  final label = previous.label?.trim();
  if (language != null) {
    final sameLanguage = available
        .where((track) => track.languageCode == language)
        .toList();
    for (final track in sameLanguage) {
      if (label != null && track.label?.trim() == label) return track;
    }
    return sameLanguage.firstOrNull;
  }
  if (label == null || label.isEmpty) return null;
  for (final track in available) {
    if (track.label?.trim() == label) return track;
  }
  return null;
}
