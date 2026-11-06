/// Settings' Extensions group, in the owner's order: SkyStream, CloudStream,
/// Nuvio, Stremio - with CloudStream marked BETA, as the skip-time providers
/// are under Accounts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/services/notification_service.dart';
import 'package:skystream/core/storage/secure_token_storage.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/core/theme/theme_provider.dart';
import 'package:skystream/features/settings/presentation/app_version_provider.dart';
import 'package:skystream/features/settings/presentation/cache_provider.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/features/settings/presentation/settings_screen.dart';
import 'package:skystream/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:skystream/features/tracking/presentation/tracking_auth_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Enough of a repository to render the screen, and nothing that touches a
/// box: [StorageService] here is never initialised.
class _QuietSettings extends SettingsRepository {
  _QuietSettings() : super(StorageService());

  @override
  bool isWatchHistoryEnabled() => true;
  @override
  String getDefaultHomeScreen() => '/home';
  @override
  bool isGithubProxyEnabled() => false;
  @override
  bool? getFullScreenMode() => false;
  @override
  Future<void> setFullScreenMode(bool enabled) async {}
  @override
  bool isAnimeSkipIntegrationEnabled() => false;
  @override
  bool isIntroDbIntegrationEnabled() => false;
  @override
  bool getDevLoadAssets() => false;
}

class _NoTokens extends SecureTokenStorage {
  _NoTokens() : super(StorageService());

  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _SignedOutTrackers extends TrackingAuth {
  @override
  Future<Map<String, bool>> build() async => const <String, bool>{
    'simkl': false,
    'trakt': false,
    'mal': false,
    'anilist': false,
  };
}

void main() {
  testWidgets('the extensions come in the owner\'s order, CloudStream marked '
      'BETA', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(_QuietSettings()),
          secureTokenStorageProvider.overrideWithValue(_NoTokens()),
          notificationServiceProvider.overrideWithValue(NotificationService()),
          trackingAuthProvider.overrideWith(_SignedOutTrackers.new),
          appThemeModeProvider.overrideWithValue(ThemeMode.dark),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          playerSettingsProvider.overrideWithBuild(
            (_, _) => const PlayerSettings(),
          ),
          deviceProfileProvider.overrideWith(
            (ref) => const DeviceProfile(isDesktopOS: true),
          ),
          appVersionProvider.overrideWith((ref) async => '1.0.0 +1'),
          cacheSizeProvider.overrideWith((ref) async => 0),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pump();

    final group = find.byWidgetPredicate(
      (w) => w is SettingsGroup && w.title == 'Extensions',
    );
    final tiles = tester
        .widgetList<SettingsTile>(
          find.descendant(of: group, matching: find.byType(SettingsTile)),
        )
        .toList();
    expect(tiles.map((t) => t.title), [
      'SkyStream Providers',
      'CloudStream Extensions',
      'Nuvio Plugins',
      'Stremio Add-ons',
    ]);
    expect(tiles.where((t) => t.isBeta).map((t) => t.title), [
      'CloudStream Extensions',
    ]);
    expect(tiles.last.isLast, isTrue, reason: 'the card closes on Stremio');
    expect(
      find.descendant(
        of: find.widgetWithText(SettingsTile, 'CloudStream Extensions'),
        matching: find.text('BETA'),
      ),
      findsOneWidget,
    );
  });
}
