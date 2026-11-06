/// The viewer's subtitle settings on a running player, driven through the real
/// screen over the real engine fake.
///
/// libVLC's lines inside the video are restyled while the video plays: the
/// screen hands the controller a look as the player is created, and a new one
/// whenever a setting the look carries changes - never for a change it does
/// not carry. Subtitle files are read in the encoding the settings name when
/// they are read.
///
/// Harness rules apply - `settle`, never `pumpAndSettle`, and every test
/// unmounts in-body so no watchdog timer outlives it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_row.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_subtitle_style_page.dart';
import 'package:skystream/features/player/presentation/vlc/side_car_fetch.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import 'fake_vlc_engine.dart';
import 'vlc_screen_harness.dart';

void main() {
  late FakeVlcEngine engine;

  setUp(() {
    engine = FakeVlcEngine();
    installEngineMocks(engine: engine);
  });
  tearDown(removeEngineMocks);

  /// Every look the screen handed the engine, in order.
  List<Map<Object?, Object?>> looks() => engine
      .callsTo('setSubtitleLook')
      .map((call) => call.arguments as Map<Object?, Object?>)
      .toList();

  /// The settings notifier the screen listens to, for changing a setting the
  /// way the player's Subtitle style page does.
  PlayerSettingsNotifier settingsOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(VlcPlayerScreen)))
          .read(playerSettingsProvider.notifier);

  Future<void> pumpScreen(
    WidgetTester tester, {
    PlayerSettings settings = const PlayerSettings(),
  }) => pumpPlayer(
    tester,
    settings: settings,
    overrides: [settingsRepositoryProvider.overrideWithValue(MemorySettings())],
  );

  testWidgets('hands the player its look as it is created, the lift '
      'included', (tester) async {
    await pumpScreen(
      tester,
      settings: const PlayerSettings(subtitleRaise: 0.1),
    );

    expect(looks(), hasLength(1));
    expect(looks().single['textScale'], 100);
    expect(looks().single['raise'], 0.1);
    expect(looks().single['outlineThickness'], 2);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('sends a new look when a setting it carries changes', (
    tester,
  ) async {
    await pumpScreen(tester);

    await settingsOf(tester).setSubtitleSize(44);
    await tester.pump();
    expect(looks(), hasLength(2));
    expect(looks().last['textScale'], 200, reason: 'twice the size');

    await settingsOf(tester).setSubtitleOutline(SubtitleOutline.thick);
    await tester.pump();
    expect(looks(), hasLength(3));
    expect(looks().last['outlineThickness'], 6);
    expect(looks().last['textScale'], 200, reason: 'the size stays');

    await settingsOf(tester).setSubtitleBackground(0xFFFFFFFF, 0.8);
    await tester.pump();
    expect(looks().last['backgroundColor'], 0xFFFFFF);
    expect(looks().last['backgroundOpacity'], 204);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('a step on the Subtitle style page is saved, shown on the page '
      'and handed to libVLC', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final store = MemorySettings();
    await pumpPlayer(
      tester,
      overrides: [settingsRepositoryProvider.overrideWithValue(store)],
    );
    await sendFirstFrame(tester);
    await revealPlayerControls(tester);
    await tester.tap(find.byTooltip(l10n.options));
    await settle(tester);
    await tester.tap(find.text(l10n.subtitles));
    await settle(tester);
    // A television's way there: down the tab to the row, and Select.
    String? focused() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PanelRow>()
        ?.label;
    for (var i = 0; i < 12 && focused() != l10n.subtitleStyle; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.select, platform: 'android');
    await settle(tester);
    expect(find.byType(SubtitleStylePage), findsOneWidget);

    // The page opens on Size, and a remote's Right is one step.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await settle(tester);

    expect(store.stored['player_sub_size'], 23.0, reason: 'saved');
    expect(
      find.descendant(
        of: find.widgetWithText(PanelStepperRow, l10n.textSize),
        matching: find.text('23'),
      ),
      findsOneWidget,
      reason: 'the screen hands the page the settings it changed',
    );
    // Created at 22, libVLC's 24: 23 is 100 x 24 x 23 / 528 percent of it.
    expect(looks().last['textScale'], 105);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('sends nothing for a change the look does not carry', (
    tester,
  ) async {
    await pumpScreen(tester);
    expect(looks(), hasLength(1));

    final notifier = settingsOf(tester);
    await notifier.setSeekDuration(30);
    await notifier.setSubtitleBold(true);
    await notifier.setSubtitleTextOpacity(0.5);
    await notifier.setSubtitleEncoding('Windows-1251');
    await tester.pump();

    expect(looks(), hasLength(1));

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('scales against the size the player was created at', (
    tester,
  ) async {
    await pumpScreen(tester, settings: const PlayerSettings(subtitleSize: 44));

    await settingsOf(tester).setSubtitleSize(22);
    await tester.pump();
    expect(looks().last['textScale'], 50, reason: 'half what it started at');

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  /// A Russian subtitle file that is not Unicode: Привет, in Windows-1251.
  final cyrillic = <int>[
    ...ascii.encode('1\n00:00:00,000 --> 10:00:00,000\n'),
    ...<int>[0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2],
    0x0A,
  ];

  /// A source shipping that file, which Auto puts on screen by itself.
  List<StreamResult> russianSource() => <StreamResult>[
    StreamResult(
      url: '/sources/alpha.mkv',
      source: '1080p',
      providerName: 'alpha.mkv',
      subtitles: <SubtitleFile>[
        SubtitleFile(url: '/subs/russian.srt', label: 'Russian'),
      ],
    ),
  ];

  Future<void> firstTick(WidgetTester tester) async {
    await engine.emit();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  testWidgets('reads a source\'s subtitle file in the encoding chosen', (
    tester,
  ) async {
    await pumpPlayer(
      tester,
      preloadedStreams: russianSource(),
      settings: const PlayerSettings(subtitleEncoding: 'Windows-1251'),
      overrides: [
        sideCarFetchProvider.overrideWithValue(
          (url, headers) async => cyrillic,
        ),
      ],
    );
    await firstTick(tester);

    expect(find.text('Привет'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);

  testWidgets('a subtitle file on screen is read again at once when the '
      'encoding changes', (tester) async {
    await pumpPlayer(
      tester,
      preloadedStreams: russianSource(),
      overrides: [
        settingsRepositoryProvider.overrideWithValue(MemorySettings()),
        sideCarFetchProvider.overrideWithValue(
          (url, headers) async => cyrillic,
        ),
      ],
    );
    await firstTick(tester);
    expect(find.text('Ïðèâåò'), findsWidgets, reason: 'Auto reads Western');

    // What the setting is for: the viewer sees gibberish and picks Cyrillic.
    await settingsOf(tester).setSubtitleEncoding('Windows-1251');
    await tester.pump();

    expect(find.text('Привет'), findsWidgets);
    expect(find.text('Ïðèâåò'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  }, variant: texturePlatform);
}
