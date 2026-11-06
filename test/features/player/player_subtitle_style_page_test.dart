/// The panel's Subtitle style page, and the stepper row it is built from.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_metrics.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_shell.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_subtitle_style_page.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'vlc_screen_harness.dart';

void main() {
  group('PanelStepperRow', () {
    /// One stepper alone, as wide as the panel is in a window [window] big.
    Future<void> pumpStepper(
      WidgetTester tester, {
      required Size window,
      required String value,
      String label = 'Encoding',
      VoidCallback? onReset,
      String? resetTooltip,
      void Function(PanelStep step)? onDecrease,
      void Function(PanelStep step)? onIncrease,
      String? increasedValue,
      String? decreasedValue,
    }) async {
      tester.view.physicalSize = window;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const metrics = PlayerPanelMetrics.touch;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerPanelMetricsScope(
              metrics: metrics,
              child: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: playerPanelWidthFor(window, metrics, edgeInset: 0),
                  child: PanelStepperRow(
                    label: label,
                    value: value,
                    onDecrease: onDecrease ?? (_) {},
                    onIncrease: onIncrease ?? (_) {},
                    onReset: onReset,
                    resetTooltip: resetTooltip,
                    increasedValue: increasedValue,
                    decreasedValue: decreasedValue,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    void expectInsideRow(WidgetTester tester, String value) {
      final row = tester.getRect(find.byType(PanelStepperRow));
      final text = tester.getRect(find.text(value));
      expect(text.left, greaterThanOrEqualTo(row.left));
      expect(text.right, lessThanOrEqualTo(row.right));
      expect(text.top, greaterThanOrEqualTo(row.top));
      expect(text.bottom, lessThanOrEqualTo(row.bottom));
    }

    testWidgets('a long value is not clipped on a phone: the label gives way', (
      tester,
    ) async {
      // A phone held the way video plays, with the reset button showing.
      await pumpStepper(
        tester,
        window: const Size(844, 390),
        value: 'Central European',
        onReset: () {},
      );

      expect(tester.takeException(), isNull);
      final value = tester.renderObject<RenderParagraph>(
        find.text('Central European'),
      );
      expect(
        value.size.width,
        greaterThanOrEqualTo(value.getMaxIntrinsicWidth(double.infinity)),
        reason: 'all of it, on one line',
      );
      expect(value.didExceedMaxLines, isFalse);
      expectInsideRow(tester, 'Central European');
      expect(
        tester.renderObject<RenderParagraph>(find.text('Encoding')).size.width,
        lessThan(
          tester
              .renderObject<RenderParagraph>(find.text('Encoding'))
              .getMaxIntrinsicWidth(double.infinity),
        ),
        reason: 'the label is what gets shortened',
      );
    });

    testWidgets('on a narrower phone the long value wraps between its words '
        'rather than being cut', (tester) async {
      await pumpStepper(
        tester,
        window: const Size(390, 844),
        value: 'Central European',
        onReset: () {},
      );

      expect(tester.takeException(), isNull);
      final value = tester.renderObject<RenderParagraph>(
        find.text('Central European'),
      );
      expect(value.didExceedMaxLines, isFalse, reason: 'nothing ellipsized');
      expectInsideRow(tester, 'Central European');
      // The lines a stretch of the value is drawn on.
      Set<double> lines(int start, int end) => value
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: end),
          )
          .map((box) => box.top)
          .toSet();
      expect(lines(0, 16), hasLength(2), reason: 'a word to a line');
      expect(lines(0, 7), hasLength(1), reason: '"Central" whole');
      expect(lines(8, 16), hasLength(1), reason: '"European" whole');
    });

    testWidgets('a short value keeps the delay\'s column', (tester) async {
      await pumpStepper(tester, window: const Size(844, 390), value: '+0ms');

      expect(
        tester.getSize(find.text('+0ms')).width,
        PlayerPanelMetrics.touch.stepperValueWidth,
      );
    });

    testWidgets('a screen reader hears the row once, can step it, and is told '
        'what -/+ do', (tester) async {
      final semantics = tester.ensureSemantics();
      final steps = <String>[];
      await pumpStepper(
        tester,
        window: const Size(844, 390),
        label: 'Outline',
        value: 'Normal',
        increasedValue: 'Thick',
        decreasedValue: 'Thin',
        onReset: () {},
        onDecrease: (step) => steps.add('down ${step.name}'),
        onIncrease: (step) => steps.add('up ${step.name}'),
      );
      final row = tester.getSemantics(find.byType(PanelStepperRow));
      expect(row.label, 'Outline', reason: 'not "Outline Outline Normal"');
      expect(row.value, 'Normal');
      expect(row.increasedValue, 'Thick');
      expect(row.decreasedValue, 'Thin');
      tester.semantics.increase(find.semantics.byLabel('Outline'));
      tester.semantics.decrease(find.semantics.byLabel('Outline'));
      expect(steps, <String>['up fine', 'down fine']);

      final decrease = find.semantics.byLabel('Decrease');
      final increase = find.semantics.byLabel('Increase');
      expect(decrease.evaluate().single.flagsCollection.isButton, isTrue);
      expect(increase.evaluate().single.flagsCollection.isButton, isTrue);
      tester.semantics.tap(increase);
      tester.semantics.tap(decrease);
      expect(steps, <String>['up fine', 'down fine', 'up fine', 'down fine']);
      semantics.dispose();
    });

    testWidgets('at an end a screen reader is offered no step past it', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpStepper(
        tester,
        window: const Size(844, 390),
        label: 'Outline',
        value: 'Thick',
        decreasedValue: 'Normal',
      );

      final row = tester.getSemantics(find.byType(PanelStepperRow));
      expect(
        row.getSemanticsData().hasAction(SemanticsAction.decrease),
        isTrue,
      );
      expect(
        row.getSemanticsData().hasAction(SemanticsAction.increase),
        isFalse,
      );
      semantics.dispose();
    });

    testWidgets('the reset button says what it resets', (tester) async {
      await pumpStepper(
        tester,
        window: const Size(844, 390),
        value: 'Thick',
        onReset: () {},
        resetTooltip: 'Reset to Default',
      );
      expect(find.byTooltip('Reset to Default'), findsOneWidget);

      await pumpStepper(
        tester,
        window: const Size(844, 390),
        value: '+100ms',
        onReset: () {},
      );
      expect(find.byTooltip('Reset Delay'), findsOneWidget);
    });
  });

  group('SubtitleStylePage', () {
    late AppLocalizations l10n;
    late MemorySettings store;

    setUpAll(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    /// The page alone, as wide as a television's panel and tall enough for
    /// every row, over the real notifier with [start] in it.
    Future<void> pumpPage(
      WidgetTester tester, {
      PlayerSettings start = const PlayerSettings(),
      bool isTv = true,
    }) async {
      store = MemorySettings();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(store),
          playerSettingsProvider.overrideWithBuild((_, _) => start),
        ],
      );
      addTearDown(container.dispose);
      final style = subtitleStyleBindingFor(container);
      tester.view.physicalSize = const Size(1280, 1440);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerPanelMetricsScope(
              metrics: PlayerPanelMetrics.forTv(isTv),
              child: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: 460,
                  child: SubtitleStylePage(style: style),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String? focusedRow() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PanelStepperRow>()
        ?.label;

    Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    /// Presses DOWN until the row called [label] holds focus.
    Future<void> focusRow(WidgetTester tester, String label) async {
      for (var i = 0; i < 12 && focusedRow() != label; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedRow(), label);
    }

    Finder row(String text) => find.widgetWithText(PanelStepperRow, text);

    test('every word on the page is in Hindi and Kannada too', () async {
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      final hi = await AppLocalizations.delegate.load(const Locale('hi'));
      final kn = await AppLocalizations.delegate.load(const Locale('kn'));
      // Not the read-outs made of numbers alone: "22 · White" and "+10%".
      final words = <String, String Function(AppLocalizations l10n)>{
        'subtitleStyle': (l10n) => l10n.subtitleStyle,
        'textSize': (l10n) => l10n.textSize,
        'subtitleTextColour': (l10n) => l10n.subtitleTextColour,
        'colorWhite': (l10n) => l10n.colorWhite,
        'colorYellow': (l10n) => l10n.colorYellow,
        'colorCyan': (l10n) => l10n.colorCyan,
        'colorGreen': (l10n) => l10n.colorGreen,
        'colorMagenta': (l10n) => l10n.colorMagenta,
        'colorRed': (l10n) => l10n.colorRed,
        'colorBlack': (l10n) => l10n.colorBlack,
        'colorDarkGrey': (l10n) => l10n.colorDarkGrey,
        'background': (l10n) => l10n.background,
        'off': (l10n) => l10n.off,
        'on': (l10n) => l10n.on,
        'subtitleBackgroundOpacity': (l10n) => l10n.subtitleBackgroundOpacity,
        'subtitleOutline': (l10n) => l10n.subtitleOutline,
        'subtitleOutlineNone': (l10n) => l10n.subtitleOutlineNone,
        'subtitleOutlineThin': (l10n) => l10n.subtitleOutlineThin,
        'subtitleOutlineNormal': (l10n) => l10n.subtitleOutlineNormal,
        'subtitleOutlineThick': (l10n) => l10n.subtitleOutlineThick,
        'subtitlePosition': (l10n) => l10n.subtitlePosition,
        'subtitlePositionBottom': (l10n) => l10n.subtitlePositionBottom,
        'subtitleNextTime': (l10n) => l10n.subtitleNextTime,
        'subtitleNextTimeNote': (l10n) => l10n.subtitleNextTimeNote,
        'subtitleBold': (l10n) => l10n.subtitleBold,
        'subtitleFont': (l10n) => l10n.subtitleFont,
        'subtitleFontDefault': (l10n) => l10n.subtitleFontDefault,
        'subtitleFontSerif': (l10n) => l10n.subtitleFontSerif,
        'subtitleFontMonospace': (l10n) => l10n.subtitleFontMonospace,
        'subtitleTextOpacity': (l10n) => l10n.subtitleTextOpacity,
        'subtitleEncoding': (l10n) => l10n.subtitleEncoding,
        'subtitleEncodingAuto': (l10n) => l10n.subtitleEncodingAuto,
        'subtitleEncodingCentralEuropean': (l10n) =>
            l10n.subtitleEncodingCentralEuropean,
        'subtitleEncodingCyrillic': (l10n) => l10n.subtitleEncodingCyrillic,
        'subtitleEncodingWestern': (l10n) => l10n.subtitleEncodingWestern,
        'subtitleEncodingGreek': (l10n) => l10n.subtitleEncodingGreek,
        'subtitleEncodingTurkish': (l10n) => l10n.subtitleEncodingTurkish,
        'subtitleEncodingHebrew': (l10n) => l10n.subtitleEncodingHebrew,
        'subtitleEncodingArabic': (l10n) => l10n.subtitleEncodingArabic,
        'subtitleEncodingBaltic': (l10n) => l10n.subtitleEncodingBaltic,
        'subtitleEncodingVietnamese': (l10n) => l10n.subtitleEncodingVietnamese,
        'resetSubtitleStyle': (l10n) => l10n.resetSubtitleStyle,
        'resetToDefault': (l10n) => l10n.resetToDefault,
      };
      for (final MapEntry(key: name, value: word) in words.entries) {
        expect(word(hi), isNot(word(en)), reason: '$name in Hindi');
        expect(word(kn), isNot(word(en)), reason: '$name in Kannada');
      }
    });

    testWidgets('tells a screen reader what each step would make it', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpPage(tester);
      SemanticsNode node(String label) => tester.getSemantics(row(label));

      expect(node(l10n.textSize).increasedValue, '23');
      expect(node(l10n.textSize).decreasedValue, '21');
      // Colours go round: White is first, so one step down is the last.
      expect(node(l10n.subtitleTextColour).increasedValue, l10n.colorYellow);
      expect(node(l10n.subtitleTextColour).decreasedValue, l10n.colorBlack);
      expect(node(l10n.subtitleBackgroundOpacity).increasedValue, '60%');
      expect(
        node(l10n.subtitleOutline).increasedValue,
        l10n.subtitleOutlineNormal,
      );
      expect(
        node(l10n.subtitleOutline).decreasedValue,
        l10n.subtitleOutlineNone,
      );
      // A scale stops at its ends: the bottom has nowhere lower to go.
      expect(node(l10n.subtitlePosition).increasedValue, '+5%');
      expect(
        node(l10n.subtitlePosition)
            .getSemanticsData()
            .hasAction(SemanticsAction.decrease),
        isFalse,
      );
      semantics.dispose();
    });

    testWidgets('opens with focus on its first row', (tester) async {
      await pumpPage(tester);

      expect(focusedRow(), l10n.textSize);
    });

    testWidgets('Left and Right step a value and save it, a held key '
        'further', (tester) async {
      await pumpPage(tester);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(store.stored['player_sub_size'], 23.0);
      expect(row('23'), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(store.stored['player_sub_size'], 18.0, reason: '23, 22, then 4');
      expect(focusedRow(), l10n.textSize, reason: 'Left/Right never move on');
    });

    testWidgets('Select puts the row it is on back to its default', (
      tester,
    ) async {
      await pumpPage(tester, start: const PlayerSettings(subtitleSize: 40));
      expect(row('40'), findsOneWidget);

      await press(tester, LogicalKeyboardKey.select);
      expect(store.stored['player_sub_size'], 22.0);
      expect(row('22'), findsOneWidget);
    });

    testWidgets('a scale stops at its ends, and a list of colours goes '
        'round', (tester) async {
      await pumpPage(tester);

      await focusRow(tester, l10n.subtitleTextColour);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(
        store.stored['player_sub_color'],
        0xFF000000,
        reason:
            'White to '
            'the last colour',
      );

      await focusRow(tester, l10n.subtitleOutline);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(store.stored['player_sub_outline'], 'none');
      store.stored.remove('player_sub_outline');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(store.stored, isNot(contains('player_sub_outline')));

      await focusRow(tester, l10n.subtitlePosition);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(store.stored['player_sub_raise'], 0.05);
      expect(row('+5%'), findsOneWidget);
    });

    testWidgets('the box off takes its opacity away, and a colour puts it '
        'back at half', (tester) async {
      await pumpPage(
        tester,
        start: const PlayerSettings(subtitleBackgroundOpacity: 0.8),
      );
      expect(row(l10n.subtitleBackgroundOpacity), findsOneWidget);
      expect(row('80%'), findsOneWidget);

      await focusRow(tester, l10n.background);
      expect(row(l10n.colorBlack), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(store.stored['player_sub_bg_opacity'], 0.0);
      expect(
        find.descendant(of: row(l10n.background), matching: find.text('Off')),
        findsOneWidget,
      );
      expect(row(l10n.subtitleBackgroundOpacity), findsNothing);

      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(store.stored['player_sub_bg'], 0xFF000000);
      expect(store.stored['player_sub_bg_opacity'], 0.5);
      expect(row('50%'), findsOneWidget);

      await focusRow(tester, l10n.subtitleBackgroundOpacity);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(store.stored['player_sub_bg_opacity'], 0.6);
    });

    testWidgets('says which settings wait for the player to open again', (
      tester,
    ) async {
      await pumpPage(tester);

      final heading = find.text(l10n.subtitleNextTime.toUpperCase());
      expect(heading, findsOneWidget);
      expect(find.text(l10n.subtitleNextTimeNote), findsOneWidget);
      double top(Finder finder) => tester.getTopLeft(finder).dy;
      for (final live in <String>[
        l10n.textSize,
        l10n.subtitleTextColour,
        l10n.background,
        l10n.subtitleBackgroundOpacity,
        l10n.subtitleOutline,
        l10n.subtitlePosition,
      ]) {
        expect(top(row(live)), lessThan(top(heading)), reason: live);
      }
      for (final tagged in <String>[
        l10n.subtitleBold,
        l10n.subtitleFont,
        l10n.subtitleTextOpacity,
        l10n.subtitleEncoding,
      ]) {
        expect(top(row(tagged)), greaterThan(top(heading)), reason: tagged);
      }
    });

    testWidgets('steps the tagged settings too, and names each code page', (
      tester,
    ) async {
      await pumpPage(tester);

      await focusRow(tester, l10n.subtitleBold);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(store.stored['player_sub_bold'], isTrue);

      await focusRow(tester, l10n.subtitleFont);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(store.stored['player_sub_font'], 'serif');

      await focusRow(tester, l10n.subtitleTextOpacity);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(store.stored['player_sub_text_opacity'], 0.75);

      await focusRow(tester, l10n.subtitleEncoding);
      expect(row(l10n.subtitleEncodingAuto), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(store.stored['player_sub_encoding'], 'Windows-1250');
      expect(row(l10n.subtitleEncodingCentralEuropean), findsOneWidget);
      await press(tester, LogicalKeyboardKey.select);
      expect(store.stored['player_sub_encoding'], '');
    });

    testWidgets('Reset subtitle style puts every setting back', (tester) async {
      await pumpPage(
        tester,
        start: const PlayerSettings(
          subtitleSize: 40,
          subtitleOutline: SubtitleOutline.thick,
          subtitleEncoding: 'Windows-1251',
        ),
      );

      await tester.tap(find.widgetWithText(PanelRow, l10n.resetSubtitleStyle));
      await tester.pumpAndSettle();
      expect(store.stored['player_sub_size'], 22.0);
      expect(store.stored['player_sub_outline'], 'thin');
      expect(store.stored['player_sub_encoding'], '');
      expect(row('22'), findsOneWidget);
    });

    testWidgets('Reset with the box off keeps focus on Reset as the opacity '
        'row comes back above it', (tester) async {
      await pumpPage(
        tester,
        start: const PlayerSettings(subtitleBackgroundOpacity: 0),
      );
      String? focusedLabel() {
        final context = FocusManager.instance.primaryFocus?.context;
        return context
                ?.findAncestorWidgetOfExactType<PanelStepperRow>()
                ?.label ??
            context?.findAncestorWidgetOfExactType<PanelRow>()?.label;
      }

      for (
        var i = 0;
        i < 14 && focusedLabel() != l10n.resetSubtitleStyle;
        i++
      ) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedLabel(), l10n.resetSubtitleStyle);
      expect(row(l10n.subtitleBackgroundOpacity), findsNothing);

      await press(tester, LogicalKeyboardKey.select);

      expect(row(l10n.subtitleBackgroundOpacity), findsOneWidget);
      expect(focusedLabel(), l10n.resetSubtitleStyle, reason: 'still on Reset');
    });

    testWidgets('under a thumb, -/+ step and the row\'s button resets', (
      tester,
    ) async {
      await pumpPage(
        tester,
        isTv: false,
        start: const PlayerSettings(subtitleRaise: 0.1),
      );

      final position = row(l10n.subtitlePosition);
      await tester.tap(
        find.descendant(of: position, matching: find.byIcon(Icons.add_rounded)),
      );
      await tester.pumpAndSettle();
      expect(store.stored['player_sub_raise'], 0.15);

      await tester.tap(
        find.descendant(
          of: position,
          matching: find.byTooltip(l10n.resetToDefault),
        ),
      );
      await tester.pumpAndSettle();
      expect(store.stored['player_sub_raise'], 0.0);
      expect(row(l10n.subtitlePositionBottom), findsOneWidget);
    });
  });
}
