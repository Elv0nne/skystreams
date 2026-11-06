import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/features/player/domain/subtitle_style.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:skystream/features/settings/presentation/widgets/subtitle_appearance_settings.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../player/vlc_screen_harness.dart' show MemorySettings;

void main() {
  group('labels', () {
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('names an offered colour and falls back to hex for anything else', () {
      expect(subtitleColorLabel(l10n, 0xFFFFFFFF), 'White');
      expect(subtitleColorLabel(l10n, 0xFFFFEB3B), 'Yellow');
      expect(subtitleColorLabel(l10n, 0xFFFF8800), '#FF8800');
    });

    test('calls a zero-opacity background Off, whatever colour is stored', () {
      expect(
        subtitleBackgroundLabel(
          l10n,
          const PlayerSettings(
            subtitleBackgroundColor: 0xFF000000,
            subtitleBackgroundOpacity: 0,
          ),
        ),
        'Off',
      );
      expect(
        subtitleBackgroundLabel(
          l10n,
          const PlayerSettings(
            subtitleBackgroundColor: 0xFF000000,
            subtitleBackgroundOpacity: 0.75,
          ),
        ),
        'Black · 75%',
      );
    });

    test('names the box a fresh install draws, whose stored alpha is 0', () {
      expect(
        subtitleBackgroundLabel(l10n, const PlayerSettings()),
        'Black · 50%',
      );
    });

    test('the frame is the short edge, because playback is landscape', () {
      expect(subtitleFrameHeight(const Size(400, 900)), 400);
      expect(subtitleFrameHeight(const Size(1920, 1080)), 1080);
    });
  });

  group('SubtitlePreview', () {
    Future<void> pumpPreview(
      WidgetTester tester,
      PlayerSettings settings, {
      Size window = const Size(1920, 1080),
    }) {
      return tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: window),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Center(
              child: SubtitlePreview(
                settings: settings,
                sample: 'The quick brown fox',
              ),
            ),
          ),
        ),
      );
    }

    /// The fill layer is the last sample drawn; the one before it is the
    /// outline stroke.
    TextStyle fillStyle(WidgetTester tester) {
      final texts = tester
          .widgetList<Text>(find.text('The quick brown fox'))
          .toList();
      return texts.last.style!;
    }

    testWidgets('sizes the sample exactly as libVLC will', (tester) async {
      const settings = PlayerSettings(subtitleSize: 22);
      await pumpPreview(tester, settings);

      // Rendered height is video height / relative size — the engine's own
      // rule, read back off the same mapping the engine is handed.
      final relative = subtitleStyleFrom(settings).relativeFontSize!;
      expect(fillStyle(tester).fontSize, 1080 / relative);
    });

    testWidgets('every size step from 10 to 80 draws a different size', (
      tester,
    ) async {
      final drawn = <double>[];
      for (var size = 10; size <= 80; size++) {
        await pumpPreview(
          tester,
          PlayerSettings(subtitleSize: size.toDouble()),
        );
        drawn.add(fillStyle(tester).fontSize!);
      }
      for (var i = 1; i < drawn.length; i++) {
        expect(drawn[i], greaterThan(drawn[i - 1]), reason: 'size ${10 + i}');
      }
    });

    testWidgets('a bigger setting really is bigger', (tester) async {
      await pumpPreview(tester, const PlayerSettings(subtitleSize: 22));
      final small = fillStyle(tester).fontSize!;

      await pumpPreview(tester, const PlayerSettings(subtitleSize: 44));
      expect(fillStyle(tester).fontSize, greaterThan(small));
    });

    testWidgets('uses the chosen text colour', (tester) async {
      await pumpPreview(
        tester,
        const PlayerSettings(subtitleColor: 0xFFFFEB3B),
      );
      expect(fillStyle(tester).color, const Color(0xFFFFEB3B));
    });

    testWidgets('draws no box at zero opacity, and one above it', (
      tester,
    ) async {
      Color? boxColour() {
        // Closest Container above the two text layers: the box itself.
        final box = tester
            .widgetList<Container>(
              find.ancestor(
                of: find.byType(Stack),
                matching: find.byType(Container),
              ),
            )
            .first;
        return box.color;
      }

      await pumpPreview(
        tester,
        const PlayerSettings(subtitleBackgroundOpacity: 0),
      );
      expect(boxColour(), isNull);

      await pumpPreview(
        tester,
        const PlayerSettings(
          subtitleBackgroundColor: 0xFF000000,
          subtitleBackgroundOpacity: 0.5,
        ),
      );
      expect(boxColour(), isNotNull);
    });

    testWidgets('outlines the sample as heavily as the player will', (
      tester,
    ) async {
      TextStyle? stroke() {
        final copies = tester
            .widgetList<Text>(find.text('The quick brown fox'))
            .toList();
        return copies.length < 2 ? null : copies.first.style;
      }

      const widths = <SubtitleOutline, double>{
        SubtitleOutline.thin: 2,
        SubtitleOutline.normal: 3.5,
        SubtitleOutline.thick: 5,
      };
      for (final MapEntry(key: outline, value: width) in widths.entries) {
        await pumpPreview(tester, PlayerSettings(subtitleOutline: outline));
        expect(stroke()?.foreground?.strokeWidth, width, reason: '$outline');
      }

      await pumpPreview(
        tester,
        const PlayerSettings(subtitleOutline: SubtitleOutline.none),
      );
      expect(stroke(), isNull);
    });

    testWidgets('draws the sample bold, in the font and at the opacity '
        'chosen', (tester) async {
      await pumpPreview(
        tester,
        const PlayerSettings(
          subtitleBold: true,
          subtitleFont: SubtitleFont.serif,
          subtitleTextOpacity: 0.25,
        ),
      );

      final style = fillStyle(tester);
      expect(style.fontWeight, FontWeight.w800);
      expect(style.fontFamily, subtitleFontFamily(SubtitleFont.serif));
      expect(style.color?.toARGB32(), 0x40FFFFFF);
    });

    testWidgets('lifts the sample by the share of its frame asked for', (
      tester,
    ) async {
      double bottom() =>
          tester.getBottomLeft(find.text('The quick brown fox').last).dy;

      await pumpPreview(tester, const PlayerSettings());
      final low = bottom();
      final frame = tester.getSize(find.byType(SubtitlePreview)).height;

      await pumpPreview(tester, const PlayerSettings(subtitleRaise: 0.2));
      expect(bottom(), closeTo(low - 0.2 * frame, 0.01));
    });
  });

  group('SubtitleAppearanceGroup', () {
    late MemorySettings store;
    late AppLocalizations l10n;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    Future<void> pumpGroup(WidgetTester tester, PlayerSettings settings) {
      store = MemorySettings();
      return tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(store),
            playerSettingsProvider.overrideWithBuild((_, _) => settings),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: ListView(
                children: [
                  const Focus(autofocus: true, child: SizedBox(height: 24)),
                  SubtitleAppearanceGroup(settings: settings),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('shows every editable field with its current value', (
      tester,
    ) async {
      await pumpGroup(
        tester,
        const PlayerSettings(
          subtitleSize: 30,
          subtitleColor: 0xFFFFEB3B,
          subtitleBackgroundColor: 0xFF000000,
          subtitleBackgroundOpacity: 0.5,
        ),
      );

      expect(find.text('Text size'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      expect(find.text('Text colour'), findsOneWidget);
      expect(find.text('Yellow'), findsOneWidget);
      expect(find.text('Background'), findsOneWidget);
      expect(find.text('Black · 50%'), findsOneWidget);
    });

    testWidgets('DOWN walks the rows, so the preview is not a dead end', (
      tester,
    ) async {
      await pumpGroup(tester, const PlayerSettings());
      await tester.pump();

      final visited = <String?>[];
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        visited.add(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<SettingsTile>()
              ?.title,
        );
      }

      expect(visited, <String>[
        'Text size',
        'Text colour',
        'Background',
        'Outline',
        'Position',
        'Bold',
        'Font',
        'Text opacity',
        'Encoding',
        'Reset subtitle appearance',
      ]);
    });

    testWidgets('shows the outline, the lift, bold, the font, the text '
        'opacity and the encoding', (tester) async {
      await pumpGroup(
        tester,
        const PlayerSettings(
          subtitleOutline: SubtitleOutline.thick,
          subtitleRaise: 0.1,
          subtitleBold: true,
          subtitleFont: SubtitleFont.serif,
          subtitleTextOpacity: 0.75,
          subtitleEncoding: 'Windows-1251',
        ),
      );

      Finder tile(String title, String value) => find.descendant(
        of: find.widgetWithText(SettingsTile, title),
        matching: find.text(value),
      );
      expect(tile(l10n.subtitleOutline, l10n.subtitleOutlineThick), findsOne);
      expect(tile(l10n.subtitlePosition, '+10%'), findsOneWidget);
      expect(tile(l10n.subtitleBold, l10n.on), findsOneWidget);
      expect(tile(l10n.subtitleFont, l10n.subtitleFontSerif), findsOneWidget);
      expect(tile(l10n.subtitleTextOpacity, '75%'), findsOneWidget);
      expect(
        tile(l10n.subtitleEncoding, l10n.subtitleEncodingCyrillic),
        findsOneWidget,
      );
    });

    testWidgets('says over the four that wait that they wait', (tester) async {
      await pumpGroup(tester, const PlayerSettings());

      final note = find.text(l10n.subtitleNextTimeNote);
      expect(note, findsOneWidget);
      double top(Finder finder) => tester.getTopLeft(finder).dy;
      expect(top(find.text(l10n.subtitlePosition)), lessThan(top(note)));
      for (final waits in <String>[
        l10n.subtitleBold,
        l10n.subtitleFont,
        l10n.subtitleTextOpacity,
        l10n.subtitleEncoding,
      ]) {
        expect(top(find.text(waits)), greaterThan(top(note)), reason: waits);
      }
    });

    testWidgets('each new row opens a list that saves the choice and closes', (
      tester,
    ) async {
      await pumpGroup(tester, const PlayerSettings());

      Future<void> choose(String row, String choice) async {
        await tester.ensureVisible(find.widgetWithText(SettingsTile, row));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(SettingsTile, row));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget, reason: row);
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text(choice),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing, reason: row);
      }

      await choose(l10n.subtitleOutline, l10n.subtitleOutlineThick);
      expect(store.stored['player_sub_outline'], 'thick');
      await choose(l10n.subtitlePosition, '+15%');
      expect(store.stored['player_sub_raise'], 0.15);
      await choose(l10n.subtitleBold, l10n.on);
      expect(store.stored['player_sub_bold'], isTrue);
      await choose(l10n.subtitleFont, l10n.subtitleFontMonospace);
      expect(store.stored['player_sub_font'], 'monospace');
      await choose(l10n.subtitleTextOpacity, '50%');
      expect(store.stored['player_sub_text_opacity'], 0.5);
      await choose(l10n.subtitleEncoding, l10n.subtitleEncodingGreek);
      expect(store.stored['player_sub_encoding'], 'Windows-1253');
    });

    testWidgets('a list longer than its dialog opens with the choice in '
        'force on screen', (tester) async {
      // A 1080p television, as Android TV lays it out.
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpGroup(
        tester,
        const PlayerSettings(subtitleEncoding: 'Windows-1258'),
      );
      final tile = find.widgetWithText(SettingsTile, l10n.subtitleEncoding);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pumpAndSettle();

      final list = tester.getRect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Scrollable),
        ),
      );
      final current = tester.getRect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(
            ListTile,
            l10n.subtitleEncodingVietnamese,
          ),
        ),
      );
      expect(current.top, greaterThanOrEqualTo(list.top));
      expect(current.bottom, lessThanOrEqualTo(list.bottom));
    });

    testWidgets('a list opens on the choice in force, for a remote', (
      tester,
    ) async {
      await pumpGroup(
        tester,
        const PlayerSettings(subtitleEncoding: 'Windows-1256'),
      );

      await tester.ensureVisible(
        find.widgetWithText(SettingsTile, l10n.subtitleEncoding),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(SettingsTile, l10n.subtitleEncoding),
      );
      await tester.pumpAndSettle();

      final focused = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<ListTile>();
      expect((focused?.title as Text?)?.data, l10n.subtitleEncodingArabic);
    });
  });
}
