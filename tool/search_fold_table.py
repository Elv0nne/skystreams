"""Generates lib/features/search/domain/search_fold_table.dart, the Unicode
data search folds titles and queries with (search_fold.dart).

Run from the repository root:

    python3 -I tool/search_fold_table.py > lib/features/search/domain/search_fold_table.dart

It reads Python's unicodedata, and Unihan's kSimplifiedVariant lines from
tool/unihan_simplified_variants.txt for the Traditional Chinese characters
search writes as Simplified ones. The output follows the Unicode version of
the Python that runs it, which must be the extract's; the file's header
records that version, and test/features/search/search_fold_test.dart checks
the file against this script wherever python3 has the same one.

search_fold.dart lowercases with Dart's String.toLowerCase() first and then
folds one code point at a time, so the table needs only lowercase and
caseless characters.
"""
import os
import re
import sys
import unicodedata as ud

OUTPUT = 'lib/features/search/domain/search_fold_table.dart'
UNIHAN = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      'unihan_simplified_variants.txt')


def span(first, last):
    return set(range(first, last + 1))


# Combining marks search drops: on their own, and from precomposed letters.
DIACRITICS = (span(0x0300, 0x036F) | span(0x1AB0, 0x1AFF)
              | span(0x1DC0, 0x1DFF) | span(0x20D0, 0x20FF)
              | span(0xFE20, 0xFE2F))
ARABIC_MARKS = (span(0x0610, 0x061A) | span(0x064B, 0x065F) | {0x0670}
                | span(0x06D6, 0x06DC) | span(0x06DF, 0x06E4)
                | span(0x06E7, 0x06E8) | span(0x06EA, 0x06ED)
                | span(0x08CA, 0x08E1) | span(0x08E3, 0x08FF))
HEBREW_POINTS = (span(0x0591, 0x05BD)
                 | {0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7})
MARKS = DIACRITICS | ARABIC_MARKS | HEBREW_POINTS

# Neither part of a word nor a break between words: soft hyphen, Arabic
# letter mark, tatweel, zero-width space, the directional marks, word joiner,
# byte order mark, the directional embeddings, overrides and isolates, and the
# variation selectors.
INVISIBLE = ({0x00AD, 0x061C, 0x0640, 0x200B, 0x200E, 0x200F, 0x2060, 0xFEFF}
             | span(0x202A, 0x202E) | span(0x2066, 0x2069)
             | span(0xFE00, 0xFE0F) | span(0xE0100, 0xE01EF))

DROPPED = MARKS | INVISIBLE

# Characters that join the parts of one word, as the joiner of their kind
# that search_fold.dart knows.
JOINERS = {
    0x00B4: "'",   # acute accent, typed for an apostrophe
    0x02BB: "'",   # modifier letter turned comma (Hawaiian okina)
    0x02BC: "'",   # modifier letter apostrophe
    0x055A: "'",   # Armenian apostrophe
    0x05F3: "'",   # Hebrew geresh
    0x05F4: "'",   # Hebrew gershayim
    0x2018: "'",   # left single quotation mark
    0x2019: "'",   # right single quotation mark
    0x2010: '-',   # hyphen
    0x2011: '-',   # non-breaking hyphen
    0x0387: '\N{MIDDLE DOT}',  # Greek ano teleia
    0x2027: '\N{MIDDLE DOT}',  # hyphenation point
    0x30FB: '\N{MIDDLE DOT}',  # katakana middle dot
    0xFF65: '\N{MIDDLE DOT}',  # halfwidth katakana middle dot
}
JOINER_FORMS = set("'`-.\N{MIDDLE DOT}")

# Letters with no decomposition, as the letters people type for them.
SPECIAL = {
    0x00DF: 'ss',  # sharp s
    0x00E6: 'ae',  # ae
    0x00F0: 'd',   # eth
    0x00F8: 'o',   # o with stroke
    0x00FE: 'th',  # thorn
    0x0111: 'd',   # d with stroke (Vietnamese, Croatian)
    0x0127: 'h',   # h with stroke
    0x0131: 'i',   # dotless i (Turkish, Azerbaijani)
    0x0140: 'l',   # l with middle dot
    0x0142: 'l',   # l with stroke
    0x0153: 'oe',  # oe
    0x0167: 't',   # t with stroke
    0x017F: 's',   # long s
    0x0259: 'e',   # schwa (Azerbaijani)
    0x03C2: '\N{GREEK SMALL LETTER SIGMA}',  # final sigma
    0x0629: '\N{ARABIC LETTER HEH}',  # teh marbuta
    0x0649: '\N{ARABIC LETTER YEH}',  # alef maksura
    0x0671: '\N{ARABIC LETTER ALEF}',  # alef wasla
    0x06A9: '\N{ARABIC LETTER KAF}',  # keheh (Persian, Urdu)
    0x06C0: '\N{ARABIC LETTER HEH}',  # heh with yeh above
    0x06C1: '\N{ARABIC LETTER HEH}',  # heh goal (Urdu)
    0x06CC: '\N{ARABIC LETTER YEH}',  # Farsi yeh
}

# Blocks the table covers: Latin, Greek, Cyrillic, Hebrew, Arabic, the Indic
# scripts, Vietnamese, general punctuation, Roman numerals, kana, the Latin
# ligatures and halfwidth katakana.
TABLE_BLOCKS = [
    (0x0080, 0x02FF),
    (0x0370, 0x04FF),
    (0x0590, 0x06FF),
    (0x0900, 0x0DFF),
    (0x1E00, 0x1FFF),
    (0x2000, 0x206F),
    (0x2160, 0x217F),
    (0x3040, 0x30FF),
    (0xFB00, 0xFB06),
    (0xFF61, 0xFF9F),
]


def compatibility_block(cp):
    """Whether cp's compatibility decomposition is what people type."""
    return (0xFF00 <= cp <= 0xFFEF        # fullwidth and halfwidth forms
            or 0xFB00 <= cp <= 0xFB4F     # presentation forms; TABLE_BLOCKS
                                          # takes the Latin ligatures only
            or cp in (0x00B2, 0x00B3, 0x00B9)  # superscript digits
            or 0x2160 <= cp <= 0x217F)    # Roman numerals


def fold(ch):
    cp = ord(ch)
    if cp in DROPPED:
        return ''
    if cp in JOINERS:
        return JOINERS[cp]
    if ud.category(ch) == 'Nd':
        return str(ud.decimal(ch))
    if compatibility_block(cp):
        nfkc = ud.normalize('NFKC', ch)
        if nfkc != ch and not nfkc.startswith(' '):
            return ''.join(fold(c) for c in nfkc.lower())
    if cp in SPECIAL:
        return SPECIAL[cp]
    nfd = ud.normalize('NFD', ch)
    if nfd != ch:
        return ''.join(SPECIAL.get(ord(c), c) for c in nfd
                       if ord(c) not in DROPPED).lower()
    return ch


def significant(text):
    """Whether text has a character search compares, or a joiner: a fold
    that only swaps one separator for another changes nothing."""
    return any(ud.category(c)[0] in 'LMN' or c in JOINER_FORMS for c in text)


def table():
    """The code points of TABLE_BLOCKS that fold to something else, and the
    joiners wherever they are."""
    entries = {}
    for first, last in TABLE_BLOCKS:
        for cp in range(first, last + 1):
            ch = chr(cp)
            if ud.category(ch) == 'Cn' or ch.lower() != ch:
                continue  # unassigned, or Dart lowercases it first
            if cp in DROPPED or ud.category(ch) == 'Nd' \
                    or 0xFF01 <= cp <= 0xFF5E:
                continue  # search_fold.dart drops these, or writes them as ASCII
            folded = fold(ch)
            if folded != ch and (significant(ch) or significant(folded)):
                entries[cp] = folded
    for cp, joiner in JOINERS.items():
        entries[cp] = joiner
    return entries


def runs(code_points):
    """code_points as (first, last) runs, in order."""
    out = []
    for cp in sorted(code_points):
        if out and out[-1][1] == cp - 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return out


def digit_zeros():
    """The zero of each run of decimal digits outside ASCII. search_fold.dart
    reads a digit's value as its distance from the zero before it, so each
    run must be the ten digits 0 to 9, which Unicode promises."""
    zeros = [cp for cp in range(0x80, sys.maxunicode + 1)
             if ud.category(chr(cp)) == 'Nd' and ud.decimal(chr(cp)) == 0]
    for zero in zeros:
        assert all(ud.category(chr(zero + d)) == 'Nd'
                   and ud.decimal(chr(zero + d)) == d for d in range(10)), zero
    digits = sum(1 for cp in range(0x80, sys.maxunicode + 1)
                 if ud.category(chr(cp)) == 'Nd')
    assert digits == 10 * len(zeros), (digits, len(zeros))
    return zeros


def han_folds():
    """Traditional Chinese characters and the Simplified ones search writes
    them as, from Unihan's kSimplifiedVariant. A character that lists only
    itself is Simplified already; one that lists itself and another form, as
    復 (复), 著 (着) and 裡 (里) do, is written as that other form, the one
    mainland titles use; and a variant that has a Simplified variant of its
    own is followed to that."""
    variants = {}
    version = None
    with open(UNIHAN, encoding='utf-8') as lines:
        for line in lines:
            if line.startswith('#'):
                found = re.match(r'# Unicode Version (\S+)', line)
                version = version or (found and found.group(1))
                continue
            if not line.strip():
                continue
            cp, field, value = line.rstrip('\n').split('\t')
            assert field == 'kSimplifiedVariant', line
            variants[int(cp[2:], 16)] = [
                int(v, 16) for v in re.findall(r'U\+([0-9A-F]+)', value)]
    assert version == ud.unidata_version, (version, ud.unidata_version)

    def others(cp):
        return [v for v in variants.get(cp, ()) if v != cp]

    folds = {}
    for cp in variants:
        if not others(cp):
            continue
        target, seen = others(cp)[0], {cp}
        while others(target):
            assert target not in seen, ('a loop', cp, target)
            seen.add(target)
            target = others(target)[0]
        folds[cp] = target
    # Folding twice changes nothing: no character is written as one that
    # folds again.
    assert not set(folds.values()) & set(folds), 'a fold folds again'
    return folds


def dart_string(text):
    return "'%s'" % ''.join(
        '\\u{%X}' % ord(c) if ord(c) > 0x7E or c in "'\\$" else c
        for c in text)


def name(cp):
    return ud.name(chr(cp), 'U+%04X' % cp)


def main():
    # The Chinese pairs are written as they are: UTF-8 and Unix line ends on
    # every system, a Windows console's code page included.
    sys.stdout.reconfigure(encoding='utf-8', newline='\n')
    w = sys.stdout.write
    w('// GENERATED by tool/search_fold_table.py from Unicode %s. Do not edit.\n'
      % ud.unidata_version)
    w('// To regenerate, from the repository root:\n')
    w('// python3 -I tool/search_fold_table.py > %s\n' % OUTPUT)
    w('\n')
    w('/// The code points search drops, as the first and last of each run:\n')
    w('/// combining diacritics, Arabic vowel and Quranic marks, Hebrew points,\n')
    w('/// tatweel and invisible characters.\n')
    w('const List<(int, int)> searchDropRanges = [\n')
    for first, last in runs(DROPPED):
        w('  // %s\n' % (name(first) if first == last
                         else '%s to %s' % (name(first), name(last))))
        w('  (0x%04X, 0x%04X),\n' % (first, last))
    w('];\n')
    w('\n')
    w('/// The zero of each run of ten decimal digits outside ASCII, in order.\n')
    w('const List<int> searchDigitZeros = [\n')
    for cp in digit_zeros():
        w('  0x%04X, // %s\n' % (cp, name(cp)))
    w('];\n')
    w('\n')
    w('/// What search writes a lowercase code point as: the base letter of an\n')
    w('/// accented one, the letters people type for one with no decomposition,\n')
    w('/// and one apostrophe, hyphen and middle dot for each of their kinds.\n')
    w('const Map<int, String> searchFoldTable = {\n')
    entries = table()
    for cp in sorted(entries):
        w('  0x%04X: %s,\n' % (cp, dart_string(entries[cp])))
    w('};\n')
    w('\n')
    w('/// Traditional Chinese characters and the Simplified ones search writes\n')
    w('/// them as, in pairs, from Unihan\'s kSimplifiedVariant (Unicode %s).\n'
      % ud.unidata_version)
    w('/// A character that is Simplified too but has a second Simplified form\n')
    w('/// is written as that form, as 著 is as 着.\n')
    w('const String searchHanFolds =\n')
    pairs = ''.join(chr(cp) + chr(folds_to)
                    for cp, folds_to in sorted(han_folds().items()))
    chunk = 64
    for start in range(0, len(pairs), chunk):
        end = ';' if start + chunk >= len(pairs) else ''
        w("    '%s'%s\n" % (pairs[start:start + chunk], end))


if __name__ == '__main__':
    main()
