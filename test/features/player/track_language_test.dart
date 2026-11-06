import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/track_language.dart';

/// What language a track is in, read from what the engine says about it.
///
/// On a device the engine's track list carries no language at all - every
/// native sends `language: null` - so a track's name is what is left: libVLC's
/// `Track 2 - [Hindi]`, a source's own `Hindi DD 5.1 - [Hindi]`, a release
/// group's `Tam 5.1`, or a name in the language's own script.
void main() {
  group('a track name', () {
    test('is read for the language libVLC put in its brackets', () {
      expect(languageCodeOfTrackName('Track 2 - [Hindi]'), 'hi');
      expect(languageCodeOfTrackName('Hindi DD 5.1 - [Hindi]'), 'hi');
      expect(languageCodeOfTrackName('Track 1 - [English]'), 'en');
    });

    test('names the language libVLC calls Panjabi', () {
      expect(languageCodeOfTrackName('Track 2 - [Panjabi]'), 'pa');
    });

    test('takes the brackets over the description beside them', () {
      // libVLC's brackets are the language the source declared; the words in
      // front are whatever its maker typed.
      expect(languageCodeOfTrackName('Hindi (dub) - [English]'), 'en');
    });

    test('falls back to the description when the brackets name no language '
        'known here', () {
      expect(languageCodeOfTrackName('Hindi - [qaa]'), 'hi');
      expect(languageCodeOfTrackName('Track 3 - [Dogri]'), isNull);
    });

    test('reads the three-letter code a release group leads with', () {
      expect(languageCodeOfTrackName('Tam 5.1'), 'ta');
      expect(languageCodeOfTrackName('Hin - AAC'), 'hi');
      expect(languageCodeOfTrackName('Eng DD 5.1'), 'en');
      expect(languageCodeOfTrackName('ENG 2.0'), 'en');
      expect(languageCodeOfTrackName('[Mal] DD+ 5.1'), 'ml');
    });

    test('reads the shorthand before a codec, a channel layout or the end of '
        'the name', () {
      expect(languageCodeOfTrackName('Ita AC3'), 'it');
      expect(languageCodeOfTrackName('Ger TrueHD Atmos 7.1'), 'de');
      expect(languageCodeOfTrackName('Jpn FLAC'), 'ja');
      expect(languageCodeOfTrackName('Rus Stereo'), 'ru');
      expect(languageCodeOfTrackName('Kor-Opus'), 'ko');
      expect(languageCodeOfTrackName('Tel6ch'), 'te');
      expect(languageCodeOfTrackName('Kan'), 'kn');
      expect(languageCodeOfTrackName('Eng SDH'), 'en');
    });

    test('takes no shorthand from a name that goes on in words', () {
      // Each of these leads with a code that is also a word, and goes on the
      // way a sentence does rather than the way a track label does.
      for (final name in <String>['Fra Diavolo', 'Tel quel', 'Mal de mer']) {
        expect(languageCodeOfTrackName(name), isNull, reason: name);
      }
    });

    test('takes no shorthand from a code that is an everyday word', () {
      for (final name in <String>[
        'Ben 2.0',
        'Mar 2.0',
        'Pan 5.1',
        'Por favor',
        'Fin',
        'Vie Sauvage',
        'Per non vedenti',
        "Dan's Commentary",
        'May 2019 Remaster',
        'Ori 5.1',
      ]) {
        expect(languageCodeOfTrackName(name), isNull, reason: name);
      }
    });

    test('reads a name in the language\'s own script', () {
      expect(languageCodeOfTrackName('ಕನ್ನಡ'), 'kn');
      expect(languageCodeOfTrackName('മലയാളം'), 'ml');
      expect(languageCodeOfTrackName('বাংলা'), 'bn');
      expect(languageCodeOfTrackName('मराठी 5.1'), 'mr');
      expect(languageCodeOfTrackName('ગુજરાતી'), 'gu');
      expect(languageCodeOfTrackName('ਪੰਜਾਬੀ'), 'pa');
      expect(languageCodeOfTrackName('অসমীয়া'), 'as');
    });

    test('says nothing when it names no language', () {
      for (final name in <String?>[
        null,
        '',
        'Track 1',
        'AAC 5.1',
        'Stereo',
        'Original',
        'Hi-Res Audio',
        'DTS',
        'Dub 2.0',
      ]) {
        expect(languageCodeOfTrackName(name), isNull, reason: '$name');
      }
    });
  });

  group('Odia', () {
    test('is known by its codes, its names and its script', () {
      expect(languageCodeOf('or'), 'or');
      expect(languageCodeOf('ori'), 'or');
      expect(languageCodeOf('ory'), 'or');
      expect(languageCodeOf('Odia'), 'or');
      expect(languageCodeOf('ଓଡ଼ିଆ'), 'or');
      expect(languageNameForCode('or'), 'Odia');
    });

    test('is what libVLC calls Oriya', () {
      expect(languageCodeOfTrackName('Track 3 - [Oriya]'), 'or');
    });

    test('is not read into the English word "or"', () {
      expect(languageCodeOfTrackName('Stereo or 5.1'), isNull);
    });
  });

  group('the codes libVLC is asked for a language by', () {
    test('are its ISO 639-2 codes and its ISO 639-1 code', () {
      expect(vlcLanguageCodes('hi'), <String>['hin', 'hi']);
      expect(vlcLanguageCodes('de'), <String>['ger', 'deu', 'de']);
    });

    test('are the same whichever of them names it', () {
      expect(vlcLanguageCodes('ger'), <String>['ger', 'deu', 'de']);
      expect(vlcLanguageCodes('pt-BR'), vlcLanguageCodes('pt'));
    });

    test('include a retired code libVLC still files apart', () {
      // libVLC 3 lists Hebrew twice, as `he` and as `iw`, and matches a track
      // tagged `iw` only by the second.
      expect(vlcLanguageCodes('he'), containsAllInOrder(<String>['heb', 'iw']));
    });

    test('are none for a tag that names no language known here', () {
      expect(vlcLanguageCodes(null), isEmpty);
      expect(vlcLanguageCodes('und'), isEmpty);
      expect(vlcLanguageCodes('qaa'), isEmpty);
    });
  });

  // The OpenSubtitles add-on's own codes (2026-10-11): its Traditional and
  // bilingual Chinese, Spain's Spanish and Kurdish were read as no language,
  // so the viewer's language never picked them.
  group('the OpenSubtitles add-on\'s own codes', () {
    test('are read as the language they are in', () {
      expect(languageCodeOf('zht'), 'zh');
      expect(languageCodeOf('zhe'), 'zh');
      expect(languageCodeOf('spn'), 'es');
      expect(languageCodeOf('kur'), 'ku');
    });
  });

  group('the languages the player offers', () {
    test('are the forty the subtitle search has always offered and four '
        'more, India\'s first', () {
      expect(playerLanguages.values.take(10), <String>[
        'en',
        'hi',
        'bn',
        'te',
        'mr',
        'ta',
        'gu',
        'kn',
        'ml',
        'pa',
      ]);
      expect(playerLanguages, hasLength(44));
      expect(playerLanguages.values.toSet(), hasLength(44));
    });

    // Persian, Filipino and Thai were offered for audio before the list was
    // shared; Azerbaijani is a language the app itself is in.
    test('offer Persian, Filipino, Thai and Azerbaijani', () {
      for (final code in <String>['fa', 'fil', 'th', 'az']) {
        expect(playerLanguages.values, contains(code));
      }
    });

    test('keep the rest of the forty the subtitle search has always '
        'offered', () {
      for (final code in <String>[
        'kn', 'gu', 'as', 'be', 'bg', 'cs', 'el', 'he', //
        'hr', 'hu', 'lv', 'mk', 'ro', 'sv',
      ]) {
        expect(playerLanguages.values, contains(code));
      }
    });

    test('are each named as track_language names them', () {
      for (final MapEntry(key: name, value: code) in playerLanguages.entries) {
        expect(languageNameForCode(code), name);
        expect(languageCodeOf(name), code);
      }
    });
  });
}
