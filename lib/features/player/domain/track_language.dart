/// Which language a track is in, from whatever the source said about it.
///
/// Sources describe a track's language every way there is: ISO 639-1 (`en`),
/// ISO 639-2 in both its forms (`ger`, `deu`), a region on either (`pt-BR`),
/// or only a name - libVLC names a subtitle track `Track 1 - [English]` and
/// leaves its language field empty on Android. Choosing a track in the
/// viewer's language needs all of them to mean the same thing.
library;

/// A language: its ISO 639-1 code, the other codes sources use for it - ISO
/// 639-2 in both forms, retired ones, OpenSubtitles' own - and its English name,
/// with the names it goes by in its own script where releases use them.
typedef _Language = ({
  String code,
  List<String> codes,
  String name,
  List<String> aliases,
});

/// The languages streams are realistically in, and every language the app
/// itself is translated into.
///
/// Not complete on purpose: an unknown code is shown as the source gave it,
/// which is honest, whereas a half-remembered mapping is not.
const List<_Language> _languages = [
  (code: 'af', codes: ['afr'], name: 'Afrikaans', aliases: []),
  (code: 'am', codes: ['amh'], name: 'Amharic', aliases: []),
  (code: 'ar', codes: ['ara'], name: 'Arabic', aliases: ['العربية']),
  (
    code: 'as',
    codes: ['asm'],
    name: 'Assamese',
    // Both ways য় is written: as য and a nukta, and as one character.
    aliases: ['অসমীয়া', 'অসমী\u09DFা'],
  ),
  (code: 'az', codes: ['aze'], name: 'Azerbaijani', aliases: []),
  (code: 'be', codes: ['bel'], name: 'Belarusian', aliases: ['беларуская']),
  (code: 'bg', codes: ['bul'], name: 'Bulgarian', aliases: ['български']),
  (code: 'bn', codes: ['ben'], name: 'Bengali', aliases: ['bangla', 'বাংলা']),
  (code: 'bs', codes: ['bos'], name: 'Bosnian', aliases: []),
  (code: 'ca', codes: ['cat'], name: 'Catalan', aliases: []),
  (code: 'cs', codes: ['cze', 'ces'], name: 'Czech', aliases: ['čeština']),
  (code: 'da', codes: ['dan'], name: 'Danish', aliases: ['dansk']),
  (code: 'de', codes: ['ger', 'deu'], name: 'German', aliases: ['deutsch']),
  (code: 'el', codes: ['gre', 'ell'], name: 'Greek', aliases: ['ελληνικά']),
  (code: 'en', codes: ['eng'], name: 'English', aliases: []),
  (
    code: 'es',
    // OpenSubtitles files Latin America's and Spain's apart.
    codes: ['spa', 'spl', 'spn'],
    name: 'Spanish',
    aliases: ['español', 'espanol', 'castellano'],
  ),
  (code: 'et', codes: ['est'], name: 'Estonian', aliases: []),
  (code: 'eu', codes: ['baq', 'eus'], name: 'Basque', aliases: []),
  (code: 'fa', codes: ['per', 'fas'], name: 'Persian', aliases: ['farsi']),
  (code: 'fi', codes: ['fin'], name: 'Finnish', aliases: ['suomi']),
  (
    code: 'fil',
    codes: ['fil', 'tgl', 'tl'],
    name: 'Filipino',
    aliases: ['tagalog'],
  ),
  (
    code: 'fr',
    codes: ['fre', 'fra'],
    name: 'French',
    aliases: ['français', 'francais'],
  ),
  (code: 'gl', codes: ['glg'], name: 'Galician', aliases: ['gallegan']),
  (code: 'gu', codes: ['guj'], name: 'Gujarati', aliases: ['ગુજરાતી']),
  (code: 'he', codes: ['heb', 'iw'], name: 'Hebrew', aliases: ['עברית']),
  (code: 'hi', codes: ['hin'], name: 'Hindi', aliases: ['हिन्दी', 'हिंदी']),
  (code: 'hr', codes: ['hrv'], name: 'Croatian', aliases: ['hrvatski']),
  (code: 'hu', codes: ['hun'], name: 'Hungarian', aliases: ['magyar']),
  (code: 'hy', codes: ['arm', 'hye'], name: 'Armenian', aliases: []),
  (code: 'id', codes: ['ind', 'in'], name: 'Indonesian', aliases: ['bahasa']),
  (code: 'is', codes: ['ice', 'isl'], name: 'Icelandic', aliases: []),
  (code: 'it', codes: ['ita'], name: 'Italian', aliases: ['italiano']),
  (code: 'ja', codes: ['jpn'], name: 'Japanese', aliases: ['日本語']),
  (code: 'ka', codes: ['geo', 'kat'], name: 'Georgian', aliases: []),
  (code: 'kk', codes: ['kaz'], name: 'Kazakh', aliases: []),
  (code: 'km', codes: ['khm'], name: 'Khmer', aliases: []),
  (code: 'kn', codes: ['kan'], name: 'Kannada', aliases: ['ಕನ್ನಡ']),
  (code: 'ko', codes: ['kor'], name: 'Korean', aliases: ['한국어']),
  (code: 'ku', codes: ['kur'], name: 'Kurdish', aliases: []),
  (code: 'lo', codes: ['lao'], name: 'Lao', aliases: []),
  (code: 'lt', codes: ['lit'], name: 'Lithuanian', aliases: []),
  (code: 'lv', codes: ['lav'], name: 'Latvian', aliases: ['latviešu']),
  (
    code: 'mk',
    codes: ['mac', 'mkd'],
    name: 'Macedonian',
    aliases: ['македонски'],
  ),
  (code: 'ml', codes: ['mal'], name: 'Malayalam', aliases: ['മലയാളം']),
  (code: 'mn', codes: ['mon'], name: 'Mongolian', aliases: []),
  (code: 'mr', codes: ['mar'], name: 'Marathi', aliases: ['मराठी']),
  (code: 'ms', codes: ['may', 'msa'], name: 'Malay', aliases: ['melayu']),
  (code: 'my', codes: ['bur', 'mya'], name: 'Burmese', aliases: []),
  (code: 'nb', codes: ['nob'], name: 'Norwegian Bokmål', aliases: []),
  (code: 'ne', codes: ['nep'], name: 'Nepali', aliases: []),
  (
    code: 'nl',
    codes: ['dut', 'nld'],
    name: 'Dutch',
    aliases: ['nederlands', 'flemish'],
  ),
  (code: 'no', codes: ['nor'], name: 'Norwegian', aliases: ['norsk']),
  (
    code: 'or',
    codes: ['ori', 'ory'],
    name: 'Odia',
    // Oriya is libVLC's name for it. Both ways ଡ଼ is written: as ଡ and a
    // nukta, and as one character.
    aliases: ['oriya', 'ଓଡ଼ିଆ', '\u0B13\u0B5C\u0B3F\u0B06'],
  ),
  (
    code: 'pa',
    codes: ['pan'],
    name: 'Punjabi',
    // Panjabi is libVLC's name for it.
    aliases: ['panjabi', 'ਪੰਜਾਬੀ'],
  ),
  (code: 'pl', codes: ['pol'], name: 'Polish', aliases: ['polski']),
  (code: 'ps', codes: ['pus'], name: 'Pashto', aliases: ['pushto']),
  (
    code: 'pt',
    codes: ['por', 'pob'],
    name: 'Portuguese',
    aliases: ['português', 'portugues'],
  ),
  (
    code: 'ro',
    codes: ['rum', 'ron'],
    name: 'Romanian',
    aliases: ['română', 'romana'],
  ),
  (code: 'ru', codes: ['rus'], name: 'Russian', aliases: ['русский']),
  (code: 'si', codes: ['sin'], name: 'Sinhala', aliases: ['sinhalese']),
  (code: 'sk', codes: ['slo', 'slk'], name: 'Slovak', aliases: []),
  (code: 'sl', codes: ['slv'], name: 'Slovenian', aliases: []),
  (code: 'sq', codes: ['alb', 'sqi'], name: 'Albanian', aliases: []),
  (code: 'sr', codes: ['srp', 'scc'], name: 'Serbian', aliases: ['srpski']),
  (code: 'sv', codes: ['swe'], name: 'Swedish', aliases: ['svenska']),
  (code: 'sw', codes: ['swa'], name: 'Swahili', aliases: []),
  (code: 'ta', codes: ['tam'], name: 'Tamil', aliases: ['தமிழ்']),
  (code: 'te', codes: ['tel'], name: 'Telugu', aliases: ['తెలుగు']),
  (code: 'th', codes: ['tha'], name: 'Thai', aliases: ['ไทย']),
  (code: 'tr', codes: ['tur'], name: 'Turkish', aliases: ['türkçe', 'turkce']),
  (code: 'uk', codes: ['ukr'], name: 'Ukrainian', aliases: ['українська']),
  (code: 'ur', codes: ['urd'], name: 'Urdu', aliases: ['اردو']),
  (code: 'uz', codes: ['uzb'], name: 'Uzbek', aliases: []),
  (code: 'vi', codes: ['vie'], name: 'Vietnamese', aliases: ['tiếng việt']),
  (
    code: 'zh',
    // And OpenSubtitles' own: Traditional, and Chinese beside another.
    codes: ['chi', 'zho', 'zht', 'zhe', 'ze'],
    name: 'Chinese',
    aliases: ['中文', 'mandarin', 'cantonese'],
  ),
];

final Map<String, _Language> _byCode = {
  for (final language in _languages) ...{
    language.code: language,
    for (final code in language.codes) code: language,
  },
};

final Map<String, _Language> _byName = {
  for (final language in _languages) ...{
    language.name.toLowerCase(): language,
    for (final alias in language.aliases) alias: language,
  },
};

final RegExp _codeTag = RegExp(r'^([a-zA-Z]{2,3})(?:[-_][a-zA-Z0-9]+)*$');
final RegExp _words = RegExp(r'[\p{L}\p{M}]+', unicode: true);

/// The English name of the language coded [code] - ISO 639-1 or 639-2, as
/// is, with no region - or null for a code not known here.
String? languageNameForCode(String code) =>
    _byCode[code.trim().toLowerCase()]?.name;

/// The ISO 639-1 code - or, for Filipino, the ISO 639-2 one - of the
/// language [tag] stands for, or null when it names none known here.
///
/// [tag] may be a code, with or without a region, or text naming the
/// language: `Track 1 - [English]`, `Brazilian Portuguese`, `Español`. `und`,
/// the code sources give an unknown language, is null.
String? languageCodeOf(String? tag) {
  final value = tag?.trim();
  if (value == null || value.isEmpty) return null;
  final code = _codeTag.firstMatch(value);
  if (code != null) return _byCode[code[1]!.toLowerCase()]?.code;
  final lowered = value.toLowerCase();
  final whole = _byName[lowered];
  if (whole != null) return whole.code;
  for (final word in _words.allMatches(lowered)) {
    final named = _byName[word[0]!];
    if (named != null) return named.code;
  }
  // A two-word alias, which the word scan cannot see.
  for (final entry in _byName.entries) {
    if (entry.key.contains(' ') && lowered.contains(entry.key)) {
      return entry.value.code;
    }
  }
  return null;
}

/// The codes to ask libVLC for the language [tag] names by, in its
/// `audio-language` option: ISO 639-2 in both forms, then ISO 639-1, as in
/// `hin,hi`, so that a source tagging its track either way is matched. Empty
/// for a tag that names no language known here.
///
/// libVLC reads each through its own ISO 639 table (`LanguageSplit` in
/// es_out.c) and drops one it does not know, so the codes only some sources
/// use - OpenSubtitles' `pob` - cost nothing. The retired ones are worth
/// sending: libVLC 3 files Hebrew twice, and a track tagged `iw` matches only
/// `iw`.
List<String> vlcLanguageCodes(String? tag) {
  final language = _byCode[languageCodeOf(tag)];
  if (language == null) return const <String>[];
  return <String>{...language.codes, language.code}.toList();
}

/// Whether [tag] is in the language [preferred] names - both read by
/// [languageCodeOf], so `eng`, `en-GB` and `English` all answer `en`.
bool isLanguage(String? tag, String? preferred) {
  final want = languageCodeOf(preferred);
  return want != null && languageCodeOf(tag) == want;
}

/// libVLC's name for a track whose source declared its language: the source's
/// own description and the language, `Hindi DD 5.1 - [Hindi]`, or a number and
/// the language, `Track 2 - [Hindi]`.
final RegExp _declared = RegExp(r'^(.*) - \[([^\]]+)\]$');

/// The language libVLC's brackets in a track's [name] declare, Hindi for
/// `Track 2 - [Hindi]`, or null when the name has none or they name no
/// language known here.
String? languageCodeOfBrackets(String? name) {
  final declared = _declared.firstMatch(name?.trim() ?? '');
  return declared == null ? null : languageCodeOf(declared[2]);
}

/// The word a name leads with, past any brackets or punctuation.
final RegExp _leadingWord = RegExp(
  r'^[^\p{L}\p{M}]*([\p{L}\p{M}]+)',
  unicode: true,
);

/// What has to follow a release group's three-letter shorthand for it to be
/// one: the end of the name, ` - `, a number - a channel layout, `5.1`,
/// `6ch` - or a codec or a track label's other words, `DD+`, `TrueHD`,
/// `Stereo`, `SDH`. A name that goes on in words is a sentence, not a label:
/// `Fra Diavolo`, `Tel quel`, `Mal de mer`.
final RegExp _shorthandTail = RegExp(
  r'^(?:[\s\])}>]*$|\s+-\s|[\s\[\](){}<>|:,._/+-]*(?:\d|(?:aac|he-?aac|'
  r'e?-?ac-?3|ddp?|dts|truehd|atmos|flac|alac|opus|vorbis|mp[23]|l?pcm|'
  r'stereo|mono|surround|dolby|sdh|cc|forced|full|signs)(?![\p{L}\p{M}])))',
  caseSensitive: false,
  unicode: true,
);

/// Three-letter codes that are everyday words in English or a Romance
/// language - or names - before they are anyone's shorthand: `Ben 2.0`,
/// `Mar 2.0`, `Por favor`, `Fin`, `Dan's Commentary`. Never read as one.
///
/// Kept out of it, though each is a word somewhere, because the shorthand is
/// common and [_shorthandTail] already turns away the sentences they begin:
/// `ara`, `fra`, `mal`, `spa` and `tel`.
const Set<String> _everydayWords = {
  'alb', 'arm', 'bel', 'ben', 'cat', 'ces', 'chi', 'dan', 'ell', 'est', //
  'fil', 'fin', 'ice', 'lit', 'mac', 'mar', 'may', 'mon', 'nor', 'ori',
  'pan', 'per', 'por', 'pus', 'ron', 'rum', 'sin', 'vie',
};

/// The language a track's name says it is in, or null when it names none.
///
/// The engine's track list carries no language on any platform, so on a
/// device the name is all a track has to say for itself - and it is said
/// three ways:
///
///  * By libVLC, whenever the source declared a language: `Track 2 - [Hindi]`,
///    or `Hindi (dub) - [English]` when the source gave a description too. The
///    brackets are the declaration and the description is whatever its maker
///    typed, so the brackets win - and the description is read only when they
///    name no language known here.
///  * By the source alone: `Hindi DD 5.1`, or a name in the language's own
///    script, `ಕನ್ನಡ`. Read as [languageCodeOf] reads any text.
///  * By a release group's shorthand: `Tam 5.1`, `Hin - AAC`. Only a leading
///    three-letter code counts. Two letters - the `Hi` of `Hi-Res Audio` - and
///    a code anywhere else in the name are words far more often than they are
///    languages. Even a leading one counts only where a label would go on -
///    see [_shorthandTail] - and never where it is an everyday word,
///    [_everydayWords]: `Ben 2.0` is not Bengali, nor `Fin` Finnish.
String? languageCodeOfTrackName(String? name) {
  final value = name?.trim();
  if (value == null || value.isEmpty) return null;
  final declared = _declared.firstMatch(value);
  if (declared != null) {
    return languageCodeOf(declared[2]) ?? languageCodeOfTrackName(declared[1]);
  }
  // A name that is nothing but one of them is the word, not the code.
  final bare = _codeTag.firstMatch(value)?[1]?.toLowerCase();
  if (_everydayWords.contains(bare)) return null;
  final named = languageCodeOf(value);
  if (named != null) return named;
  final lead = _leadingWord.firstMatch(value);
  final word = lead?[1]?.toLowerCase();
  if (lead == null || word == null || word.length != 3) return null;
  if (_everydayWords.contains(word)) return null;
  if (!_shorthandTail.hasMatch(value.substring(lead.end))) return null;
  return _byCode[word]?.code;
}

/// The languages the player offers to choose from - the subtitle search's
/// chips and the audio language setting - each by the name it is shown under:
/// India's first, then the rest in code order. The forty the subtitle search
/// has always offered, and Azerbaijani, Persian, Filipino and Thai. The
/// subtitle providers ask each in their own terms (subtitle_providers.dart).
///
/// Not the languages the app itself is translated into, which is another
/// list: this one has Finnish, which the app is not in.
const Map<String, String> playerLanguages = {
  'English': 'en',
  'Hindi': 'hi',
  'Bengali': 'bn',
  'Telugu': 'te',
  'Marathi': 'mr',
  'Tamil': 'ta',
  'Gujarati': 'gu',
  'Kannada': 'kn',
  'Malayalam': 'ml',
  'Punjabi': 'pa',
  'Arabic': 'ar',
  'Assamese': 'as',
  'Azerbaijani': 'az',
  'Belarusian': 'be',
  'Bulgarian': 'bg',
  'Czech': 'cs',
  'German': 'de',
  'Greek': 'el',
  'Spanish': 'es',
  'Persian': 'fa',
  'Finnish': 'fi',
  'Filipino': 'fil',
  'French': 'fr',
  'Hebrew': 'he',
  'Croatian': 'hr',
  'Hungarian': 'hu',
  'Indonesian': 'id',
  'Italian': 'it',
  'Japanese': 'ja',
  'Korean': 'ko',
  'Latvian': 'lv',
  'Macedonian': 'mk',
  'Dutch': 'nl',
  'Polish': 'pl',
  'Portuguese': 'pt',
  'Romanian': 'ro',
  'Russian': 'ru',
  'Swedish': 'sv',
  'Thai': 'th',
  'Turkish': 'tr',
  'Ukrainian': 'uk',
  'Urdu': 'ur',
  'Vietnamese': 'vi',
  'Chinese': 'zh',
};
