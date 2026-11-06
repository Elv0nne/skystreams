import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/domain/search_fold.dart';
import 'package:skystream/features/search/domain/search_fold_table.dart';

/// Search folds a title and a query the same way before it compares them, so
/// the spellings people type and the ones sites write come out the same.
/// Characters a reader can't see, or can't tell from others, are escapes.
void main() {
  group('foldForSearch', () {
    test('lowercases ASCII and changes nothing else in it', () {
      expect(
        foldForSearch("Spider-Man: Don't Look Back (2026)"),
        "spider-man: don't look back (2026)",
      );
    });

    test('drops accents, precomposed or written as combining marks', () {
      expect(foldForSearch('Pokémon'), 'pokemon');
      expect(foldForSearch('Poke\u{301}mon'), 'pokemon');
      expect(foldForSearch('Mắt Biếc'), 'mat biec');
      expect(foldForSearch('Ma\u{306}\u{301}t Bie\u{302}\u{301}c'), 'mat biec');
      expect(foldForSearch('Άγριες Μέλισσες'), 'αγριεσ μελισσεσ');
    });

    test('folds letters with no decomposition to the letters people type', () {
      for (final (text, folded) in const [
        ('Chłopi', 'chlopi'),
        ('Bølgen', 'bolgen'),
        ('Đất', 'dat'),
        ('Ófærð', 'ofaerd'),
        ("L'Arnacœur", "l'arnacoeur"),
        ('Großstadtrevier', 'grossstadtrevier'),
        ('Þór', 'thor'),
        ('Işık', 'isik'),
        ('İstanbul', 'istanbul'),
        ('Bəxt', 'bext'),
        ('ΟΔΥΣΣΕΑΣ', 'οδυσσεασ'),
        ('οδυσσεας', 'οδυσσεασ'),
        ('Чёрное', 'черное'),
        ('Мой', 'мои'),
        ('сім\u{2BC}я', "сім'я"),
      ]) {
        expect(foldForSearch(text), folded, reason: text);
      }
    });

    test('folds Arabic letter variants', () {
      expect(foldForSearch('أ إ آ ٱ'), 'ا ا ا ا');
      expect(foldForSearch('ؤ ئ ى ة'), 'و ي ي ه');
    });

    test('folds Persian and Urdu letters to the Arabic ones', () {
      expect(foldForSearch('ی ک ہ ۀ'), 'ي ك ه ه');
    });

    test('drops Arabic vowel and Quranic marks, tatweel and Hebrew points', () {
      expect(foldForSearch('مُسَلْسَل'), 'مسلسل');
      expect(foldForSearch('محمّد'), 'محمد');
      expect(foldForSearch('رَحْمٰن'), 'رحمن');
      expect(foldForSearch('مسلســل'), 'مسلسل');
      expect(foldForSearch('מָשָׁה וְהַדֹּב'), 'משה והדב');
    });

    test('drops invisible characters', () {
      for (final invisible in const [
        '\u{AD}', // soft hyphen
        '\u{200B}', // zero-width space
        '\u{2060}', // word joiner
        '\u{FEFF}', // byte order mark
        '\u{200E}', // left-to-right mark
        '\u{200F}', // right-to-left mark
        '\u{61C}', // Arabic letter mark
        '\u{202A}', // left-to-right embedding
        '\u{202E}', // right-to-left override
        '\u{2066}', // left-to-right isolate
        '\u{2069}', // pop directional isolate
        '\u{FE0F}', // variation selector 16
        '\u{E0100}', // variation selector 17
      ]) {
        expect(
          foldForSearch('Bridg${invisible}erton'),
          'bridgerton',
          reason: 'U+${invisible.runes.single.toRadixString(16)}',
        );
      }
    });

    test('writes the digits of every script as 0 to 9', () {
      expect(
        foldForSearch('٢٠١٩ ۲۰۱۹ १९९२ ๒๕๖๗ ၁၂ ១៩'),
        '2019 2019 1992 2567 12 19',
      );
      expect(foldForSearch('２０２４ 𝟚𝟘𝟚𝟜'), '2024 2024');
    });

    test('writes full-width ASCII as ASCII', () {
      expect(foldForSearch('ＳＰＹ×ＦＡＭＩＬＹ'), 'spy×family');
    });

    test('writes half-width katakana and voiced kana one way', () {
      expect(foldForSearch('ｽﾊﾟｲﾌｧﾐﾘｰ'), foldForSearch('スパイファミリー'));
      expect(foldForSearch('ガンダム'), foldForSearch('カ\u{3099}ンダム'));
      expect(foldForSearch('ぱ'), foldForSearch('は\u{309A}'));
    });

    test('spells out ligatures', () {
      expect(foldForSearch('The Pro\u{FB01}le'), 'the profile');
      expect(foldForSearch('Æon Flux'), 'aeon flux');
    });

    test('gives apostrophes, hyphens and middle dots one form each', () {
      expect(
        foldForSearch(
          'Grey\u{2019}s Grey\u{2BC}s Hawai\u{2BB}i Don\u{B4}t ג\u{5F3}וקר',
        ),
        "grey's grey's hawai'i don't ג'וקר",
      );
      expect(foldForSearch('a\u{2010}b a\u{2011}b'), 'a-b a-b');
      expect(
        foldForSearch('トム\u{30FB}ハンクス 哈利\u{2027}波特 WALL\u{B7}E'),
        'トム\u{B7}ハンクス 哈利\u{B7}波特 wall\u{B7}e',
      );
    });

    test('keeps the vowel signs and viramas inside Indic and Thai words', () {
      for (final word in const [
        'दंगल',
        'स्कैम',
        'ஜெயிலர்',
        'ಕಾಂತಾರ',
        'ร่างทรง',
      ]) {
        expect(foldForSearch(word), word);
      }
    });

    test('writes two-part vowels one way', () {
      // Tamil o, and Malayalam o and oo, precomposed and in two parts.
      expect(
        foldForSearch('ப\u{BCA}ன்னி'),
        foldForSearch('ப\u{BC6}\u{BBE}ன்னி'),
      );
      expect(
        foldForSearch('ക\u{D4A}റ\u{D4B}ണ'),
        foldForSearch('ക\u{D46}\u{D3E}റ\u{D47}\u{D3E}ണ'),
      );
    });

    test('drops the nukta of Devanagari and Gurmukhi letters', () {
      expect(foldForSearch('ज\u{93C}िंदगी'), 'जिंदगी');
      expect(foldForSearch('\u{95B}िंदगी'), 'जिंदगी');
      expect(foldForSearch('ਸੁਫ\u{A3C}ਨਾ'), 'ਸੁਫਨਾ');
      expect(foldForSearch('ਸੁ\u{A5E}ਨਾ'), 'ਸੁਫਨਾ');
    });

    test('writes chandrabindu, and a nasal with a virama before a consonant, '
        'as anusvara', () {
      expect(foldForSearch('फ\u{901}ड्री'), 'फ\u{902}ड्री');
      expect(foldForSearch('हिन\u{94D}दी'), 'हि\u{902}दी');
      expect(foldForSearch('अम\u{94D}बर'), 'अ\u{902}बर');
    });

    test('writes old Malayalam chillu letters as the atomic ones', () {
      expect(foldForSearch('മഞ്ഞുമ്മല\u{D4D}\u{200D}'), 'മഞ്ഞുമ്മ\u{D7D}');
      expect(foldForSearch('അവന\u{D4D}\u{200D}'), 'അവ\u{D7B}');
    });

    test('writes Traditional Chinese characters as their Simplified ones', () {
      expect(foldForSearch('慶餘年'), foldForSearch('庆余年'));
      expect(foldForSearch('甄嬛傳'), '甄嬛传');
      expect(foldForSearch('東京愛情故事'), '东京爱情故事');
      // Two Traditional characters, one Simplified one.
      expect(foldForSearch('發'), foldForSearch('髮'));
    });

    // 復, 著 and 裡 are Simplified too, but mainland titles write them 复, 着
    // and 里: written as those, a search in either script finds the other.
    // Search only filters what a site returned, so where two words meet (乾隆
    // and 干) nothing is lost.
    test('writes a character with a second Simplified form as that one', () {
      expect(foldForSearch('復仇者聯盟'), foldForSearch('复仇者联盟'));
      expect(foldForSearch('活著'), foldForSearch('活着'));
      expect(foldForSearch('這裡'), foldForSearch('这里'));
    });

    test('drops a zero-width joiner or non-joiner after a virama', () {
      expect(foldForSearch('क\u{94D}\u{200D}ष'), 'क\u{94D}ष');
      expect(foldForSearch('ന\u{D4D}\u{200C}ന'), 'ന\u{D4D}ന');
    });

    test(
      'keeps a zero-width non-joiner between the parts of a Persian word',
      () {
        expect(foldForSearch('بچه\u{200C}های'), 'بچه\u{200C}هاي');
      },
    );
  });

  group('the fold table', () {
    test('has the entries search relies on', () {
      expect(searchFoldTable.length, inInclusiveRange(300, 1000));
      for (final (codePoint, folded) in const [
        (0xE9, 'e'), // é
        (0xDF, 'ss'), // ß
        (0x131, 'i'), // ı
        (0x142, 'l'), // ł
        (0x451, '\u{435}'), // ё to е
        (0x439, '\u{438}'), // й to и
        (0x3C2, '\u{3C3}'), // ς to σ
        (0x623, '\u{627}'), // أ to ا
        (0x629, '\u{647}'), // ة to ه
        (0x6CC, '\u{64A}'), // ی to ي
        (0x6A9, '\u{643}'), // ک to ك
        (0x2BC, "'"), // ʼ
        (0x2019, "'"), // ’
        (0x30FB, '\u{B7}'), // ・ to ·
        (0xFB01, 'fi'), // ﬁ
        (0xFF76, '\u{30AB}'), // ｶ to カ
        (0x30AC, '\u{30AB}\u{3099}'), // ガ to カ and its voiced mark
      ]) {
        expect(
          searchFoldTable[codePoint],
          folded,
          reason: 'U+${codePoint.toRadixString(16)}',
        );
      }
    });

    test('is what tool/search_fold_table.py makes', () {
      final table = File('lib/features/search/domain/search_fold_table.dart')
          .readAsStringSync();
      final unicode = RegExp(r'from Unicode (\S+)\.').firstMatch(table)?[1];
      expect(unicode, isNotNull, reason: "the table's header names Unicode");
      final ProcessResult local;
      try {
        local = Process.runSync('python3', [
          '-I',
          '-c',
          'import unicodedata; print(unicodedata.unidata_version)',
        ]);
      } on ProcessException {
        markTestSkipped('no python3 to run the generator with');
        return;
      }
      final localUnicode = '${local.stdout}'.trim();
      if (local.exitCode != 0 || localUnicode != unicode) {
        markTestSkipped(
          "python3 has Unicode '$localUnicode', the table $unicode",
        );
        return;
      }
      // UTF-8 whatever the system's code page: the table has Chinese in it.
      final made = Process.runSync('python3', [
        '-I',
        'tool/search_fold_table.py',
      ], stdoutEncoding: utf8);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      expect(made.stdout, table);
    });
  });
}
