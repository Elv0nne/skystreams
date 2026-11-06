/// What the viewer's subtitle settings become for libVLC: the options a
/// player is created with, the look it takes while it plays, and the font
/// each platform names.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/subtitle_style.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

void main() {
  group('relativeSizeFor', () {
    test('is libVLC\'s inverted scale, held to 8..60', () {
      expect(relativeSizeFor(22), 24);
      expect(relativeSizeFor(44), 12);
      expect(relativeSizeFor(80), 8, reason: '6.6 is past the largest');
      expect(relativeSizeFor(5), 60, reason: '105.6 is past the smallest');
      expect(relativeSizeFor(0), 24, reason: 'no size is the default size');
    });
  });

  group('subtitleStyleFrom', () {
    test('a fresh install creates the player exactly as it always did', () {
      expect(subtitleStyleFrom(const PlayerSettings()).toOptions(), <String>[
        '--freetype-rel-fontsize=24',
        '--freetype-color=${0xFFFFFF}',
        '--freetype-opacity=255',
        '--freetype-outline-color=0',
        '--freetype-outline-opacity=255',
        '--freetype-outline-thickness=2',
        '--freetype-background-color=0',
        '--freetype-background-opacity=128',
      ]);
    });

    test('takes bold, the font, the text opacity and the encoding', () {
      final List<String> options = subtitleStyleFrom(
        const PlayerSettings(
          subtitleBold: true,
          subtitleFont: SubtitleFont.serif,
          subtitleTextOpacity: 0.5,
          subtitleEncoding: 'Windows-1251',
        ),
      ).toOptions();

      expect(
        options,
        containsAll(<String>[
          '--freetype-bold',
          '--freetype-font=${subtitleFontFamily(SubtitleFont.serif)}',
          '--freetype-opacity=128',
          '--subsdec-encoding=Windows-1251',
        ]),
      );
    });

    test('outlines at libVLC\'s own presets', () {
      int? thickness(SubtitleOutline outline) =>
          subtitleStyleFrom(PlayerSettings(subtitleOutline: outline))
              .outlineThickness;

      expect(thickness(SubtitleOutline.none), 0);
      expect(thickness(SubtitleOutline.thin), 2);
      expect(thickness(SubtitleOutline.normal), 4);
      expect(thickness(SubtitleOutline.thick), 6);
    });

    test('the text opacity replaces the stored colour\'s own alpha', () {
      final Color? colour = subtitleStyleFrom(
        const PlayerSettings(
          subtitleColor: 0x80FFEB3B,
          subtitleTextOpacity: 0.75,
        ),
      ).color;
      expect(colour?.toARGB32(), 0xBFFFEB3B);
    });
  });

  group('subtitleLookFrom', () {
    test('scales against the size the player was created with', () {
      // Created at 22, which is libVLC's 24; 44 is its 12: twice the size.
      expect(
        subtitleLookFrom(
          const PlayerSettings(subtitleSize: 44),
          createdRelativeSize: 24,
        ).textScale,
        200,
      );
      // Created at 44, its 12; 22 is half the size.
      expect(
        subtitleLookFrom(
          const PlayerSettings(subtitleSize: 22),
          createdRelativeSize: 12,
        ).textScale,
        50,
      );
      expect(
        subtitleLookFrom(
          const PlayerSettings(),
          createdRelativeSize: 24,
        ).textScale,
        100,
      );
    });

    test('the scale moves with every size step', () {
      // Created at 22, the default, the scale stays inside libVLC's 10..500
      // all the way from 10 to 80, so each step has to say something new.
      int scaleAt(int size) => subtitleLookFrom(
        PlayerSettings(subtitleSize: size.toDouble()),
        createdRelativeSize: 24,
      ).textScale;
      for (var size = 11; size <= 80; size++) {
        expect(scaleAt(size), greaterThan(scaleAt(size - 1)), reason: '$size');
      }
    });

    test('holds the scale to the 10..500 libVLC takes', () {
      // Created at the smallest size and asked for the largest: 750 %.
      expect(
        subtitleLookFrom(
          const PlayerSettings(subtitleSize: 80),
          createdRelativeSize: 60,
        ).textScale,
        500,
      );
      expect(
        subtitleLookFrom(
          const PlayerSettings(subtitleSize: 10),
          createdRelativeSize: 4,
        ).textScale,
        10,
      );
    });

    test('carries the colours, the box, the outline and the lift', () {
      final look = subtitleLookFrom(
        const PlayerSettings(
          subtitleColor: 0xFFFFEB3B,
          subtitleBackgroundColor: 0xFF303030,
          subtitleBackgroundOpacity: 0.8,
          subtitleOutline: SubtitleOutline.normal,
          subtitleRaise: 0.1,
        ),
        createdRelativeSize: 24,
      );

      expect(look.color, const Color(0xFFFFEB3B));
      expect(look.backgroundColor, const Color(0xFF303030));
      expect(look.backgroundOpacity, 204);
      expect(look.outlineThickness, 4);
      expect(look.raise, 0.1);
    });

    test('a box at zero opacity is no box, whatever its colour', () {
      expect(
        subtitleLookFrom(
          const PlayerSettings(
            subtitleBackgroundColor: 0xFFFFFFFF,
            subtitleBackgroundOpacity: 0,
          ),
          createdRelativeSize: 24,
        ).backgroundOpacity,
        0,
      );
    });

    test('leaves out what is fixed when the player is created', () {
      // libVLC keeps the text's opacity from creation, so a look that moved
      // with it would only ever be sent for nothing.
      const PlayerSettings plain = PlayerSettings();
      expect(
        subtitleLookFrom(
          plain.copyWith(
            subtitleTextOpacity: 0.5,
            subtitleBold: true,
            subtitleFont: SubtitleFont.monospace,
            subtitleEncoding: 'Windows-1251',
            subtitleColor: 0x80FFFFFF,
          ),
          createdRelativeSize: 24,
        ),
        subtitleLookFrom(plain, createdRelativeSize: 24),
      );
      // The stored background is transparent black: the look's is opaque,
      // its opacity a number of its own.
      expect(
        subtitleLookFrom(plain, createdRelativeSize: 24).backgroundColor,
        const Color(0xFF000000),
      );
    });
  });

  group('subtitleFontFamily', () {
    test('names a family each platform has, and none for the default', () {
      const families = <TargetPlatform, (String, String)>{
        TargetPlatform.android: ('serif', 'monospace'),
        TargetPlatform.iOS: ('Times New Roman', 'Menlo'),
        TargetPlatform.macOS: ('Times New Roman', 'Menlo'),
        TargetPlatform.windows: ('Times New Roman', 'Consolas'),
        TargetPlatform.linux: ('serif', 'monospace'),
      };
      for (final MapEntry(key: platform, value: (serif, monospace))
          in families.entries) {
        expect(
          subtitleFontFamily(SubtitleFont.serif, platform: platform),
          serif,
          reason: '$platform',
        );
        expect(
          subtitleFontFamily(SubtitleFont.monospace, platform: platform),
          monospace,
          reason: '$platform',
        );
        expect(
          subtitleFontFamily(SubtitleFont.standard, platform: platform),
          isNull,
          reason: '$platform',
        );
      }
    });

    test('reads the platform the app runs on', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        expect(subtitleFontFamily(SubtitleFont.monospace), 'Consolas');
        expect(
          subtitleStyleFrom(
            const PlayerSettings(subtitleFont: SubtitleFont.monospace),
          ).fontFamily,
          'Consolas',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
