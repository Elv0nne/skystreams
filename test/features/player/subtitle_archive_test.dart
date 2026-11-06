import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/subtitle_archive.dart';

ArchiveEntry _file(String name, [int size = 40000]) => (name: name, size: size);

void main() {
  group('pickSubtitleEntry', () {
    test('passes over the uploader\'s note for a real subtitle', () {
      // SubDL's first result for Breaking Bad S01E01, as it arrived.
      final entries = [
        _file('00 Breaking Bad, SEASON 1 1080p x265 [23.976 FPS].srt', 296),
        _file('01 Pilot.en.srt'),
        _file('02 Cat\'s in the Bag....en.srt'),
      ];

      expect(
        pickSubtitleEntry(entries, season: 1, episode: 1),
        '01 Pilot.en.srt',
      );
    });

    test('takes the episode being watched from a season pack, not the first '
        'file', () {
      final entries = [
        _file('Breaking Bad  S01E06  Crazy Handful of Nothin`.srt'),
        _file('Breaking Bad  S01E01  Pilot.srt'),
        _file('Breaking Bad  S01E02  Cat\'s in the Bag.srt'),
      ];

      expect(
        pickSubtitleEntry(entries, season: 1, episode: 2),
        'Breaking Bad  S01E02  Cat\'s in the Bag.srt',
      );
    });

    test('reads every way packs number their episodes', () {
      String? pick(String name, {int season = 1, int episode = 7}) =>
          pickSubtitleEntry(
            [_file(name), _file('Other.S01E03.srt')],
            season: season,
            episode: episode,
          );

      expect(pick('show.s01e07.720p.srt'), 'show.s01e07.720p.srt');
      expect(
        pick('--Breaking Bad S1 EP07--.srt'),
        '--Breaking Bad S1 EP07--.srt',
      );
      expect(pick('Show 1x07 Title.srt'), 'Show 1x07 Title.srt');
      expect(pick('Show - Episode 7.srt'), 'Show - Episode 7.srt');
      expect(
        pick('Show Season 1 Episode 07.srt'),
        'Show Season 1 Episode 07.srt',
      );
      expect(pick('07 Title.en.srt'), '07 Title.en.srt');
    });

    test('never hands over another season\'s episode', () {
      final entries = [
        _file('Show.S01E05.srt'),
        _file('Show.S02E05.srt'),
        _file('Show.S03E05.srt'),
      ];

      expect(
        pickSubtitleEntry(entries, season: 2, episode: 5),
        'Show.S02E05.srt',
      );
    });

    test('gives nothing for a pack without the episode', () {
      final entries = [_file('Show.S01E01.srt'), _file('Show.S01E02.srt')];

      expect(pickSubtitleEntry(entries, season: 1, episode: 9), isNull);
    });

    test('keeps a lone untagged file for an episode', () {
      expect(
        pickSubtitleEntry([_file('English.srt')], season: 1, episode: 4),
        'English.srt',
      );
    });

    test('prefers the language asked for, spelled any way', () {
      final entries = [
        _file('Movie.2010.fr.srt', 90000),
        _file('Movie.2010.English.srt', 60000),
        _file('Movie.2010.spa.srt', 70000),
      ];

      expect(
        pickSubtitleEntry(entries, language: 'en'),
        'Movie.2010.English.srt',
      );
      expect(
        pickSubtitleEntry(entries, language: 'Spanish'),
        'Movie.2010.spa.srt',
      );
    });

    test('finds a language a hyphen joins to the word beside it', () {
      // English-SDH, en-US, Movie-English: the hyphen that keeps pt-br whole
      // glued every other language to its neighbour, and the largest file -
      // here the wrong language - won instead.
      expect(
        pickSubtitleEntry([
          _file('Show.S01E01.French.srt', 90000),
          _file('Show.S01E01.English-SDH.srt', 60000),
        ], language: 'en'),
        'Show.S01E01.English-SDH.srt',
      );
      expect(
        pickSubtitleEntry([
          _file('Movie.fr-FR.srt', 90000),
          _file('Movie.en-US.srt', 60000),
        ], language: 'English'),
        'Movie.en-US.srt',
      );
      expect(
        pickSubtitleEntry([
          _file('Movie-French.srt', 90000),
          _file('Movie-English.srt', 60000),
        ], language: 'eng'),
        'Movie-English.srt',
      );
      expect(
        pickSubtitleEntry([
          _file('Movie.en.srt', 90000),
          _file('Movie.pt-BR.srt', 60000),
        ], language: 'pt-br'),
        'Movie.pt-BR.srt',
        reason: 'and pt-br still reads as one',
      );
    });

    test('takes the largest of what is left: a full track over a forced '
        'one', () {
      final entries = [
        _file('Movie.forced.srt', 3000),
        _file('Movie.srt', 70000),
      ];

      expect(pickSubtitleEntry(entries), 'Movie.srt');
    });

    test('reads extensions in any case, and SubStation Alpha\'s older one', () {
      expect(pickSubtitleEntry([_file('MOVIE.SRT')]), 'MOVIE.SRT');
      expect(pickSubtitleEntry([_file('movie.ssa')]), 'movie.ssa');
    });

    test('skips what is not a subtitle, and gives nothing when that is all '
        'there is', () {
      expect(
        pickSubtitleEntry([
          _file('Readme.txt'),
          _file('cover.jpg'),
          _file('sub/Movie.srt'),
        ]),
        'sub/Movie.srt',
      );
      expect(
        pickSubtitleEntry([_file('Readme.txt'), _file('movie.idx')]),
        isNull,
      );
    });

    test('falls back to a small file when it is the only subtitle', () {
      expect(pickSubtitleEntry([_file('Short.srt', 400)]), 'Short.srt');
    });
  });

  group('episodeTagOf', () {
    test('reads the season with the episode where the name has both', () {
      expect(episodeTagOf('The.Show.S02E05.1080p'), (season: 2, episode: 5));
      expect(episodeTagOf('show 3x12'), (season: 3, episode: 12));
    });

    test('reads the episode alone where that is all there is', () {
      expect(episodeTagOf('The.Show.E05.720p'), (season: null, episode: 5));
      expect(episodeTagOf('03 Title.srt'), (season: null, episode: 3));
    });

    test('does not mistake resolutions, codecs or years for episodes', () {
      expect(episodeTagOf('Movie.2010.1920x1080.x265-GRP'), isNull);
      expect(episodeTagOf('Movie.2008.BluRay.1080p.DTS.AC3.x264-3Li'), isNull);
      expect(episodeTagOf('Breaking Bad - Season 1 (WEBRip)'), isNull);
    });
  });
}
