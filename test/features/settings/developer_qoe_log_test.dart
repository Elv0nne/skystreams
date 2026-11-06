import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/core/storage/settings_repository.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/features/player/domain/qoe_log.dart';
import 'package:skystream/features/settings/presentation/developer_options_screen.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Answers the developer screen's reads without a storage stack, and keeps
/// what the QoE switch writes.
class _Settings extends SettingsRepository {
  _Settings() : super(StorageService());

  final List<bool> qoeWrites = <bool>[];

  @override
  bool getDevLoadAssets() => false;

  @override
  Future<void> setDevQoeLog(bool enabled) async => qoeWrites.add(enabled);
}

void main() {
  tearDown(() => QoeLog.writeToAppLog = false);

  testWidgets('the QoE log switch turns the app-log lines on and is stored', (
    tester,
  ) async {
    QoeLog.writeToAppLog = false;
    final settings = _Settings();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          deviceProfileProvider.overrideWithValue(
            const AsyncValue.data(DeviceProfile()),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DeveloperOptionsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('QoE log'));
    await tester.tap(find.text('QoE log'));
    await tester.pumpAndSettle();

    expect(QoeLog.writeToAppLog, isTrue);
    expect(settings.qoeWrites, <bool>[true]);
  });

  testWidgets('the switch shows what is in force when the screen opens', (
    tester,
  ) async {
    QoeLog.writeToAppLog = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(_Settings()),
          deviceProfileProvider.overrideWithValue(
            const AsyncValue.data(DeviceProfile()),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DeveloperOptionsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.ancestor(
      of: find.text('QoE log'),
      matching: find.byType(ListTile),
    );
    await tester.ensureVisible(row);
    final toggle = tester.widget<Switch>(
      find.descendant(of: row, matching: find.byType(Switch)),
    );
    expect(toggle.value, isTrue);
  });
}
