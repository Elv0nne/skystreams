import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/addons/data/addon_client.dart';
import 'package:skystream/core/addons/data/addon_repository.dart';
import 'package:skystream/core/addons/data/debrid_service.dart';
import 'package:skystream/core/addons/models/addon_manifest.dart';
import 'package:skystream/features/addons/presentation/addon_providers.dart';
import 'package:skystream/features/addons/presentation/addons_screen.dart';
import 'package:skystream/features/addons/presentation/widgets/addon_manage_view.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// Two installed add-ons: enough for the list to offer its search field.
class _Repo extends AddonRepository {
  @override
  AddonsState build() => AddonsState(
    isLoading: false,
    addons: [
      for (final name in ['Cinemeta', 'Torrentio'])
        ManagedAddon(
          manifestUrl: 'https://$name.test/manifest.json',
          addedAt: DateTime(2026),
          manifest: AddonManifest(
            id: name.toLowerCase(),
            name: name,
            version: '1.0.0',
            resources: const [AddonResource(name: 'stream')],
            types: const ['movie'],
          ),
        ),
    ],
  );
}

/// The text field around [hint]'s focus node.
FocusNode _fieldWith(WidgetTester tester, String hint) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.ancestor(
          of: find.text(hint),
          matching: find.byType(TextField),
        ),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode;

/// The debrid API key dialog's field, opened the way a viewer opens it.
Future<FocusNode> _openApiKeyDialog(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1920, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [addonRepositoryProvider.overrideWith(_Repo.new)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: AddonManageView()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));

  final dropdown = find.byType(DropdownButtonFormField<DebridProvider>);
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Real-Debrid').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Enter API Key'));
  await tester.pumpAndSettle();

  final field = tester
      .widget<EditableText>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(EditableText),
        ),
      )
      .focusNode;
  expect(field.hasFocus, isTrue);
  return field;
}

/// The add-ons' search fields, on a television.
void main() {
  // The API key field, on a television: while a keyboard is up its keys are
  // its own, and Select - OK on a remote - brings back a keyboard put away
  // with Back.
  testWidgets('API key: down stays with a visible keyboard', (tester) async {
    final field = await _openApiKeyDialog(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 540);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(field.hasFocus, isTrue);
  });

  testWidgets('API key: select reopens a keyboard put away with back', (
    tester,
  ) async {
    final field = await _openApiKeyDialog(tester);
    tester.testTextInput.hide();
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();

    expect(tester.testTextInput.isVisible, isTrue);
    expect(field.hasFocus, isTrue);
  });

  testWidgets(
    'with the keyboard put away, DOWN leaves Discover\'s search for the add-ons below it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1920, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            addonRepositoryProvider.overrideWith(_Repo.new),
            communityAddonsProvider.overrideWith(
              (ref) async => [
                const CommunityAddon(
                  transportUrl: 'https://community.test/manifest.json',
                  manifest: AddonManifest(
                    id: 'community',
                    name: 'Community',
                    version: '1.0.0',
                    resources: [AddonResource(name: 'stream')],
                    types: ['movie'],
                  ),
                ),
              ],
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: AddonsScreen(isEmbedded: true, initialTab: 1)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final field = _fieldWith(tester, 'Search community add-ons');
      field.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(
        field.hasFocus,
        isFalse,
        reason: 'DOWN stayed in the search field',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'with the keyboard put away, DOWN leaves the search for the add-ons below it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1920, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [addonRepositoryProvider.overrideWith(_Repo.new)],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: AddonManageView()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final search = find.ancestor(
        of: find.text('Search installed add-ons…'),
        matching: find.byType(TextField),
      );
      final field = tester
          .widget<EditableText>(
            find.descendant(of: search, matching: find.byType(EditableText)),
          )
          .focusNode;
      field.requestFocus();
      await tester.pump();
      expect(field.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      expect(
        field.hasFocus,
        isFalse,
        reason: 'DOWN stayed in the search field',
      );
      final focused = FocusManager.instance.primaryFocus!.rect;
      expect(focused.top, greaterThan(tester.getRect(search).bottom));

      await tester.pumpWidget(const SizedBox());
    },
  );
}
