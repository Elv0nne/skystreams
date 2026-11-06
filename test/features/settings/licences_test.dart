import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/core/theme/theme_provider.dart';
import 'package:skystream/features/settings/presentation/app_version_provider.dart';
import 'package:skystream/features/settings/presentation/cache_provider.dart';
import 'package:skystream/features/settings/presentation/general_settings_provider.dart';
import 'package:skystream/features/settings/presentation/settings_screen.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// SkyStream is GPL-3.0, and the GPL asks an interactive program to show its
/// legal notices: who holds the copyright, that there is no warranty, that it
/// may be shared under the GPL, and where the licence is. Settings' About
/// group is where they are, on Flutter's licence page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('licences');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.close();
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            SettingsRepository(storage),
          ),
          appThemeModeProvider.overrideWithValue(ThemeMode.dark),
          generalSettingsProvider.overrideWithValue(const GeneralSettings()),
          appVersionProvider.overrideWith((ref) async => '2.8.1 +1'),
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
  }

  testWidgets('About opens the licence page with SkyStream\'s notice', (
    tester,
  ) async {
    await pumpSettings(tester);
    final row = find.text('Open-source licences');
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    // The list jumps the row into view; the tap needs the frame that lays the
    // jump out.
    await tester.pump();
    expect(
      find.text('SkyStream is free software under the GNU GPL v3'),
      findsOneWidget,
    );

    await tester.tap(row);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(LicensePage), findsOneWidget);
    expect(
      find.textContaining('GNU General Public License, version 3'),
      findsOneWidget,
      reason: 'the notice says which licence applies',
    );
    expect(
      find.textContaining('ABSOLUTELY NO WARRANTY'),
      findsOneWidget,
      reason: 'and that there is no warranty',
    );
  });
}
