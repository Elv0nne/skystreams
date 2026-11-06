import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/presentation/search_provider.dart';

/// Search keeps a result only when every word of the query begins a word of
/// its title, or, in a script written without spaces, is anywhere in it.
/// Words are split at punctuation as well as spaces: a title's year in
/// brackets, or a hyphenated name, is still made of words. Both sides are
/// folded first (search_fold_test.dart), and a title's words count in their
/// other spellings too: joined, German, Hindi with its nasals as written,
/// Arabic without its article.
void main() {
  test('a year in brackets is a word', () {
    expect(searchWords('His Girl Friday (1940)'), [
      'his',
      'girl',
      'friday',
      '1940',
    ]);
    expect(
      titleMatches(
        'His Girl Friday (1940)',
        searchWords('his girl friday 1940'),
      ),
      isTrue,
    );
  });

  test('hyphens, colons and apostrophes split words', () {
    expect(searchWords("Spider-Man: Don't Look Back"), [
      'spider',
      'man',
      'don',
      't',
      'look',
      'back',
    ]);
    expect(
      titleMatches('Spider-Man: No Way Home', searchWords('spider man')),
      isTrue,
    );
    expect(
      titleMatches('Spider-Man: No Way Home', searchWords('spider-man')),
      isTrue,
    );
  });

  test('words still have to begin a title word, in any order', () {
    expect(
      titleMatches('Night of the Living Dead', searchWords('dead night')),
      isTrue,
    );
    expect(
      titleMatches('Night of the Living Dead', searchWords('ight')),
      isFalse,
    );
    expect(
      titleMatches('Night of the Living Dead', searchWords('night zombie')),
      isFalse,
    );
  });

  test('letters and digits of any script stay words', () {
    // 進 as Simplified Chinese writes it, 进: search folds a Traditional
    // character to its Simplified one in a title and a query alike.
    expect(searchWords('Shingeki no Kyojin (進撃の巨人)'), [
      'shingeki',
      'no',
      'kyojin',
      '进撃の巨人',
    ]);
    expect(searchWords('Pokémon 2000'), ['pokemon', '2000']);
    expect(
      titleMatches('Pokémon: The Movie 2000', searchWords('pokémon 2000')),
      isTrue,
    );
  });

  test('a query of only punctuation has no words', () {
    expect(searchWords(' --- '), isEmpty);
  });

  test('words are folded as titles are, accents and all', () {
    expect(searchWords('Işıklar Sönmesin'), ['isiklar', 'sonmesin']);
    expect(searchWords('مُسَلْسَل الحفرة'), ['مسلسل', 'الحفره']);
    expect(searchWords('ＳＰＹ×ＦＡＭＩＬＹ'), ['spy', 'family']);
  });

  test('the vowel signs and viramas of a word stay in it', () {
    // Split at them, Hindi and Tamil words fell apart into letters that
    // began words of unrelated titles.
    expect(searchWords('तारे ज़मीन पर'), ['तारे', 'जमीन', 'पर']);
    expect(searchWords('ஜெயிலர் விக்ரம்'), ['ஜெயிலர்', 'விக்ரம்']);
    expect(searchWords('ร่างทรง'), ['ร่างทรง']);
    expect(titleMatches('तारे ज़मीन पर', searchWords('मिर्ज़ापुर')), isFalse);
    expect(titleMatches('ஜெயிலர்', searchWords('லியோ')), isFalse);
  });

  test('title words joined by an apostrophe, hyphen, dot, middle dot or '
      'zero-width (non-)joiner are found joined too', () {
    for (final (title, query) in const [
      ("Grey's Anatomy", 'greys anatomy'),
      ('Assassin\u{2019}s Creed', 'assassins creed'),
      ('As a Reincarnated Aristocrat, I`ll', 'ill'),
      ('Spider-Man: No Way Home', 'spiderman'),
      ("Marvel's Agents of S.H.I.E.L.D.", 'marvels agents of shield'),
      ('WALL·E', 'walle'),
      ('بچه\u{200C}های آسمان', 'بچههای'),
    ]) {
      expect(titleMatches(title, searchWords(query)), isTrue, reason: title);
    }
  });

  test('a joined form begins where its first part does', () {
    expect(titleMatches('Spider-Man', searchWords('derman')), isFalse);
    expect(titleMatches('Spider-Man', searchWords('man')), isTrue);
    expect(titleMatches('Batman Begins', searchWords('man')), isFalse);
    expect(
      titleMatches('E.T. the Extra-Terrestrial', searchWords('et')),
      isTrue,
    );
  });

  test('an Arabic title word is found without a leading "and" or article', () {
    for (final (title, query) in const [
      ('توم وجيري', 'جيري'), // wa-
      ('رِحْلَةُ البَحْرِ', 'بحر'), // al-
      ('فيلم الحرب والسلام', 'سلام'), // wa-al-
      ('حب بالصدفة', 'صدفة'), // bil-
      ('كالسيف', 'سيف'), // kal-
      ('فالحب', 'حب'), // fal-
      ('للبيع', 'بيع'), // lil-
    ]) {
      expect(titleMatches(title, searchWords(query)), isTrue, reason: title);
    }
  });

  test('a short Arabic word keeps its first letters', () {
    // و of a word under four letters, or an article before a single letter,
    // is part of the word.
    expect(titleMatches('ولد', searchWords('لد')), isFalse);
    expect(titleMatches('الم', searchWords('م')), isFalse);
  });

  test('a query word in a script written without spaces is found anywhere in '
      'the title, across its spaces', () {
    for (final (title, query) in const [
      ('哪吒之魔童降世', '魔童'), // Han
      ('名探偵コナン 黒鉄の魚影', 'コナン'), // katakana
      ('千と千尋の神隠し', 'と千尋'), // hiragana
      ('오징어 게임', '오징어게임'), // Hangul
      ('พี่มากพระโขนง', 'พระโขนง'), // Thai
      ('ກຂຄງ', 'ຂຄ'), // Lao
      ('កខគឃ', 'ខគ'), // Khmer
      ('ကခဂဃ', 'ခဂ'), // Myanmar
    ]) {
      expect(titleMatches(title, searchWords(query)), isTrue, reason: title);
    }
    expect(titleMatches('ドラえもん', searchWords('コナン')), isFalse);
  });

  test('other query words still begin a title word', () {
    const title = '進撃の巨人 The Final Season';
    expect(titleMatches(title, searchWords('巨人 final')), isTrue);
    expect(titleMatches(title, searchWords('巨人 inal')), isFalse);
    expect(titleMatches('Superman', searchWords('man')), isFalse);
  });

  test('a title with ä, ö or ü is found spelled with ae, oe or ue too', () {
    for (final (title, query) in const [
      ('Fack ju Göhte', 'fack ju goehte'),
      ('Fack ju Go\u{308}hte', 'goehte'),
      ('Männerherzen', 'maennerherzen'),
      ('MÄNNERHERZEN', 'maenner'),
      ('Türkisch für Anfänger', 'tuerkisch fuer anfaenger'),
      ('Türkisch für Anfänger', 'turkisch fur anfanger'),
    ]) {
      expect(titleMatches(title, searchWords(query)), isTrue, reason: title);
    }
  });

  test('a Hindi title word is found typed up to a nasal that, with a virama '
      'before a consonant, folds to an anusvara', () {
    final missed = [
      for (final (title, query) in const [
        ('सेक्रेड गेम्स', 'गेम'), // Sacred Games
        ('फिल्म्स', 'फिल्म'),
        ('टाइम्स', 'टाइम'),
        ('जेम्स बॉन्ड', 'जेम'), // James Bond
        ('हिन्दी', 'हिन'),
        ('ज़िन्दगी ना मिलेगी दोबारा', 'जिन'), // and without its nukta
      ])
        if (!titleMatches(title, searchWords(query))) '"$query" in "$title"',
    ];
    expect(missed, isEmpty);
  });

  test('a Hindi title word is found typed up to its second such nasal', () {
    // Typed so far, the word folds its first nasal to an anusvara and keeps
    // the second as written.
    expect(titleMatches('चन्द्रकान्ता', searchWords('चन्द्रकान')), isTrue);
    expect(titleMatches('चन्द्रकान्ता', searchWords('चन्द्रकान्')), isTrue);
  });

  test('a Hindi nasal with a virama before a consonant, and an anusvara, '
      'find each other', () {
    expect(titleMatches('हिन्दी', searchWords('हिंदी')), isTrue);
    expect(titleMatches('हिंदी', searchWords('हिन्दी')), isTrue);
    expect(titleMatches('चन्द्रकान्ता', searchWords('चंद्रकांता')), isTrue);
    expect(titleMatches('चंद्रकांता', searchWords('चन्द्रकान्ता')), isTrue);
  });

  group('answeredInOtherScripts', () {
    // A site may answer a search with titles in another script than the
    // query's (issue #36): an Arabic search, Turkish titles. No title shows a
    // query word then, and search keeps the answer as the site sent it.
    test('is true when no title has a letter in a script of the query', () {
      for (final (titles, query) in const [
        (['Tasacak Bu Deniz', 'The Sea Will Overflow'], 'هذا البحر سوف يفيض'),
        (['Demon Slayer: Kimetsu no Yaiba'], '鬼滅の刃'),
        (['Squid Game'], '오징어 게임'),
        (['오징어 게임'], 'squid game'),
      ]) {
        expect(
          answeredInOtherScripts(titles, searchWords(query)),
          isTrue,
          reason: query,
        );
      }
    });

    test('is false when a title has a letter in a script of the query', () {
      for (final (titles, query) in const [
        (['Tasacak Bu Deniz', 'مسلسل هذا البحر سيفيض'], 'هذا البحر سوف يفيض'),
        (['Batman Begins', 'Superman'], 'spider man'),
        (['ＳＰＹ×ＦＡＭＩＬＹ'], 'spy family'),
        (['Squid Game'], 'squid 오징어'),
      ]) {
        expect(
          answeredInOtherScripts(titles, searchWords(query)),
          isFalse,
          reason: query,
        );
      }
    });

    test('is false when no title has a letter', () {
      // A broken site's answer, blank titles or years alone, is in no script:
      // it is held to the query's words, which none of it has.
      for (final titles in const [
        ['', '', ''],
        ['1917', '2012'],
      ]) {
        for (final query in const ['batman', 'هذا البحر سوف يفيض']) {
          expect(
            answeredInOtherScripts(titles, searchWords(query)),
            isFalse,
            reason: '$titles for "$query"',
          );
        }
      }
    });

    test('is true when one title has a letter, though the others have '
        'none', () {
      expect(
        answeredInOtherScripts([
          '1917',
          'Tasacak Bu Deniz',
        ], searchWords('هذا البحر سوف يفيض')),
        isTrue,
      );
    });

    test('tells Japanese kana from Chinese characters, as Unicode does', () {
      expect(answeredInOtherScripts(['名侦探柯南'], searchWords('コナン')), isTrue);
      expect(answeredInOtherScripts(['名探偵コナン'], searchWords('コナン')), isFalse);
    });

    test(
      'is false for a query with no letters, which is held to its words',
      () {
        expect(
          answeredInOtherScripts(['दंगल', '1917'], searchWords('1917')),
          isFalse,
        );
      },
    );
  });
}
