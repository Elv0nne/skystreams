import 'search_fold_table.dart';

/// [text] as search compares it, the same for a title and a query, so the
/// spellings people type and the ones sites write come out alike:
///
/// - lowercase, without accents, Arabic vowel and Quranic marks, Hebrew
///   points, tatweel and invisible characters (soft hyphens, zero-width
///   spaces, direction marks, variation selectors);
/// - the digits of every script as 0 to 9, full-width ASCII as ASCII, and
///   half-width katakana and voiced kana written one way;
/// - letters with no decomposition as the letters people type for them
///   (ß as ss, ı as i, ł as l, ё as е, й as и, ς as σ), and the Arabic and
///   Persian forms of a letter as one (أ إ آ ٱ as ا, ة as ه, ى and ی as ي,
///   ک as ك);
/// - one apostrophe, hyphen and middle dot for each of their kinds, for
///   joined title words ("Grey’s", "Spider‐Man", "WALL·E");
/// - Hindi and Punjabi words with or without a nukta, with a chandrabindu or
///   an anusvara, and with a nasal and virama or an anusvara, written one
///   way; and old Malayalam chillu letters as the atomic ones;
/// - Traditional Chinese characters as the Simplified ones (庆 for 慶), except
///   one that is Simplified as well (乾, 著).
///
/// The marks a word is made of (Indic vowel signs and viramas, Thai vowels,
/// kana voicing marks) stay in it. Text that is all ASCII is only lowercased.
String foldForSearch(String text) => _fold(text, nasalsAsAnusvara: true);

/// The other spellings of [text], folded as [foldForSearch] folds it, that a
/// word typed up to one of its Devanagari nasals begins: [foldForSearch]
/// writes a nasal and virama before a consonant as an anusvara, and a word
/// typed so far that ends at the nasal has no consonant after it, so "गेम"
/// does not begin "गेम्स" as folded ("गेंस"). One spelling for each such
/// nasal: it and those after it as written, those before it as anusvaras.
/// None when [text] has no such nasal.
List<String> nasalSpellingsForSearch(String text) {
  if (!text.contains('\u{94D}')) return const [];
  final asWritten = _fold(text, nasalsAsAnusvara: false);
  return [
    for (final nasal in _nasalVirama.allMatches(asWritten))
      asWritten.replaceAllMapped(
        _nasalVirama,
        (m) => m.start < nasal.start ? '\u{902}' : m[0]!,
      ),
  ];
}

/// [codePoint] as Simplified Chinese writes it, when it is a Traditional
/// character with a Simplified one (see [searchHanFolds]); otherwise itself.
int _simplified(int codePoint) {
  final ideograph =
      (codePoint >= 0x3400 && codePoint <= 0x9FFF) ||
      (codePoint >= 0xF900 && codePoint <= 0xFAFF) ||
      codePoint >= 0x20000;
  return ideograph ? (_hanFolds[codePoint] ?? codePoint) : codePoint;
}

/// [searchHanFolds] as code points, read the first time a title has a Chinese
/// character in it.
final Map<int, int> _hanFolds = () {
  final pairs = searchHanFolds.runes.toList();
  return {for (var i = 0; i + 1 < pairs.length; i += 2) pairs[i]: pairs[i + 1]};
}();

/// [text] folded for search, with each Devanagari nasal and virama before a
/// consonant as an anusvara when [nasalsAsAnusvara], or as written.
String _fold(String text, {required bool nasalsAsAnusvara}) {
  final lower = text.toLowerCase();
  if (_isAscii(lower)) return lower;
  final out = StringBuffer();
  var zeroWidthJoiner = false;
  var devanagariOrGurmukhi = false;
  for (final codePoint in lower.runes) {
    if (codePoint < 0x80) {
      out.writeCharCode(codePoint);
      continue;
    }
    if (_dropped(codePoint)) continue;
    final digit = _digit(codePoint);
    if (digit >= 0) {
      out.writeCharCode(0x30 + digit);
    } else if (codePoint >= 0xFF01 && codePoint <= 0xFF5E) {
      final ascii = codePoint - 0xFEE0;
      out.writeCharCode(ascii >= 0x41 && ascii <= 0x5A ? ascii + 0x20 : ascii);
    } else {
      final folded = searchFoldTable[codePoint];
      if (folded != null) {
        out.write(folded);
      } else {
        out.writeCharCode(_simplified(codePoint));
      }
      if (codePoint == 0x200C || codePoint == 0x200D) zeroWidthJoiner = true;
      if ((codePoint >= 0x0900 && codePoint <= 0x097F) ||
          (codePoint >= 0x0A00 && codePoint <= 0x0A7F)) {
        devanagariOrGurmukhi = true;
      }
    }
  }
  var folded = out.toString();
  if (zeroWidthJoiner) {
    folded = folded
        .replaceAllMapped(
          _oldChillu,
          (m) => String.fromCharCode(_chillus[m[1]!.codeUnitAt(0)]!),
        )
        .replaceAllMapped(_zeroWidthAfterVirama, (m) => m[1]!);
  }
  if (devanagariOrGurmukhi) {
    folded = folded.replaceAll(_nukta, '').replaceAll('\u{901}', '\u{902}');
    if (nasalsAsAnusvara) folded = folded.replaceAll(_nasalVirama, '\u{902}');
  }
  return folded;
}

bool _isAscii(String text) {
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) >= 0x80) return false;
  }
  return true;
}

/// Whether search drops [codePoint]: a run of [searchDropRanges] holds it.
bool _dropped(int codePoint) {
  var low = 0;
  var high = searchDropRanges.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    final (first, last) = searchDropRanges[middle];
    if (codePoint < first) {
      high = middle - 1;
    } else if (codePoint > last) {
      low = middle + 1;
    } else {
      return true;
    }
  }
  return false;
}

/// The value of [codePoint] as a decimal digit outside ASCII, or -1.
int _digit(int codePoint) {
  var low = 0;
  var high = searchDigitZeros.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    final zero = searchDigitZeros[middle];
    if (codePoint < zero) {
      high = middle - 1;
    } else if (codePoint > zero + 9) {
      low = middle + 1;
    } else {
      return codePoint - zero;
    }
  }
  return -1;
}

/// A Malayalam chillu written the old way: the consonant, a virama and a
/// zero-width joiner.
final _oldChillu = RegExp(
  '([\u{D15}\u{D23}\u{D28}\u{D30}\u{D32}\u{D33}])\u{D4D}\u{200D}',
);

/// The atomic chillu letter of each consonant [_oldChillu] finds.
const _chillus = {
  0xD15: 0xD7F, // ka
  0xD23: 0xD7A, // nna
  0xD28: 0xD7B, // na
  0xD30: 0xD7C, // ra
  0xD32: 0xD7D, // la
  0xD33: 0xD7E, // lla
};

/// A virama of an Indic script or Sinhala, then a zero-width joiner or
/// non-joiner, which only asks for another shape of the same letters.
final _zeroWidthAfterVirama = RegExp(
  '([\u{94D}\u{9CD}\u{A4D}\u{ACD}\u{B4D}\u{BCD}\u{C4D}\u{CCD}\u{D4D}\u{DCA}])'
  '[\u{200C}\u{200D}]',
);

/// The Devanagari and Gurmukhi nukta, which Hindi and Punjabi often leave out
/// ("ज़िंदगी", "जिंदगी").
final _nukta = RegExp('[\u{93C}\u{A3C}]');

/// A Devanagari nasal and virama before a consonant: the same sound as an
/// anusvara ("हिन्दी", "हिंदी").
final _nasalVirama = RegExp(
  '[\u{919}\u{91E}\u{923}\u{928}\u{92E}]\u{94D}(?=[\u{915}-\u{939}])',
);
