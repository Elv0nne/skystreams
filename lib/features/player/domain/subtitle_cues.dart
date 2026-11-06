/// Subtitle files SkyStream draws itself, read into timed cues.
///
/// libVLC draws subtitles into the picture, so they shared its fate: Zoom
/// pushed lines off the screen, Stretch squashed them, and a file libVLC could
/// not open - an HLS subtitle playlist, or one served only with the right
/// headers - showed nothing at all. Side-car files are read here instead and
/// the player screen draws them over the video at the size the viewer chose,
/// whatever the fit. Tracks embedded in the video stay with libVLC.
///
/// Reads SubRip, WebVTT - HLS subtitle playlists included - and the dialogue
/// of SubStation Alpha and Advanced SubStation Alpha: the text, its italics
/// and bold, and whether a line sits at the bottom, the middle or the top.
/// Exact positions, colours, fonts, karaoke and drawings are left out.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'subtitle_code_pages.dart';

/// Where on the screen a cue sits.
enum SubtitlePlacement { bottom, middle, top }

/// A run of a cue's text in one style. Line breaks are `\n`s in [text].
@immutable
class SubtitleSpan {
  const SubtitleSpan(this.text, {this.italic = false, this.bold = false});

  final String text;
  final bool italic;
  final bool bold;

  @override
  bool operator ==(Object other) =>
      other is SubtitleSpan &&
      other.text == text &&
      other.italic == italic &&
      other.bold == bold;

  @override
  int get hashCode => Object.hash(text, italic, bold);

  @override
  String toString() =>
      'SubtitleSpan(${jsonEncode(text)}'
      '${italic ? ', italic' : ''}${bold ? ', bold' : ''})';
}

/// Text on screen from [start] until just before [end].
@immutable
class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.spans,
    this.placement = SubtitlePlacement.bottom,
  });

  final Duration start;
  final Duration end;
  final List<SubtitleSpan> spans;
  final SubtitlePlacement placement;

  /// The cue's text without its styling.
  String get text => spans.map((span) => span.text).join();

  SubtitleCue _shifted(Duration by) => by == Duration.zero
      ? this
      : SubtitleCue(
          start: start + by,
          end: end + by,
          spans: spans,
          placement: placement,
        );

  @override
  bool operator ==(Object other) =>
      other is SubtitleCue &&
      other.start == start &&
      other.end == end &&
      other.placement == placement &&
      listEquals(other.spans, spans);

  @override
  int get hashCode => Object.hash(start, end, placement, Object.hashAll(spans));

  @override
  String toString() => 'SubtitleCue($start - $end, ${placement.name}, $spans)';
}

/// A subtitle file's cues in start order, answering which are on screen when.
class SubtitleTimeline {
  factory SubtitleTimeline(Iterable<SubtitleCue> cues) {
    final given = cues.toList(growable: false);
    // Cues that start together keep their file order, which is the order they
    // stack in; List.sort alone is not stable.
    final order = List<int>.generate(given.length, (i) => i)
      ..sort((a, b) {
        final byStart = given[a].start.compareTo(given[b].start);
        return byStart != 0 ? byStart : a.compareTo(b);
      });
    final sorted = [for (final i in order) given[i]];
    final reach = <Duration>[];
    var furthest = Duration.zero;
    for (final cue in sorted) {
      if (cue.end > furthest) furthest = cue.end;
      reach.add(furthest);
    }
    return SubtitleTimeline._(List.unmodifiable(sorted), reach);
  }

  SubtitleTimeline._(this.cues, this._reach);

  static final SubtitleTimeline empty = SubtitleTimeline(const []);

  /// Every cue, ordered by start.
  final List<SubtitleCue> cues;

  /// The latest end among the cues up to each index, which tells [at] when
  /// nothing further back can still be on screen.
  final List<Duration> _reach;

  bool get isEmpty => cues.isEmpty;

  /// When after [position] the cues on screen next change - a cue starting or
  /// one ending - or null when nothing changes again.
  Duration? nextChange(Duration position) {
    Duration? next;
    final starting = _firstStartAfter(position);
    if (starting < cues.length) next = cues[starting].start;
    for (final cue in at(position)) {
      if (next == null || cue.end < next) next = cue.end;
    }
    return next;
  }

  /// The index of the first cue starting after [position].
  int _firstStartAfter(Duration position) {
    var low = 0;
    var high = cues.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (cues[middle].start <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// The cues on screen at [position], in start order.
  List<SubtitleCue> at(Duration position) {
    final low = _firstStartAfter(position);
    final showing = <SubtitleCue>[];
    for (var i = low - 1; i >= 0 && _reach[i] > position; i--) {
      if (cues[i].end > position) showing.add(cues[i]);
    }
    return showing.reversed.toList(growable: false);
  }
}

/// The cues of the subtitle file [text], or null when it is in none of the
/// formats read here.
List<SubtitleCue>? parseSubtitles(String text) {
  final body = _withoutBom(text);
  if (body.trimLeft().startsWith('WEBVTT')) return _parseVtt(body).cues;
  if (_assSection.hasMatch(body)) return _parseAss(body);
  if (body.contains('-->')) return _readCueBlocks(_lines(body), 0);
  return null;
}

/// The code page a file that is not Unicode is read in when the viewer has
/// chosen none: the usual legacy encoding of Western subtitle files.
const String _kAutoCodePage = 'Windows-1252';

/// The text of a subtitle file's [bytes]: UTF-8 or UTF-16 when a byte order
/// mark says so, UTF-8 when the bytes are valid UTF-8, and otherwise the code
/// page [encoding] names - libVLC's name for it, a key of [subtitleCodePages]
/// - or Windows-1252 for Auto (empty) and for a name not known here.
///
/// A byte order mark and valid UTF-8 win over [encoding]: a Unicode file read
/// as a code page is garbage, and a chosen code page is for the files that
/// are not Unicode.
String decodeSubtitleBytes(List<int> bytes, {String encoding = ''}) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _utf16(bytes, bigEndian: false);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _utf16(bytes, bigEndian: true);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    final page =
        subtitleCodePages[encoding] ?? subtitleCodePages[_kAutoCodePage]!;
    return String.fromCharCodes([
      for (final byte in bytes) byte < 0x80 ? byte : page[(byte & 0xFF) - 0x80],
    ]);
  }
}

/// A segment of an HLS subtitle playlist.
@immutable
class SubtitleSegment {
  const SubtitleSegment(this.url, this.start);

  final Uri url;

  /// Where the segment starts on the playlist's clock.
  final Duration start;
}

/// The segments of the HLS media playlist [text], fetched from [base] - or
/// null when [text] is a master playlist or no playlist at all.
List<SubtitleSegment>? hlsSubtitleSegments(String text, Uri base) {
  if (!text.trimLeft().startsWith('#EXTM3U')) return null;
  final segments = <SubtitleSegment>[];
  var clock = Duration.zero;
  var targetSeconds = 0.0;
  double? pending;
  for (final raw in LineSplitter.split(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXT-X-STREAM-INF:')) return null;
    if (line.startsWith('#EXTINF:')) {
      final value = line.substring('#EXTINF:'.length).split(',').first;
      pending = double.tryParse(value.trim());
    } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      targetSeconds =
          double.tryParse(line.substring('#EXT-X-TARGETDURATION:'.length)) ?? 0;
    } else if (!line.startsWith('#')) {
      final Uri url;
      try {
        url = base.resolve(line);
      } on FormatException {
        pending = null;
        continue;
      }
      segments.add(SubtitleSegment(url, clock));
      final seconds = pending ?? targetSeconds;
      clock += Duration(microseconds: (seconds * 1000000).round());
      pending = null;
    }
  }
  return segments;
}

/// Joins the segments of an HLS subtitle playlist, given in playlist order,
/// into one list of cues.
///
/// WebVTT segments are placed on the video's clock by their
/// `X-TIMESTAMP-MAP`, measured from the first segment's, and a cue repeated
/// in the segments it straddles is kept once.
List<SubtitleCue> joinSubtitleSegments(Iterable<String> segments) {
  final join = _SegmentJoin();
  segments.forEach(join.add);
  return join.cues;
}

/// Fetches the bytes at [url], or null when they cannot be had.
typedef SubtitleFetcher = Future<List<int>?> Function(Uri url);

/// How many segments of a subtitle playlist are fetched at once.
const int _kSegmentFetches = 4;

/// How often [loadSubtitleCues] hands over the cues of a playlist it is still
/// fetching.
const Duration _kProgressInterval = Duration(milliseconds: 500);

/// Why a subtitle file gave no cues.
enum SubtitleLoadFailure {
  /// Nothing could be fetched - or the load was cancelled first.
  unavailable,

  /// The file arrived, but in no format read here, or with no cues in it.
  unreadable,
}

/// What reading a subtitle file came to: its cues, or why there are none.
typedef SubtitleLoad = ({List<SubtitleCue> cues, SubtitleLoadFailure? failure});

SubtitleLoad _failed(SubtitleLoadFailure failure) =>
    (cues: const <SubtitleCue>[], failure: failure);

/// Reads the subtitle file at [url]: a plain file, or an HLS subtitle playlist
/// whose segments are fetched and joined.
///
/// A playlist's cues also arrive in [onProgress] while its segments come in,
/// nearest [from] first, so a video resumed an hour in does not wait for the
/// hour before it. [cancelled] is asked between fetches and stops them once
/// it says so.
///
/// A file that is not Unicode is read in the code page [encoding] names - see
/// [decodeSubtitleBytes].
Future<SubtitleLoad> loadSubtitleCues(
  Uri url,
  SubtitleFetcher fetch, {
  Duration from = Duration.zero,
  void Function(List<SubtitleCue> cues)? onProgress,
  bool Function()? cancelled,
  String encoding = '',
}) async {
  bool stopped() => cancelled?.call() ?? false;

  final bytes = await _fetchQuietly(fetch, url);
  if (bytes == null || stopped()) {
    return _failed(SubtitleLoadFailure.unavailable);
  }
  final text = decodeSubtitleBytes(bytes, encoding: encoding);
  if (!text.trimLeft().startsWith('#EXTM3U')) {
    final cues = parseSubtitles(text);
    if (cues == null || cues.isEmpty) {
      return _failed(SubtitleLoadFailure.unreadable);
    }
    return (cues: cues, failure: null);
  }

  final segments = hlsSubtitleSegments(text, url);
  if (segments == null || segments.isEmpty) {
    return _failed(SubtitleLoadFailure.unreadable);
  }
  final join = _SegmentJoin();
  var fetched = 0;

  Future<void> fetchSegment(int index) async {
    final segment = await _fetchQuietly(fetch, segments[index].url);
    if (segment == null || stopped()) return;
    fetched++;
    join.add(decodeSubtitleBytes(segment, encoding: encoding));
  }

  // The first segment's timestamp map is the clock every other segment is
  // placed on, so it is fetched before the rest.
  await fetchSegment(0);
  if (stopped()) return _failed(SubtitleLoadFailure.unavailable);
  if (segments.length > 1) {
    onProgress?.call(List.of(join.cues));
    var at = segments.lastIndexWhere((segment) => segment.start <= from);
    if (at < 1) at = 1;
    final order = [
      for (var i = at; i < segments.length; i++) i,
      for (var i = at - 1; i >= 1; i--) i,
    ];
    var next = 0;
    final sinceProgress = Stopwatch()..start();
    Future<void> worker() async {
      while (next < order.length && !stopped()) {
        await fetchSegment(order[next++]);
        if (onProgress != null &&
            !stopped() &&
            sinceProgress.elapsed >= _kProgressInterval) {
          sinceProgress.reset();
          onProgress(List.of(join.cues));
        }
      }
    }

    await Future.wait([for (var i = 0; i < _kSegmentFetches; i++) worker()]);
  }
  if (stopped() || fetched == 0) {
    return _failed(SubtitleLoadFailure.unavailable);
  }
  if (join.cues.isEmpty) return _failed(SubtitleLoadFailure.unreadable);
  return (cues: join.cues, failure: null);
}

Future<List<int>?> _fetchQuietly(SubtitleFetcher fetch, Uri url) async {
  try {
    return await fetch(url);
  } catch (_) {
    return null;
  }
}

/// Cues gathered from a subtitle playlist's segments, in whatever order they
/// arrive.
class _SegmentJoin {
  _TimestampMap? _reference;
  final Set<SubtitleCue> _seen = {};
  final List<SubtitleCue> cues = [];

  void add(String text) {
    final body = _withoutBom(text);
    if (body.trimLeft().startsWith('WEBVTT')) {
      final vtt = _parseVtt(body);
      final map = vtt.map;
      var shift = Duration.zero;
      if (map != null) {
        final reference = _reference ??= map;
        shift = map.offsetFrom(reference);
      }
      for (final cue in vtt.cues) {
        _keep(cue._shifted(shift));
      }
    } else {
      (parseSubtitles(body) ?? const <SubtitleCue>[]).forEach(_keep);
    }
  }

  void _keep(SubtitleCue cue) {
    if (_seen.add(cue)) cues.add(cue);
  }
}

/// A WebVTT segment's `X-TIMESTAMP-MAP`: the MPEG-2 timestamp, in 90 kHz
/// ticks, that its cue time [local] stands for.
@immutable
class _TimestampMap {
  const _TimestampMap(this.mpegTs, this.local);

  final int mpegTs;
  final Duration local;

  static _TimestampMap? parse(String value) {
    int? mpegTs;
    Duration? local;
    for (final part in value.split(',')) {
      final colon = part.indexOf(':');
      if (colon == -1) continue;
      final key = part.substring(0, colon).trim().toUpperCase();
      final field = part.substring(colon + 1).trim();
      if (key == 'MPEGTS') {
        mpegTs = int.tryParse(field);
      } else if (key == 'LOCAL') {
        local = _readTimestamp(field);
      }
    }
    if (mpegTs == null) return null;
    return _TimestampMap(mpegTs, local ?? Duration.zero);
  }

  /// How far this segment's cue times lie from where they would sit on
  /// [reference]'s clock.
  Duration offsetFrom(_TimestampMap reference) {
    // MPEG-2 timestamps are 33 bits and wrap; the shorter way round is the
    // real distance.
    const wrap = 1 << 33;
    var ticks = mpegTs - reference.mpegTs;
    if (ticks > wrap ~/ 2) {
      ticks -= wrap;
    } else if (ticks < -wrap ~/ 2) {
      ticks += wrap;
    }
    return Duration(microseconds: ticks * 100 ~/ 9) - (local - reference.local);
  }
}

({List<SubtitleCue> cues, _TimestampMap? map}) _parseVtt(String body) {
  final lines = _lines(body);
  _TimestampMap? map;
  var i = 1;
  // The header runs to the first blank line; a timing line also ends it, for
  // files that leave the blank line out.
  for (; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty || _readTiming(line) != null) break;
    if (line.startsWith('X-TIMESTAMP-MAP=')) {
      map = _TimestampMap.parse(line.substring('X-TIMESTAMP-MAP='.length));
    }
  }
  return (cues: _readCueBlocks(lines, i), map: map);
}

typedef _Timing = ({Duration start, Duration end, String settings});

/// The cues of SubRip or WebVTT [lines] from [from] on.
///
/// A cue is a timing line and the text under it, up to a blank line - or up
/// to the next cue's counter and timing when a file leaves the blank line
/// out, which SubRip files often do. Everything else, WebVTT's notes, styles
/// and cue identifiers and SubRip's counters included, is skipped.
List<SubtitleCue> _readCueBlocks(List<String> lines, int from) {
  final cues = <SubtitleCue>[];
  var i = from;
  while (i < lines.length) {
    final timing = _readTiming(lines[i].trim());
    i++;
    if (timing == null) continue;
    final text = <String>[];
    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.isEmpty || _readTiming(line) != null) break;
      if (_counter.hasMatch(line) &&
          i + 1 < lines.length &&
          _readTiming(lines[i + 1].trim()) != null) {
        break;
      }
      text.add(line);
      i++;
    }
    if (timing.end <= timing.start || text.isEmpty) continue;
    final markup = _Markup.subRip()..read(text.join('\n'));
    final spans = markup.spans();
    if (spans.isEmpty) continue;
    cues.add(
      SubtitleCue(
        start: timing.start,
        end: timing.end,
        spans: spans,
        placement: markup.placement ?? _vttPlacement(timing.settings),
      ),
    );
  }
  return cues;
}

final RegExp _counter = RegExp(r'^\d+$');
final RegExp _timingLine = RegExp(r'^(\S+?)\s*-->\s*(\S+)(.*)$');
final RegExp _timestamp = RegExp(
  r'^(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3})\d*)?$',
);

_Timing? _readTiming(String line) {
  if (!line.contains('-->')) return null;
  final match = _timingLine.firstMatch(line);
  if (match == null) return null;
  final start = _readTimestamp(match[1]!);
  final end = _readTimestamp(match[2]!);
  if (start == null || end == null) return null;
  return (start: start, end: end, settings: match[3]!.trim());
}

/// `[h:]mm:ss[.fff]`, the way SubRip, WebVTT and SubStation Alpha each write
/// it: a comma or a point before the fraction, which may have one to three
/// digits.
Duration? _readTimestamp(String text) {
  final match = _timestamp.firstMatch(text.trim());
  if (match == null) return null;
  final hours = int.tryParse(match[1] ?? '0');
  final minutes = int.tryParse(match[2]!);
  final seconds = int.tryParse(match[3]!);
  final millis = int.tryParse((match[4] ?? '').padRight(3, '0'));
  if (hours == null || minutes == null || seconds == null || millis == null) {
    return null;
  }
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: millis,
  );
}

/// Where a WebVTT cue's `line` setting puts it. A line number counts from
/// the top when it is not negative; a percentage is a height down the screen.
SubtitlePlacement _vttPlacement(String settings) {
  for (final setting in settings.split(RegExp(r'\s+'))) {
    if (!setting.startsWith('line:')) continue;
    final value = setting.substring('line:'.length).split(',').first;
    if (value.endsWith('%')) {
      final percent = double.tryParse(value.substring(0, value.length - 1));
      if (percent == null) continue;
      if (percent < 40) return SubtitlePlacement.top;
      if (percent <= 60) return SubtitlePlacement.middle;
      return SubtitlePlacement.bottom;
    }
    final line = double.tryParse(value);
    if (line != null && line >= 0) return SubtitlePlacement.top;
  }
  return SubtitlePlacement.bottom;
}

final RegExp _assSection = RegExp(
  r'^\s*\[(script info|events|v4\+? styles)\]\s*$',
  multiLine: true,
  caseSensitive: false,
);

/// The Events format SubStation Alpha files use when they do not state one.
const List<String> _defaultEventFormat = [
  'layer',
  'start',
  'end',
  'style',
  'name',
  'marginl',
  'marginr',
  'marginv',
  'effect',
  'text',
];

List<SubtitleCue> _parseAss(String body) {
  final styles = <String, _AssStyle>{};
  final cues = <SubtitleCue>[];
  var section = '';
  List<String>? styleFormat;
  var eventFormat = _defaultEventFormat;
  for (final raw in _lines(body)) {
    final line = raw.trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.toLowerCase();
      continue;
    }
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final key = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1);
    if (section == '[v4+ styles]' || section == '[v4 styles]') {
      if (key == 'format') {
        styleFormat = _assFields(value);
      } else if (key == 'style' && styleFormat != null) {
        final style = _AssStyle.parse(
          styleFormat,
          value,
          legacy: section == '[v4 styles]',
        );
        if (style != null) styles[style.name] = style;
      }
    } else if (section == '[events]') {
      if (key == 'format') {
        eventFormat = _assFields(value);
      } else if (key == 'dialogue') {
        final cue = _assDialogue(eventFormat, value, styles);
        if (cue != null) cues.add(cue);
      }
    }
  }
  return cues;
}

List<String> _assFields(String value) =>
    value.split(',').map((field) => field.trim().toLowerCase()).toList();

SubtitleCue? _assDialogue(
  List<String> format,
  String value,
  Map<String, _AssStyle> styles,
) {
  if (format.isEmpty) return null;
  // Text is the last field and the only one that may hold commas.
  final fields = <String>[];
  var rest = value;
  for (var i = 0; i < format.length - 1; i++) {
    final comma = rest.indexOf(',');
    if (comma == -1) return null;
    fields.add(rest.substring(0, comma).trim());
    rest = rest.substring(comma + 1);
  }
  fields.add(rest);
  String field(String name) {
    final index = format.indexOf(name);
    return index == -1 ? '' : fields[index];
  }

  final start = _readTimestamp(field('start'));
  final end = _readTimestamp(field('end'));
  if (start == null || end == null || end <= start) return null;
  final style =
      styles[_assStyleName(field('style'))] ??
      styles['Default'] ??
      _AssStyle.plain;
  final markup = _Markup.ass(style, styles)..read(field('text'));
  final spans = markup.spans();
  if (spans.isEmpty) return null;
  return SubtitleCue(
    start: start,
    end: end,
    spans: spans,
    placement: markup.placement ?? style.placement,
  );
}

/// SubStation Alpha writes some style names with a leading `*`.
String _assStyleName(String name) =>
    name.startsWith('*') ? name.substring(1) : name;

/// What a SubStation Alpha style says about the text drawn here.
@immutable
class _AssStyle {
  const _AssStyle({
    required this.name,
    this.italic = false,
    this.bold = false,
    this.placement = SubtitlePlacement.bottom,
  });

  static const _AssStyle plain = _AssStyle(name: '');

  final String name;
  final bool italic;
  final bool bold;
  final SubtitlePlacement placement;

  static _AssStyle? parse(
    List<String> format,
    String value, {
    required bool legacy,
  }) {
    final fields = value.split(',').map((field) => field.trim()).toList();
    String? field(String name) {
      final index = format.indexOf(name);
      return index == -1 || index >= fields.length ? null : fields[index];
    }

    final name = field('name');
    if (name == null) return null;
    final alignment = int.tryParse(field('alignment') ?? '');
    return _AssStyle(
      name: _assStyleName(name),
      italic: _assBold(field('italic')),
      bold: _assBold(field('bold')),
      placement: alignment == null
          ? SubtitlePlacement.bottom
          : legacy
          ? _legacyPlacement(alignment)
          : _numpadPlacement(alignment),
    );
  }
}

/// A SubStation Alpha on/off value: -1 or 1 for on, 0 for off - or, for
/// bold, a font weight, which is bold from 600.
bool _assBold(String? value) {
  final number = int.tryParse(value ?? '');
  if (number == null) return false;
  return number == -1 || number == 1 || number >= 600;
}

/// `\an` and Advanced SubStation Alpha styles lay alignments out like a
/// numeric keypad: 1-3 along the bottom, 4-6 the middle, 7-9 the top.
SubtitlePlacement _numpadPlacement(int alignment) => alignment >= 7
    ? SubtitlePlacement.top
    : alignment >= 4
    ? SubtitlePlacement.middle
    : SubtitlePlacement.bottom;

/// `\a` and SubStation Alpha v4 styles: 1-3 along the bottom, plus 4 for the
/// top and plus 8 for the middle.
SubtitlePlacement _legacyPlacement(int alignment) => alignment >= 9
    ? SubtitlePlacement.middle
    : alignment >= 5
    ? SubtitlePlacement.top
    : SubtitlePlacement.bottom;

final RegExp _anTag = RegExp(r'^an([1-9])$');
final RegExp _aTag = RegExp(r'^a(\d{1,2})$');
final RegExp _italicTag = RegExp(r'^i([01]?)$');
final RegExp _boldTag = RegExp(r'^b(\d*)$');
final RegExp _drawingTag = RegExp(r'^p(\d+)$');
final RegExp _htmlTag = RegExp(r'^(/?)([a-zA-Z][a-zA-Z0-9]*)(?:[.\s][^<>]*)?$');
final RegExp _entity = RegExp(
  r'&(#[xX][0-9a-fA-F]{1,6}|#\d{1,7}|[a-zA-Z]{2,8});',
);
final RegExp _spaceAroundBreak = RegExp(r'[ \t]*\n[ \t]*');

const Map<String, String> _namedEntities = {
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  'lrm': '‎',
  'rlm': '‏',
};

/// Reads one cue's marked-up text into styled spans, noting where the markup
/// places the cue.
///
/// SubRip and WebVTT mark text up with HTML-like tags and entities, and some
/// SubRip files borrow SubStation Alpha's `{\...}` overrides. SubStation Alpha
/// has only its brace blocks - overrides and comments - and `\N`, `\n` and
/// `\h` escapes. Italics and bold are kept; every other tag is dropped, and
/// so is the text of drawings and of ruby annotations.
class _Markup {
  _Markup.subRip() : _ass = false, _style = _AssStyle.plain, _styles = const {};

  _Markup.ass(this._style, this._styles) : _ass = true {
    _italic = _style.italic;
    _bold = _style.bold;
  }

  final bool _ass;
  final _AssStyle _style;
  final Map<String, _AssStyle> _styles;

  final List<SubtitleSpan> _spans = [];
  final StringBuffer _run = StringBuffer();
  var _italic = false;
  var _bold = false;
  var _italicTags = 0;
  var _boldTags = 0;
  var _drawing = false;
  var _ruby = false;

  /// Where the markup places the cue - the first alignment override wins,
  /// as it does in libass - or null when it says nothing.
  SubtitlePlacement? placement;

  void read(String text) {
    var i = 0;
    while (i < text.length) {
      final char = text[i];
      if (char == '<' && !_ass) {
        final close = text.indexOf('>', i + 1);
        if (close != -1 && _tag(text.substring(i + 1, close))) {
          i = close + 1;
          continue;
        }
      } else if (char == '{') {
        final close = text.indexOf('}', i + 1);
        if (close != -1 && (_ass || text.startsWith(r'{\', i))) {
          _override(text.substring(i + 1, close));
          i = close + 1;
          continue;
        }
      } else if (char == r'\' && _ass && i + 1 < text.length) {
        final escaped = switch (text[i + 1]) {
          'N' => '\n',
          // A soft break only breaks under a wrap style this does not do.
          'n' => ' ',
          'h' => ' ',
          _ => null,
        };
        if (escaped != null) {
          _write(escaped);
          i += 2;
          continue;
        }
      } else if (char == '&' && !_ass) {
        final entity = _entity.matchAsPrefix(text, i);
        final decoded = entity == null ? null : _decodeEntity(entity[1]!);
        if (decoded != null) {
          _write(decoded);
          i = entity!.end;
          continue;
        }
      }
      _write(char);
      i++;
    }
  }

  /// The text read, trimmed at its ends and around its line breaks - empty
  /// when nothing visible is left.
  List<SubtitleSpan> spans() {
    _flush();
    final spans = [
      for (final span in _spans)
        SubtitleSpan(
          span.text.replaceAll(_spaceAroundBreak, '\n'),
          italic: span.italic,
          bold: span.bold,
        ),
    ];
    while (spans.isNotEmpty) {
      final first = spans.first;
      final trimmed = first.text.trimLeft();
      if (trimmed.isNotEmpty) {
        spans[0] = SubtitleSpan(
          trimmed,
          italic: first.italic,
          bold: first.bold,
        );
        break;
      }
      spans.removeAt(0);
    }
    while (spans.isNotEmpty) {
      final last = spans.last;
      final trimmed = last.text.trimRight();
      if (trimmed.isNotEmpty) {
        spans[spans.length - 1] = SubtitleSpan(
          trimmed,
          italic: last.italic,
          bold: last.bold,
        );
        break;
      }
      spans.removeLast();
    }
    return spans;
  }

  bool get _italicNow => _italic || _italicTags > 0;
  bool get _boldNow => _bold || _boldTags > 0;

  void _write(String text) {
    if (_drawing || _ruby) return;
    _run.write(text);
  }

  /// Closes the run written so far in the current style, before the style
  /// changes.
  void _flush() {
    if (_run.isEmpty) return;
    final text = _run.toString();
    _run.clear();
    if (_spans.isNotEmpty &&
        _spans.last.italic == _italicNow &&
        _spans.last.bold == _boldNow) {
      final last = _spans.removeLast();
      _spans.add(
        SubtitleSpan(last.text + text, italic: last.italic, bold: last.bold),
      );
    } else {
      _spans.add(SubtitleSpan(text, italic: _italicNow, bold: _boldNow));
    }
  }

  /// Applies the HTML-like tag [inner] - what sits between `<` and `>` -
  /// and says whether it was one; `<3` and the like are text.
  bool _tag(String inner) {
    // A WebVTT karaoke timestamp.
    if (_readTimestamp(inner) != null) return true;
    final match = _htmlTag.firstMatch(inner);
    if (match == null) return false;
    final opens = match[1]!.isEmpty;
    switch (match[2]!.toLowerCase()) {
      case 'i':
        _flush();
        _italicTags = opens ? _italicTags + 1 : max(0, _italicTags - 1);
      case 'b':
        _flush();
        _boldTags = opens ? _boldTags + 1 : max(0, _boldTags - 1);
      case 'rt':
        _ruby = opens;
      case 'br':
        _write('\n');
    }
    return true;
  }

  /// Applies a SubStation Alpha override block; one without a backslash is a
  /// comment.
  void _override(String block) {
    for (final raw in block.split(r'\').skip(1)) {
      final tag = raw.trim();
      RegExpMatch? match;
      if ((match = _anTag.firstMatch(tag)) != null) {
        placement ??= _numpadPlacement(int.parse(match![1]!));
      } else if ((match = _aTag.firstMatch(tag)) != null) {
        placement ??= _legacyPlacement(int.parse(match![1]!));
      } else if ((match = _italicTag.firstMatch(tag)) != null) {
        final value = match![1]!;
        _flush();
        _italic = value.isEmpty ? _style.italic : value == '1';
      } else if ((match = _boldTag.firstMatch(tag)) != null) {
        final value = match![1]!;
        _flush();
        _bold = value.isEmpty ? _style.bold : _assBold(value);
      } else if ((match = _drawingTag.firstMatch(tag)) != null) {
        _drawing = int.parse(match![1]!) > 0;
      } else if (tag.startsWith('r')) {
        final style = tag.length > 1
            ? _styles[_assStyleName(tag.substring(1))] ?? _style
            : _style;
        _flush();
        _italic = style.italic;
        _bold = style.bold;
      }
    }
  }
}

String? _decodeEntity(String name) {
  if (name.startsWith('#')) {
    final hex = name.length > 1 && (name[1] == 'x' || name[1] == 'X');
    final code = hex
        ? int.tryParse(name.substring(2), radix: 16)
        : int.tryParse(name.substring(1));
    if (code == null ||
        code <= 0 ||
        code > 0x10FFFF ||
        (code >= 0xD800 && code <= 0xDFFF)) {
      return null;
    }
    return String.fromCharCode(code);
  }
  return _namedEntities[name];
}

List<String> _lines(String text) => LineSplitter.split(text).toList();

String _withoutBom(String text) =>
    text.startsWith('﻿') ? text.substring(1) : text;

String _utf16(List<int> bytes, {required bool bigEndian}) {
  final units = <int>[];
  for (var i = 2; i + 1 < bytes.length; i += 2) {
    units.add(
      bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : bytes[i] | (bytes[i + 1] << 8),
    );
  }
  return String.fromCharCodes(units);
}
