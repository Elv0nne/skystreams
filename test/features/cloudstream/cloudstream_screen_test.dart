/// The CloudStream screen renders installed extensions and repositories, and keeps rendering as
/// its state changes (installs, repositories arriving), without a network or an engine.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/cloudstream_models.dart';
import 'package:skystream/core/cloudstream/cloudstream_repository.dart';
import 'package:skystream/features/cloudstream/presentation/cloudstream_screen.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const _repoUrl = 'https://repo.test/repo.json';

CsPluginInfo _plugin(String name, {int version = 1, int status = 1}) => CsPluginInfo(
  internalName: name,
  name: name,
  url: 'https://repo.test/$name.cs3',
  repositoryUrl: _repoUrl,
  version: version,
  status: status,
  tvTypes: const ['Movie'],
  language: 'en',
  fileSize: 30000,
);

/// A fixed state, which the test can replace.
class _FakeCloudStream extends CloudStreamRepository {
  _FakeCloudStream(this._initial);

  final CloudStreamState _initial;

  @override
  CloudStreamState build() => _initial;

  // The real one loads extensions on the engine, which a widget test doesn't have.
  @override
  Future<void> learnSettings() async {}

  final switched = <bool>[];

  @override
  Future<void> setEnabled(bool value) async => switched.add(value);

  void replace(CloudStreamState next) => state = next;
}

void main() {
  testWidgets('renders installed extensions and repositories, and follows state changes', (tester) async {
    final installed = CsInstalledPlugin(
      info: _plugin('Alpha'),
      filePath: '/x/Alpha.cs3',
      providers: const [CsProviderInfo(name: 'Alpha')],
    );
    final repo = CsRepository(
      url: _repoUrl,
      name: 'Repo',
      plugins: [_plugin('Alpha', version: 2), _plugin('Bravo', status: 0), _plugin('Charlie', status: 3)],
    );
    final fake = _FakeCloudStream(CloudStreamState(isLoading: false, installed: [installed], repositories: [repo]));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudStreamRepositoryProvider.overrideWith(() => fake)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CloudStreamScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('CloudStream Extensions'), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('v1 → v2'), findsOneWidget, reason: 'the update the repository offers');
    expect(find.text('Check Updates (1)'), findsOneWidget);

    await tester.tap(find.text('Repositories'));
    await tester.pumpAndSettle();
    expect(find.text('Repo'), findsOneWidget);
    expect(find.text('down'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);

    // State changes the way installs and arriving repositories make them.
    for (var i = 0; i < 20; i++) {
      fake.replace(
        fake.state.copyWith(
          busy: i.isEven ? {CloudStreamRepository.keyOf(_plugin('Bravo'))} : const {},
          repositories: [
            ...fake.state.repositories,
            CsRepository(url: 'https://more.test/$i/repo.json', name: 'More $i', plugins: [_plugin('X$i')]),
          ],
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('Repo'), findsOneWidget, reason: 'the list stopped rendering as repositories arrived');
  });

  testWidgets("a keyboard over the screen, a sheet's or a dialog's, doesn't squeeze it", (tester) async {
    // The small phone the device tests use (720×1280 at 2×), with a keyboard up for a field above it.
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2;
    tester.view.viewInsets = const FakeViewPadding(bottom: 700);
    addTearDown(tester.view.reset);
    final fake = _FakeCloudStream(
      CloudStreamState(
        isLoading: false,
        installed: [CsInstalledPlugin(info: _plugin('Alpha'), filePath: '/x/Alpha.cs3')],
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudStreamRepositoryProvider.overrideWith(() => fake)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CloudStreamScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    "an extension's Settings button shows wherever its screen can be drawn: every platform SkyStream runs on",
    (tester) async {
      final state = CloudStreamState(
        isLoading: false,
        installed: [CsInstalledPlugin(info: _plugin('Alpha'), filePath: '/x/Alpha.cs3', hasSettings: true)],
      );
      Future<void> show() async {
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [cloudStreamRepositoryProvider.overrideWith(() => _FakeCloudStream(state))],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: CloudStreamScreen(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
      }

      final settings = find.byKey(const ValueKey('cs3_settings_Alpha'));
      await show();
      expect(settings, findsOneWidget, reason: 'Android');
      // Android draws them from its real windows; the desktops and iOS from the engine's stand-ins.
      for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux]) {
        debugDefaultTargetPlatformOverride = platform;
        await show();
        debugDefaultTargetPlatformOverride = null;
        expect(settings, findsOneWidget, reason: '$platform');
      }
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
      await show();
      debugDefaultTargetPlatformOverride = null;
      expect(settings, findsNothing, reason: 'Fuchsia: SkyStream has no engine there');
    },
  );

  testWidgets("switched off, what would load an extension waits for the switch, and Uninstall still works", (
    tester,
  ) async {
    final alpha = CsInstalledPlugin(
      info: _plugin('Alpha'),
      filePath: '/x/Alpha.cs3',
      providers: const [CsProviderInfo(name: 'Alpha')],
      hasSettings: true,
    );
    final repo = CsRepository(url: _repoUrl, name: 'Repo', plugins: [_plugin('Alpha', version: 2), _plugin('Bravo')]);
    final fake = _FakeCloudStream(
      CloudStreamState(
        isLoading: false,
        enabled: false,
        installed: [alpha],
        repositories: [repo],
        popups: {
          '/x/Alpha.cs3': ['Support us'],
        },
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudStreamRepositoryProvider.overrideWith(() => fake)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CloudStreamScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    IconButton button(Finder finder) => tester.widget<IconButton>(finder);
    expect(find.textContaining('no CloudStream extension is loaded'), findsOneWidget);
    expect(button(find.byKey(const ValueKey('cs3_settings_Alpha'))).onPressed, isNull);
    expect(button(find.ancestor(of: find.byTooltip('Update'), matching: find.byType(IconButton))).onPressed, isNull);
    expect(find.byKey(const ValueKey('cs3_support_Alpha')), findsNothing);
    expect(button(find.byKey(const ValueKey('cs3_uninstall_Alpha'))).onPressed, isNotNull);
    await tester.tap(find.text('Repositories'));
    await tester.pumpAndSettle();
    expect(button(find.byKey(const ValueKey('cs3_install_Bravo'))).onPressed, isNull);
    fake.replace(fake.state.copyWith(enabled: true));
    await tester.pump();
    expect(button(find.byKey(const ValueKey('cs3_install_Bravo'))).onPressed, isNotNull, reason: 'on: it works');
  });

  testWidgets("the header's switch switches CloudStream", (tester) async {
    final fake = _FakeCloudStream(const CloudStreamState(isLoading: false));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudStreamRepositoryProvider.overrideWith(() => fake)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CloudStreamScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('cs3_cloudstream_switch')));
    expect(fake.switched, [false]);
  });

  // A repository's address or code is not a word - see CustomTextField.
  testWidgets('the add repository field takes an address', (tester) async {
    final fake = _FakeCloudStream(const CloudStreamState(isLoading: false));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [cloudStreamRepositoryProvider.overrideWith(() => fake)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CloudStreamScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('Repositories'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Repository').last);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)));
    expect(field.keyboardType, TextInputType.url);
    expect(field.autocorrect, isFalse);
  });
}
