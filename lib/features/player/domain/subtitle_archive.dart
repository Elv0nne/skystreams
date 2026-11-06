/// Which file of a downloaded subtitle archive to show.
///
/// Providers hand whole seasons over as one zip - SubDL does for most shows,
/// SubSource for many - and the app used to take the first subtitle file in
/// it. That was episode one at best. For Breaking Bad's first season on SubDL
/// it was a 296-byte note from the uploader ("00 ... YOU CAN DELETE THIS"),
/// which reads as no subtitles at all; for another upload of the same season
/// it was episode six, over episode one.
///
/// So the archive is read the way a viewer would pick from it: subtitle files
/// only, the episode asked for when there is one, the language asked for, and
/// never a file too small to be a subtitle while a real one is there.
library;

/// A file in an archive: its path inside it and its size in bytes.
typedef ArchiveEntry = ({String name, int size});

/// The extensions worth taking out of an archive: the formats SkyStream reads,
/// SubStation Alpha's older one included.
const Set<String> _kSubtitleExtensions = {'srt', 'vtt', 'ass', 'ssa'};

/// Smaller than this is a note, not a subtitle: a real subtitle file runs to
/// kilobytes even for a short episode.
const int _kNoteBytes = 1024;

/// The entry of [entries] to show, or null when none will do.
///
/// With an [episode], a file naming it is taken over the rest, and a pack
/// whose files name other episodes but not this one gives nothing rather than
/// the wrong episode. With a [language] - a code or a name - a file carrying
/// it is preferred where the pack has several. Of what is left, the largest
/// wins: a full track over a forced one.
String? pickSubtitleEntry(
  List<ArchiveEntry> entries, {
  int? season,
  int? episode,
  String? language,
}) {
  final subtitles = entries
      .where((entry) => _kSubtitleExtensions.contains(_extension(entry.name)))
      .toList();
  if (subtitles.isEmpty) return null;

  var pool = subtitles.where((entry) => entry.size >= _kNoteBytes).toList();
  if (pool.isEmpty) pool = subtitles;

  if (episode != null && episode > 0) {
    final tagged = [
      for (final entry in pool)
        if (episodeTagOf(_baseName(entry.name)) case final tag?)
          (entry: entry, tag: tag),
    ];
    final matching = [
      for (final item in tagged)
        if (item.tag.episode == episode &&
            (season == null ||
                season <= 0 ||
                item.tag.season == null ||
                item.tag.season == season))
          item.entry,
    ];
    if (matching.isNotEmpty) {
      pool = matching;
    } else if (tagged.isNotEmpty) {
      // A pack of other episodes: none of them is the one being watched.
      return null;
    }
  }

  final wanted = _languageWords(language);
  if (wanted.isNotEmpty) {
    final inLanguage = pool
        .where((entry) => _mentionsLanguage(entry.name, wanted))
        .toList();
    if (inLanguage.isNotEmpty) pool = inLanguage;
  }

  pool.sort((a, b) => b.size.compareTo(a.size));
  return pool.first.name;
}

/// The season and episode a file or release name carries - `S01E07`,
/// `s1 ep07`, `1x07`, `Episode 7`, `E07`, or a leading `07 ` as season packs
/// number their files - or null when it names no episode. The season is null
/// when only the episode is named.
({int? season, int episode})? episodeTagOf(String name) {
  final text = name.toLowerCase();
  final seasonEpisode = _seasonEpisodeTag.firstMatch(text);
  if (seasonEpisode != null) {
    return (
      season: int.parse(seasonEpisode[1]!),
      episode: int.parse(seasonEpisode[2]!),
    );
  }
  final spelled = _spelledTag.firstMatch(text);
  if (spelled != null) {
    return (season: int.parse(spelled[1]!), episode: int.parse(spelled[2]!));
  }
  final crossed = _crossedTag.firstMatch(text);
  if (crossed != null) {
    return (season: int.parse(crossed[1]!), episode: int.parse(crossed[2]!));
  }
  final episodeOnly = _episodeTag.firstMatch(text);
  if (episodeOnly != null) {
    return (season: null, episode: int.parse(episodeOnly[1]!));
  }
  final leading = _leadingNumber.firstMatch(text);
  if (leading != null) {
    return (season: null, episode: int.parse(leading[1]!));
  }
  return null;
}

final RegExp _seasonEpisodeTag = RegExp(
  r's(\d{1,2})[ ._-]*e(?:p(?:isode)?)?[ ._-]*(\d{1,3})(?!\d)',
);
final RegExp _spelledTag = RegExp(
  r'season[ ._-]*(\d{1,2})[ ._,-]*episode[ ._-]*(\d{1,3})(?!\d)',
);
final RegExp _crossedTag = RegExp(r'(?<!\d)(\d{1,2})x(\d{1,3})(?!\d)');
final RegExp _episodeTag = RegExp(
  r'(?:^|[^a-z0-9])e(?:p(?:isode)?)?[ ._-]*(\d{1,3})(?!\d)',
);
final RegExp _leadingNumber = RegExp(r'^(\d{1,3})(?=[ ._-])');

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot == -1 ? '' : name.substring(dot + 1).toLowerCase();
}

String _baseName(String name) {
  final slash = name.lastIndexOf(RegExp(r'[/\\]'));
  return slash == -1 ? name : name.substring(slash + 1);
}

/// The words a file name uses for [language]: `en`, `eng` and `english` for
/// any of the three. Empty when [language] says nothing.
Set<String> _languageWords(String? language) {
  final value = language?.trim().toLowerCase();
  if (value == null || value.isEmpty) return const {};
  for (final words in _kLanguageWords) {
    if (words.contains(value)) return words;
  }
  return {value};
}

/// The same language as file names spell it. Only the common ones: a pack
/// rarely has more than a handful, and an unknown one is matched as given.
const List<Set<String>> _kLanguageWords = [
  {'en', 'eng', 'english'},
  {'es', 'spa', 'spanish', 'español', 'espanol'},
  {'fr', 'fre', 'fra', 'french'},
  {'de', 'ger', 'deu', 'german'},
  {'it', 'ita', 'italian'},
  {'pt', 'por', 'portuguese', 'pob', 'ptbr', 'pt-br'},
  {'ar', 'ara', 'arabic'},
  {'hi', 'hin', 'hindi'},
  {'ru', 'rus', 'russian'},
  {'tr', 'tur', 'turkish'},
  {'id', 'ind', 'indonesian'},
  {'ko', 'kor', 'korean'},
  {'ja', 'jpn', 'japanese'},
  {'zh', 'chi', 'zho', 'chinese'},
];

final RegExp _nameWord = RegExp(r'[a-zÀ-ɏ-]+');

bool _mentionsLanguage(String name, Set<String> words) {
  final text = _baseName(name).toLowerCase();
  for (final match in _nameWord.allMatches(text)) {
    final word = match[0]!;
    if (words.contains(word)) return true;
    // The hyphen that keeps pt-br whole also joins a language to the word
    // beside it - English-SDH, en-US, Movie-English - so the parts count too.
    for (final part in word.split('-')) {
      if (part.isNotEmpty && words.contains(part)) return true;
    }
  }
  return false;
}
