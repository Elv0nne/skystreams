import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/track_memory.dart';
import 'package:vlc_player/vlc_player.dart';

VlcTrackDescription _t(int id, {String? language, String name = ''}) =>
    VlcTrackDescription(id: id, name: name, language: language);

/// Carrying an audio or subtitle pick across a reopen.
///
/// The cost of getting this wrong is asymmetric, and the rules follow from
/// that: handing back the wrong track plays a film in a language the viewer
/// did not choose, while handing back nothing leaves the engine's own default,
/// which is exactly where they would have been anyway. So every rule here
/// prefers null to a guess.
void main() {
  /// Every native sends `language: null` from `getAudioTracks`, so these are
  /// the shapes a device actually produces: libVLC's names, and the language
  /// `getMediaInfo` reports for the track at the same position.
  group('the language of each track', () {
    const disable = VlcTrackDescription(id: -1, name: 'Disable');
    VlcMediaTrackInfo info(String? language) =>
        VlcMediaTrackInfo(type: 'audio', language: language);

    test('is read off libVLC\'s names, with Disable left out', () {
      final tracks = withTrackLanguages(<VlcTrackDescription>[
        disable,
        _t(1, name: 'Track 1 - [English]'),
        _t(2, name: 'Track 2 - [Hindi]'),
      ], const <VlcMediaTrackInfo>[]);

      expect(tracks.map((t) => t.id), <int>[1, 2]);
      expect(tracks.map((t) => t.language), <String>['en', 'hi']);
      expect(tracks.map((t) => t.name), <String>[
        'Track 1 - [English]',
        'Track 2 - [Hindi]',
      ]);
    });

    test('takes getMediaInfo\'s language for the track at its position', () {
      // A libVLC built with its translations names the language in the
      // viewer's own: here, French.
      final tracks = withTrackLanguages(
        <VlcTrackDescription>[
          disable,
          _t(1, name: 'Piste 1 - [Anglais]'),
          _t(2, name: 'Piste 2 - [Tamoul]'),
        ],
        <VlcMediaTrackInfo>[info('eng'), info('tam')],
      );

      expect(tracks.map((t) => t.language), <String>['en', 'ta']);
    });

    test('trusts the track\'s own tag first, and getMediaInfo over the words '
        'of the name', () {
      final tracks = withTrackLanguages(
        <VlcTrackDescription>[
          _t(1, language: 'tur', name: 'Track 1 - [Hindi]'),
          _t(2, name: 'Hindi DD 5.1'),
        ],
        <VlcMediaTrackInfo>[info('eng'), info('eng')],
      );

      expect(tracks.map((t) => t.language), <String>['tr', 'en']);
    });

    test('takes libVLC\'s brackets over getMediaInfo\'s language', () {
      // getMediaInfo's list is matched by position, which a deleted stream or
      // a second program in a TS puts out of step. The brackets are libVLC's
      // word on this very track.
      final tracks = withTrackLanguages(
        <VlcTrackDescription>[
          _t(1, name: 'Track 1 - [Hindi]'),
          _t(2, name: 'Track 2 - [Tamil]'),
        ],
        <VlcMediaTrackInfo>[info('eng'), info('hin')],
      );

      expect(tracks.map((t) => t.language), <String>['hi', 'ta']);
    });

    test('leaves a track that names no language as it was', () {
      final tracks = withTrackLanguages(
        <VlcTrackDescription>[_t(1, language: 'und', name: 'Track 1')],
        <VlcMediaTrackInfo>[info('und')],
      );

      expect(tracks.single.language, 'und');
    });
  });

  group('the track in the preferred audio language', () {
    List<VlcTrackDescription> named(List<String> names) =>
        withTrackLanguages(<VlcTrackDescription>[
          const VlcTrackDescription(id: -1, name: 'Disable'),
          for (final (index, name) in names.indexed) _t(index + 1, name: name),
        ], const <VlcMediaTrackInfo>[]);

    test('is found by the language libVLC names, however it spells it', () {
      final tracks = named(<String>[
        'Track 1 - [English]',
        'Track 2 - [Panjabi]',
        'Track 3 - [Oriya]',
      ]);

      expect(findPreferredAudioTrack(tracks, 'pa')?.id, 2);
      expect(findPreferredAudioTrack(tracks, 'or')?.id, 3);
      expect(findPreferredAudioTrack(tracks, 'eng')?.id, 1);
    });

    test('is found by a release group\'s shorthand', () {
      final tracks = named(<String>['Hin - AAC', 'Tam 5.1']);

      expect(findPreferredAudioTrack(tracks, 'ta')?.id, 2);
      expect(findPreferredAudioTrack(tracks, 'hi')?.id, 1);
    });

    test('is found by a name in the language\'s own script', () {
      final tracks = named(<String>['ಕನ್ನಡ', 'മലയാളം', 'বাংলা']);

      expect(findPreferredAudioTrack(tracks, 'kn')?.id, 1);
      expect(findPreferredAudioTrack(tracks, 'ml')?.id, 2);
      expect(findPreferredAudioTrack(tracks, 'bn')?.id, 3);
    });

    test('is not a track whose description merely mentions the language', () {
      final tracks = named(<String>[
        'Hindi (dub) - [English]',
        'Track 2 - [Hindi]',
      ]);

      expect(findPreferredAudioTrack(tracks, 'hi')?.id, 2);
    });

    test('is the one already playing when it is in that language', () {
      final tracks = named(<String>[
        'Hindi 2.0 - [Hindi]',
        'Hindi DD 5.1 - [Hindi]',
      ]);

      expect(findPreferredAudioTrack(tracks, 'hi', activeId: 2)?.id, 2);
      expect(findPreferredAudioTrack(tracks, 'hi', activeId: 1)?.id, 1);
    });

    test('is the film\'s own track over a commentary in the same language', () {
      final tracks = named(<String>[
        'Track 1 - [Japanese]',
        'English Commentary - [English]',
        'English - [English]',
      ]);

      expect(findPreferredAudioTrack(tracks, 'en', activeId: 1)?.id, 3);
      expect(
        findPreferredAudioTrack(tracks, 'en', activeId: 2)?.id,
        2,
        reason: 'the one already playing is still left alone',
      );
    });

    test('is nothing when all there is in the language is a commentary', () {
      // The film's own Japanese goes on playing: a commentary is not the
      // film in English.
      final tracks = named(<String>[
        'Track 1 - [Japanese]',
        'English Commentary - [English]',
      ]);

      expect(findPreferredAudioTrack(tracks, 'en', activeId: 1), isNull);
    });

    test('is that commentary when it is the one already playing', () {
      final tracks = named(<String>[
        'Track 1 - [Japanese]',
        'English Commentary - [English]',
      ]);

      expect(findPreferredAudioTrack(tracks, 'en', activeId: 2)?.id, 2);
    });

    test('knows a commentary or an audio description however a release '
        'labels it', () {
      for (final (label, language, code) in <(String, String, String)>[
        ('English AD', 'English', 'en'),
        ('English (AD)', 'English', 'en'),
        ('Audio Description', 'English', 'en'),
        ('Descriptive Audio', 'English', 'en'),
        ('Kommentar', 'German', 'de'),
        ('Audiodeskription', 'German', 'de'),
        ('Hörfilm', 'German', 'de'),
        ('Comentario', 'Spanish', 'es'),
        ('Audiodescripción', 'Spanish', 'es'),
        ('Audiodescripcion', 'Spanish', 'es'),
        ('Commentaire', 'French', 'fr'),
        ('Audiodescription', 'French', 'fr'),
        ('Commento', 'Italian', 'it'),
        ('Audiodescrição', 'Portuguese', 'pt'),
        ('Audiodescricao', 'Portuguese', 'pt'),
      ]) {
        final tracks = named(<String>[
          'Track 1 - [Japanese]',
          '$label - [$language]',
        ]);

        expect(
          findPreferredAudioTrack(tracks, code, activeId: 1),
          isNull,
          reason: label,
        );
      }
    });

    test('reads AD only as a word of its own', () {
      final tracks = named(<String>[
        'Track 1 - [Japanese]',
        'Headphone Mix - [English]',
      ]);

      expect(findPreferredAudioTrack(tracks, 'en', activeId: 1)?.id, 2);
    });

    test('is nothing for a language the media lacks, a preference that names '
        'no language, or libVLC\'s Disable', () {
      final tracks = withTrackLanguages(<VlcTrackDescription>[
        const VlcTrackDescription(id: -1, name: 'Disable', language: 'tur'),
        _t(1, name: 'Track 1 - [English]'),
      ], const <VlcMediaTrackInfo>[]);

      expect(findPreferredAudioTrack(tracks, 'tr'), isNull);
      expect(findPreferredAudioTrack(tracks, ''), isNull);
      expect(findPreferredAudioTrack(tracks, 'xx'), isNull);
    });
  });

  group('a recovery of the same file', () {
    test('takes the id back when the language agrees', () {
      final tracks = <VlcTrackDescription>[
        _t(1, language: 'eng'),
        _t(3, language: 'fra'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 3, language: 'fra'),
      );

      expect(match?.id, 3);
    });
  });

  group('among the tracks in the language', () {
    test('the one of the same name goes back on, wherever it is listed', () {
      // The viewer was on the film's English; this copy lists its commentary
      // first, under the number the English had.
      final tracks = <VlcTrackDescription>[
        _t(1, language: 'en', name: 'English Commentary - [English]'),
        _t(2, language: 'en', name: 'English - [English]'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(
          id: 1,
          language: 'en',
          name: 'English - [English]',
        ),
      );

      expect(match?.id, 2);
    });

    test('the one of the same id goes back on when no name agrees', () {
      final tracks = <VlcTrackDescription>[
        _t(1, language: 'hi', name: 'Hindi 2.0 - [Hindi]'),
        _t(2, language: 'hi', name: 'Hindi 5.1 - [Hindi]'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 2, language: 'hi', name: 'Hindi DD 5.1'),
      );

      expect(match?.id, 2);
    });

    test('a commentary under the same id is not the film the viewer was '
        'hearing', () {
      final tracks = <VlcTrackDescription>[
        _t(1, language: 'en', name: 'English Commentary - [English]'),
        _t(2, language: 'en', name: 'English 5.1 - [English]'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(
          id: 1,
          language: 'en',
          name: 'English - [English]',
        ),
      );

      expect(match?.id, 2);
    });

    test('a commentary under the same id is the commentary the viewer was '
        'hearing', () {
      final tracks = <VlcTrackDescription>[
        _t(2, language: 'en', name: 'English - [English]'),
        _t(3, language: 'en', name: 'Commentary - [English]'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(
          id: 3,
          language: 'en',
          name: "Director's Commentary - [English]",
        ),
      );

      expect(match?.id, 3);
    });

    test('the first that is not a commentary goes back on when neither name '
        'nor id agrees', () {
      final tracks = <VlcTrackDescription>[
        _t(3, language: 'en', name: 'Commentary - [English]'),
        _t(4, language: 'en', name: 'English 5.1 - [English]'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(
          id: 1,
          language: 'en',
          name: 'English - [English]',
        ),
      );

      expect(match?.id, 4);
    });

    test('a commentary alone is the language gone from this copy', () {
      final tracks = <VlcTrackDescription>[
        _t(1, language: 'ja', name: 'Track 1 - [Japanese]'),
        _t(2, language: 'en', name: 'English Commentary - [English]'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(
          id: 5,
          language: 'en',
          name: 'English - [English]',
        ),
      );

      expect(match, isNull);
    });
  });

  group('a failover to another provider', () {
    test('follows the language when the ids have been renumbered', () {
      // Same film, another release: the French track is id 7 here.
      final tracks = <VlcTrackDescription>[
        _t(5, language: 'eng'),
        _t(7, language: 'fra'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 3, language: 'fra'),
      );

      expect(match?.id, 7);
    });

    test(
      'a track chosen as Turkish survives a 3-letter to 2-letter tag change',
      () {
        final tracks = <VlcTrackDescription>[
          _t(1, language: 'eng'),
          _t(9, language: 'tr'),
        ];
        final match = matchRememberedTrack(
          tracks,
          const RememberedTrack(id: 7, language: 'tur'),
        );
        expect(match?.id, 9);
      },
    );

    test('follows the language libVLC names to a copy that numbers and '
        'names its tracks differently', () {
      // What the engine actually reports: no language field, the language in
      // the name, and another numbering on the other provider's copy.
      final before = withTrackLanguages(<VlcTrackDescription>[
        _t(1, name: 'Track 1 - [English]'),
        _t(2, name: 'Track 2 - [Hindi]'),
      ], const <VlcMediaTrackInfo>[]);
      final after = withTrackLanguages(<VlcTrackDescription>[
        _t(1, name: 'Hindi - [Hindi]'),
        _t(2, name: 'English - [English]'),
      ], const <VlcMediaTrackInfo>[]);

      expect(matchRememberedTrack(after, RememberedTrack.of(before[0]))?.id, 2);
      expect(matchRememberedTrack(after, RememberedTrack.of(before[1]))?.id, 1);
    });

    test('refuses an id that survived while the language did not', () {
      // The dangerous case, and the reason the id is not a fallback: id 3
      // exists in the new source and is a completely different language.
      final tracks = <VlcTrackDescription>[
        _t(1, language: 'eng'),
        _t(3, language: 'deu'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 3, language: 'fra'),
      );

      expect(
        match,
        isNull,
        reason: 'German is not French, however familiar the number looks',
      );
    });

    test('regional variants of one language still match', () {
      final tracks = <VlcTrackDescription>[_t(9, language: 'pt-BR')];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 2, language: 'pt'),
      );

      expect(match?.id, 9);
    });
  });

  group('sources that declare no language', () {
    test('fall back to the label, which is all a scraped release has', () {
      final tracks = <VlcTrackDescription>[
        _t(1, name: 'AAC 2.0 English'),
        _t(2, name: 'AAC 5.1 Hindi'),
      ];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 8, name: 'AAC 5.1 Hindi'),
      );

      expect(match?.id, 2);
    });

    test('fall back to the id only when there is nothing else to go on', () {
      final tracks = <VlcTrackDescription>[_t(1), _t(4)];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 4),
      );

      expect(match?.id, 4);
    });
  });

  group('nothing to restore', () {
    test('no remembered pick matches nothing', () {
      expect(matchRememberedTrack(<VlcTrackDescription>[_t(1)], null), isNull);
    });

    test('an empty track list matches nothing', () {
      expect(
        matchRememberedTrack(
          const <VlcTrackDescription>[],
          const RememberedTrack(id: 1, language: 'eng'),
        ),
        isNull,
      );
    });

    test('"und" is not a language, so it matches no other unknown', () {
      final tracks = <VlcTrackDescription>[_t(2, language: 'und')];

      final match = matchRememberedTrack(
        tracks,
        const RememberedTrack(id: 9, language: 'und'),
      );

      expect(match, isNull);
    });
  });

  group('snapshotting a pick', () {
    test('keeps every signal the restore will need', () {
      final remembered = RememberedTrack.of(
        _t(3, language: 'fra', name: 'French'),
      );

      expect(remembered?.id, 3);
      expect(remembered?.language, 'fra');
      expect(remembered?.name, 'French');
    });

    test('nothing selected remembers nothing', () {
      expect(RememberedTrack.of(null), isNull);
    });
  });
}
