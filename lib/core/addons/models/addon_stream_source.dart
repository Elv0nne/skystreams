/// Stream + subtitle objects returned by an add-on's `/stream` resource.
library;

import '../../utils/file_size_formatter.dart';
import '../../../features/player/domain/track_language.dart';

class AddonSubtitleTrack {
  final String id;
  final String url;
  final String lang;
  final String addonName;

  /// The release the subtitle was made for, when the add-on names it: the
  /// OpenSubtitles add-on does, beside the plain Stremio fields.
  final String? release;

  const AddonSubtitleTrack({
    required this.id,
    required this.url,
    required this.lang,
    this.addonName = '',
    this.release,
  });

  static AddonSubtitleTrack? fromJson(
    Map<String, dynamic> json, {
    required String addonName,
    required int index,
  }) {
    final url = (json['url'] as String?)?.trim() ?? '';
    if (!url.startsWith('http')) return null;
    final lang = ((json['lang'] as String?) ?? 'en').trim();
    return AddonSubtitleTrack(
      id: (json['id'] as String?) ?? '$addonName-$lang-$index',
      url: url,
      lang: lang.isEmpty ? 'en' : lang,
      addonName: addonName,
      release: _release(json),
    );
  }

  /// The release [json] names, else its file without the extension.
  static String? _release(Map<String, dynamic> json) {
    final release = json['movieReleaseName'];
    if (release is String && release.trim().isNotEmpty) return release.trim();
    final file = json['subtitleFileName'];
    if (file is! String || file.trim().isEmpty) return null;
    final name = file.trim();
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  String get label => prettyLanguage(lang);

  /// The language [code] names, as the player names languages - with the
  /// variants the OpenSubtitles add-on files apart - or [code] as the add-on
  /// gave it.
  static String prettyLanguage(String code) {
    final key = code.trim().toLowerCase();
    if (key.isEmpty) return 'Unknown';
    final variant = _variants[key];
    if (variant != null) return variant;
    final iso = languageCodeOf(key);
    final name = iso == null ? null : languageNameForCode(iso);
    if (name != null) return name;
    return key[0].toUpperCase() + key.substring(1);
  }

  /// A language's variants, by the OpenSubtitles add-on's own codes and by
  /// the tags other add-ons use.
  static const Map<String, String> _variants = {
    'pob': 'Portuguese (Brazil)',
    'pt-br': 'Portuguese (Brazil)',
    'spl': 'Spanish (Latin America)',
    'spn': 'Spanish (Spain)',
    'zht': 'Chinese (Traditional)',
    'zh-tw': 'Chinese (Traditional)',
    'zhe': 'Chinese (Bilingual)',
  };
}

enum AddonStreamKind { direct, torrent, youtube, external, unknown }

/// One playable result from an add-on.
class AddonStreamSource {
  final String addonId;
  final String addonName;

  final String? url;
  final String? infoHash;
  final int? fileIdx;
  final String? ytId;
  final String? externalUrl;

  final String? name;
  final String? title;
  final String? description;

  /// Torrent trackers advertised by the add-on (`tracker:udp://…`).
  final List<String> sources;

  final Map<String, String>? proxyHeaders;
  final String? bingeGroup;
  final int? videoSize;
  final String? filename;
  final List<AddonSubtitleTrack> subtitles;

  const AddonStreamSource({
    required this.addonId,
    required this.addonName,
    this.url,
    this.infoHash,
    this.fileIdx,
    this.ytId,
    this.externalUrl,
    this.name,
    this.title,
    this.description,
    this.sources = const [],
    this.proxyHeaders,
    this.bingeGroup,
    this.videoSize,
    this.filename,
    this.subtitles = const [],
  });

  factory AddonStreamSource.fromJson(
    Map<String, dynamic> json, {
    required String addonId,
    required String addonName,
  }) {
    final rawHints = json['behaviorHints'];
    final hints = rawHints is Map
        ? Map<String, dynamic>.from(rawHints)
        : <String, dynamic>{};

    Map<String, String>? headers;
    final proxy = hints['proxyHeaders'];
    if (proxy is Map) {
      final request = proxy['request'];
      if (request is Map) {
        final map = <String, String>{};
        request.forEach((key, value) {
          if (key is String && value != null) map[key] = value.toString();
        });
        if (map.isNotEmpty) headers = map;
      }
    }

    final subtitles = <AddonSubtitleTrack>[];
    final rawSubs = json['subtitles'];
    if (rawSubs is List) {
      for (var i = 0; i < rawSubs.length; i++) {
        final entry = rawSubs[i];
        if (entry is Map) {
          final sub = AddonSubtitleTrack.fromJson(
            Map<String, dynamic>.from(entry),
            addonName: addonName,
            index: i,
          );
          if (sub != null) subtitles.add(sub);
        }
      }
    }

    final sources = <String>[];
    final rawSources = json['sources'];
    if (rawSources is List) {
      for (final entry in rawSources) {
        if (entry is String && entry.isNotEmpty) sources.add(entry);
      }
    }

    return AddonStreamSource(
      addonId: addonId,
      addonName: addonName,
      // Direct links occasionally hide inside behaviorHints (see ARVIO).
      url: _firstHttpUrl([json['url'], hints['directUrl'], hints['url']]),
      infoHash: (json['infoHash'] as String?)?.toLowerCase(),
      fileIdx: (json['fileIdx'] as num?)?.toInt(),
      ytId: json['ytId'] as String?,
      externalUrl: _firstHttpUrl([json['externalUrl'], hints['externalUrl']]),
      name: json['name'] as String?,
      title: json['title'] as String?,
      description: json['description'] as String?,
      sources: sources,
      proxyHeaders: headers,
      bingeGroup: hints['bingeGroup'] as String?,
      videoSize: (hints['videoSize'] as num?)?.toInt(),
      filename: hints['filename'] as String?,
      subtitles: subtitles,
    );
  }

  static String? _firstHttpUrl(List<dynamic> candidates) {
    for (final candidate in candidates) {
      final value = candidate is String ? candidate.trim() : '';
      if (value.isEmpty) continue;
      if (value.startsWith('//')) return 'https:$value';
      if (value.startsWith('http://') || value.startsWith('https://')) {
        return value;
      }
    }
    return null;
  }

  AddonStreamKind get kind {
    if ((infoHash ?? '').isNotEmpty) return AddonStreamKind.torrent;
    if ((url ?? '').isNotEmpty) return AddonStreamKind.direct;
    if ((ytId ?? '').isNotEmpty) return AddonStreamKind.youtube;
    if ((externalUrl ?? '').isNotEmpty) return AddonStreamKind.external;
    return AddonStreamKind.unknown;
  }

  bool get isTorrent => kind == AddonStreamKind.torrent;
  bool get isDirect => kind == AddonStreamKind.direct;
  bool get isPlayable => isTorrent || isDirect;

  /// Deep links into a streaming service or YouTube (WatchHub, JustWatch-style
  /// add-ons). They can't be played in-app, but they must still *do* something
  /// when tapped — opening the service is the whole point of those add-ons.
  bool get isExternal =>
      kind == AddonStreamKind.external || kind == AddonStreamKind.youtube;

  String? get launchUrl => switch (kind) {
    AddonStreamKind.external => externalUrl,
    AddonStreamKind.youtube => 'https://www.youtube.com/watch?v=$ytId',
    _ => null,
  };

  String get _text =>
      [name ?? '', title ?? '', description ?? '', filename ?? ''].join(' ');

  static final RegExp _res = RegExp(
    r'(\d{3,4})\s*[pi]\b',
    caseSensitive: false,
  );
  // Bare height tokens used by multi-provider scrapers ("1080", "720 HD")
  // without a trailing p/i — only match common ladder values so a seeder
  // count like "1360 seeds" is never mistaken for a resolution.
  static final RegExp _bareRes = RegExp(
    r'(?<![.\d])(2160|1440|1080|720|576|540|480|360|240)(?!\d)',
  );
  static final RegExp _uhd = RegExp(
    r'\b(4k|uhd|2160p?)\b',
    caseSensitive: false,
  );
  static final RegExp _qhd = RegExp(r'\b(2k|1440p?)\b', caseSensitive: false);
  static final RegExp _hdr = RegExp(
    r'\b(hdr10\+?|hdr|dolby\s*vision|dovi|dv)\b',
    caseSensitive: false,
  );
  static final RegExp _cam = RegExp(
    r'\b(cam|camrip|hdcam|telesync|hdts|\bts\b|screener|scr)\b',
    caseSensitive: false,
  );
  static final RegExp _seeders = RegExp(r'(?:👤|seeders?[:\s]*)\s*(\d+)');
  static final RegExp _size = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*(gb|mb|gib|mib)\b',
    caseSensitive: false,
  );
  // Quality / release token that ends a provider chip:
  // "MovieBox 1080p", "VegaMovies · 4K", "MoviesDrive 1080", "[RD+] 720p".
  static final RegExp _trailingQuality = RegExp(
    r'(?:'
    r'[\s|\n·•\-–—/]+'
    r'(?:\[(?:rd|pm|ad|dl|oc|tb|ed)\+?\]\s*)?'
    r'(?:'
    r'\d{3,4}\s*[pi]\b'
    r'|(?:2160|1440|1080|720|576|540|480|360|240)(?!\d)'
    r'|4k\b|uhd\b|2k\b|cam(?:rip)?\b|hdr(?:10\+?)?\b|auto\b'
    r')'
    r'.*$'
    r')',
    caseSensitive: false,
  );

  int get qualityScore {
    if (_uhd.hasMatch(_text)) return 2160;
    if (_qhd.hasMatch(_text)) return 1440;
    final match = _res.firstMatch(_text);
    if (match != null) return int.tryParse(match.group(1)!) ?? 0;
    final bare = _bareRes.firstMatch(_text);
    return bare == null ? 0 : (int.tryParse(bare.group(1)!) ?? 0);
  }

  String get qualityLabel {
    final score = qualityScore;
    if (score >= 2160) return '4K';
    if (score >= 1440) return '2K';
    if (score > 0) return '${score}p';
    if (isCam) return 'CAM';
    return isTorrent ? 'Torrent' : 'Auto';
  }

  /// Provider / scraper name inside a multi-provider add-on (MovieBox,
  /// MoviesDrive, VegaMovies…), or null when the stream only names the
  /// add-on itself. CNCVerse-style bridges put the real source in `name`.
  String? get providerName {
    final raw = (name ?? '').trim();
    if (raw.isEmpty) return null;

    String? chip;
    // Bracket form: "[MovieBox] 1080p" / "[VegaMovies]".
    final bracket = RegExp(r'^\[([^\]]+)\]').firstMatch(raw);
    if (bracket != null) {
      chip = bracket.group(1)!.trim();
    } else {
      // Split on an explicit separator (newline / bullet / pipe).
      final sep = RegExp(r'[\n|·•]').firstMatch(raw);
      final head = (sep == null ? raw : raw.substring(0, sep.start)).trim();
      final peeled = head.replaceFirst(_trailingQuality, '').trim();
      if (peeled.isNotEmpty && peeled.toLowerCase() != head.toLowerCase()) {
        // "MovieBox 1080p" → "MovieBox"
        chip = peeled;
      } else if (sep != null && head.isNotEmpty) {
        // "MovieBox · something" → "MovieBox"
        chip = head;
      } else if (RegExp(r'^\S{2,32}$').hasMatch(head) &&
          !_isQualityOnly(head)) {
        // Bare short token: name: "MovieBox"
        chip = head;
      }
    }
    if (chip == null || chip.isEmpty) return null;
    if (_isQualityOnly(chip)) return null;
    if (chip.toLowerCase() == addonName.trim().toLowerCase()) return null;
    if (chip.length > 40) return null;
    return chip;
  }

  static bool _isQualityOnly(String value) {
    final lower = value.trim().toLowerCase();
    return RegExp(
      r'^(?:\[?(?:rd|pm|ad|dl|oc|tb|ed)\+?\]?\s*)?'
      r'(?:'
      r'\d{3,4}\s*[pi]'
      r'|2160|1440|1080|720|576|540|480|360|240'
      r'|4k|uhd|2k|cam(?:rip)?|hdr(?:10\+?)?|auto'
      r')$',
    ).hasMatch(lower);
  }

  bool get isHdr => _hdr.hasMatch(_text);
  bool get isCam => _cam.hasMatch(_text);
  bool get isCachedDebrid => RegExp(
    r'\[(rd|pm|ad|dl|oc|tb|ed)\+\]',
    caseSensitive: false,
  ).hasMatch(_text);

  int? get seeders {
    final match = _seeders.firstMatch(_text);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  int? get sizeBytes {
    if (videoSize != null && videoSize! > 0) return videoSize;
    final match = _size.firstMatch(_text);
    if (match == null) return null;
    final value = double.tryParse(match.group(1)!.replaceAll(',', '.'));
    if (value == null) return null;
    final unit = match.group(2)!.toLowerCase();
    final multiplier = unit.startsWith('g') ? 1024 * 1024 * 1024 : 1024 * 1024;
    return (value * multiplier).round();
  }

  String? get sizeLabel {
    final bytes = sizeBytes;
    if (bytes == null || bytes <= 0) return null;
    return formatFileSize(bytes, fractionDigits: 1);
  }

  List<String> get trackers => [
    for (final source in sources)
      if (source.startsWith('tracker:')) source.substring('tracker:'.length),
  ];

  String? get magnetUri {
    final hash = infoHash;
    if (hash == null || hash.isEmpty) return null;
    final buffer = StringBuffer('magnet:?xt=urn:btih:$hash');
    final display = filename ?? title ?? name;
    if (display != null && display.trim().isNotEmpty) {
      buffer.write('&dn=${Uri.encodeComponent(display.trim())}');
    }
    for (final tracker in trackers) {
      buffer.write('&tr=${Uri.encodeComponent(tracker)}');
    }
    // BEP 53's select-only: the file a season pack's row is for, which the
    // torrent service plays instead of the pack's first video.
    if (fileIdx case final index?) buffer.write('&so=$index');
    return buffer.toString();
  }

  /// Headline shown in the sources list.
  ///
  /// Nuvio layout: add-on name first, then the inner provider when the
  /// stream names one (so a CNCVerse → MovieBox row reads
  /// "CNCVerse Bridge · MovieBox", not a free-form dump of the name field).
  String get headline {
    final provider = providerName;
    if (provider == null || provider.isEmpty) return addonName;
    if (addonName.trim().isEmpty) return provider;
    return '$addonName · $provider';
  }

  /// Secondary line: stream's own label + descriptive text the add-on sent.
  String get subtitleLine {
    final parts = <String>[];
    final streamLabel = (name ?? '').trim().replaceAll(
      RegExp(r'[\n\r]+'),
      ' · ',
    );
    if (streamLabel.isNotEmpty && streamLabel != addonName) {
      parts.add(streamLabel);
    }
    final text = (title ?? description ?? '').trim();
    if (text.isNotEmpty) {
      final cleaned = text.replaceAll(RegExp(r'[\n\r]+'), ' · ');
      if (parts.isEmpty || cleaned.toLowerCase() != streamLabel.toLowerCase()) {
        parts.add(cleaned);
      }
    }
    if (parts.isEmpty) {
      final file = filename?.trim();
      if (file != null && file.isNotEmpty) return file;
      return qualityLabel;
    }
    return parts.join(' · ');
  }

  /// Whether [query] matches this stream for the sources-sheet filter.
  ///
  /// Empty / whitespace-only queries match everything. Otherwise the needle is
  /// looked for (case-insensitive) in the add-on name, inner provider chip
  /// (VegaMovies, MovieBox…), quality label, and the free-text fields the
  /// add-on published.
  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final haystack = [
      addonName,
      providerName ?? '',
      headline,
      subtitleLine,
      qualityLabel,
      name ?? '',
      title ?? '',
      description ?? '',
    ].join(' ').toLowerCase();
    return haystack.contains(q);
  }

  /// De-dup key, mirroring ARVIO's.
  String get dedupeKey => [
    addonId,
    url ?? '',
    infoHash ?? '',
    fileIdx?.toString() ?? '',
    name ?? '',
    description ?? title ?? '',
  ].join('|');

  /// Ranking score.
  ///
  /// Resolution leads, because SkyStream streams torrents natively through the
  /// bundled torrent server — unlike a browser client, a 4K torrent is not
  /// second-class here. Direct links still get a head start for instant
  /// playback, cached debrid links more so, and CAM rips are buried.
  int get score {
    var value = 0;
    if (isCachedDebrid) value += 70;
    if (isDirect) value += 45;

    final quality = qualityScore;
    if (quality >= 2160) {
      value += 140;
    } else if (quality >= 1440) {
      value += 110;
    } else if (quality >= 1080) {
      value += 85;
    } else if (quality >= 720) {
      value += 45;
    }

    // No boost for HDR: every SkyStream path shows it washed out (P1 spec 6).
    if (isCam) value -= 150;

    final seeds = seeders;
    if (seeds != null) value += (seeds.clamp(0, 60) / 2).round();

    final bytes = sizeBytes;
    if (bytes != null) {
      value += (bytes / (1024 * 1024 * 1024)).clamp(0, 20).round();
    }
    return value;
  }
}

/// Distinct provider / add-on labels for a sources-sheet chip rail.
///
/// Prefers the inner provider (VegaMovies) when a multi-provider bridge named
/// one; otherwise the add-on itself (Torrentio). Sorted case-insensitively.
List<String> addonStreamProviderLabels(Iterable<AddonStreamSource> streams) {
  final seen = <String>{};
  final out = <String>[];
  for (final s in streams) {
    final provider = s.providerName?.trim();
    final label = (provider != null && provider.isNotEmpty)
        ? provider
        : s.addonName.trim();
    if (label.isEmpty) continue;
    if (!seen.add(label.toLowerCase())) continue;
    out.add(label);
  }
  out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return out;
}

/// [streams] best first: by [AddonStreamSource.score], except that links which
/// look like a different film go after every other link.
///
/// Scraper bridges search their sites by title and sometimes take the wrong
/// page: asked for The Vvaan (2026), CNCVerse's FourKHDHub answered with 4K
/// links to The Twilight Saga: Breaking Dawn - Part 2, and the score alone
/// made one of them the top pick. Those links name the film they are for. An
/// add-on that names the film asked for in some of its links has, in the
/// others, named another, so those go last, still listed. An add-on that names
/// no film, and a [title] with no word distinctive enough to look for, leave
/// the score to decide. A link that carries the film's [year] counts as naming
/// it: that keeps a release under a translated title ("Duna - Parte Dois
/// 2024") where it was.
List<AddonStreamSource> rankAddonStreams(
  Iterable<AddonStreamSource> streams, {
  String? title,
  int? year,
}) {
  final ranked = streams.toList();
  final scores = Map<AddonStreamSource, int>.identity();
  for (final stream in ranked) {
    scores[stream] = stream.score;
  }

  final suspects = Set<AddonStreamSource>.identity();
  final words = _titleWords(title);
  if (words.isNotEmpty) {
    final naming = <String>{};
    final unnamed = <AddonStreamSource>[];
    for (final stream in ranked) {
      if (stream._names(words, year)) {
        naming.add(stream.addonId);
      } else {
        unnamed.add(stream);
      }
    }
    suspects.addAll(unnamed.where((s) => naming.contains(s.addonId)));
  }

  ranked.sort((a, b) {
    final bySuspicion = (suspects.contains(a) ? 1 : 0).compareTo(
      suspects.contains(b) ? 1 : 0,
    );
    if (bySuspicion != 0) return bySuspicion;
    final byScore = scores[b]!.compareTo(scores[a]!);
    if (byScore != 0) return byScore;
    return a.addonName.compareTo(b.addonName);
  });
  return ranked;
}

/// Words that name nothing in particular: they turn up in titles and in any
/// release's name alike.
const Set<String> _commonWords = {
  'the',
  'and',
  'for',
  'with',
  'from',
  'part',
  'movie',
  'film',
  'full',
  'hindi',
  'dubbed',
  'season',
  'episode',
  'series',
  'complete',
  'dual',
  'audio',
};

final RegExp _word = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// The distinctive words of [text], lower-case.
Set<String> _wordsOf(String text) => {
  for (final match in _word.allMatches(text.toLowerCase()))
    if (match[0]!.length >= 3 && !_commonWords.contains(match[0])) match[0]!,
};

/// The words a link must share to name the film called [title].
///
/// A scraper bridge's catalog names the release rather than the film ("The
/// Vvaan (2026) V2 HQ-HDTC Hindi (LiNE) 1080p | Full Movie"): the film is what
/// comes before its year or first bracket.
Set<String> _titleWords(String? title) {
  if (title == null) return const {};
  final name = title
      .replaceFirst(RegExp(r'^\s*(\[[^\]]*\]\s*)+'), '')
      .split(RegExp(r'[(\[{|]|\b(?:19|20)\d\d\b'))
      .first;
  return _wordsOf(name);
}

extension on AddonStreamSource {
  /// Whether this link names the film: one of [words] in its labels, file
  /// name or path, or the film's [year].
  bool _names(Set<String> words, int? year) {
    var path = '';
    final link = url;
    if (link != null) {
      try {
        path = Uri.decodeFull(Uri.parse(link).path);
      } on FormatException {
        // Not a URL to read a name from; the labels still say.
      } on ArgumentError {
        // A malformed escape in the path; the same.
      }
    }
    final text = '$_text $path';
    if (_wordsOf(text).any(words.contains)) return true;
    return year != null && RegExp('\\b$year\\b').hasMatch(text);
  }
}
