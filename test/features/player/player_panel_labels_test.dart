import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_labels.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

/// The two derivations the panel cannot get from anywhere else: what a
/// plugin's source string is actually saying, and what to call a track libVLC
/// declined to name. Both are pure, so both are tested without a tree.
void main() {
  StreamResult source(String label) =>
      StreamResult(url: 'https://example.test/a', source: label);

  group('sourceFactsOf', () {
    test('lifts quality, size and seeders out of a torrent label', () {
      final facts = sourceFactsOf(
        source('Torrentio 1080p · The.Body.WEB-DL · 2.13 GB · 👤 45'),
      );

      expect(facts.quality, '1080p');
      expect(facts.size, '2.1 GB');
      expect(facts.seeders, 45);
    });

    test('does not print the size and seeders twice', () {
      final facts = sourceFactsOf(source('1080p | 2.13 GB | 45 seeders'));

      expect(facts.title, isNot(contains('GB')));
      expect(facts.title, isNot(contains('seeders')));
      expect(facts.title, '1080p');
    });

    test('reads the spelled-out and prefixed seeder forms', () {
      expect(sourceFactsOf(source('4K · Seeders: 7')).seeders, 7);
      expect(sourceFactsOf(source('720p S: 12')).seeders, 12);
    });

    test('does not mistake a season number for a seeder count', () {
      expect(sourceFactsOf(source('Show.S02E04.1080p.WEB')).seeders, isNull);
    });

    test('normalises units and separators', () {
      expect(sourceFactsOf(source('700 mb')).size, '700 MB');
      expect(sourceFactsOf(source('1,5GiB')).size, '1.5 GB');
      expect(sourceFactsOf(source('2.0 GB')).size, '2 GB');
    });

    test('says nothing about quality it cannot see', () {
      expect(sourceFactsOf(source('Server 2')).quality, isNull);
      expect(sourceFactsOf(source('Server 2')).title, 'Server 2');
    });

    test('collapses a multi-line label into one readable line', () {
      final facts = sourceFactsOf(source('Torrentio\n1080p\n\nWEB-DL'));

      expect(facts.title, 'Torrentio 1080p WEB-DL');
    });

    test('never returns an empty title, whatever it removed', () {
      expect(sourceFactsOf(source('2.13 GB')).title, isNotEmpty);
    });
  });

  group('trackLabel', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    VlcTrackDescription track(String name, {String? language, int id = 3}) =>
        VlcTrackDescription(id: id, name: name, language: language);

    test('keeps a name the engine actually gave', () {
      expect(trackLabel(track('Director commentary'), null, l10n),
          'Director commentary');
    });

    test('replaces the engine counting with the language', () {
      expect(trackLabel(track('Track 3', language: 'eng'), null, l10n),
          'English');
      expect(trackLabel(track('', language: 'jpn'), null, l10n), 'Japanese');
    });

    test('falls back to the media info language when the track has none', () {
      const info = VlcMediaTrackInfo(type: 'audio', language: 'fre');

      expect(trackLabel(track(''), info, l10n), 'French');
    });

    test('prints an unmapped code rather than guessing', () {
      expect(trackLabel(track('', language: 'zzz'), null, l10n), 'ZZZ');
    });

    test('keeps the engine number when there is nothing else at all', () {
      expect(trackLabel(track(''), null, l10n), l10n.playerTrackNumber(3));
    });

    test('ignores an undefined language', () {
      expect(trackLabel(track('', language: 'und'), null, l10n),
          l10n.playerTrackNumber(3));
    });
  });

  group('trackDetail', () {
    test('reads codec, channels and bitrate', () {
      const info = VlcMediaTrackInfo(
        type: 'audio',
        codec: 'ac3',
        channels: 6,
        bitrate: 448000,
      );

      expect(trackDetail(info), 'AC3 · 5.1 · 448 kbps');
    });

    test('omits what VLC did not find out', () {
      const info = VlcMediaTrackInfo(type: 'audio', codec: 'aac', bitrate: 0);

      expect(trackDetail(info), 'AAC');
    });

    test('is absent rather than empty when there is no info at all', () {
      expect(trackDetail(null), isNull);
      expect(trackDetail(const VlcMediaTrackInfo(type: 'audio')), isNull);
    });
  });
}
