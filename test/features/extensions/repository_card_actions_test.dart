/// What a repository's card does with plugins the user has, when it lists
/// them too: a plugin installed from one repository is that repository's to
/// update, and moving it to another is the user's call, never a side effect.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/extensions/base_provider.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/core/extensions/models/extension_plugin.dart';
import 'package:skystream/core/extensions/models/extension_repository.dart';
import 'package:skystream/features/extensions/providers/extensions_controller.dart';
import 'package:skystream/features/extensions/screens/extensions_screen.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const String _a = 'https://a.test/repo.json';
const String _b = 'https://b.test/repo.json';

/// Records what the screen asks to install.
class _Recorder extends ExtensionsController {
  _Recorder(this._initial);

  final ExtensionsState _initial;
  final List<List<ExtensionPlugin>> installs = <List<ExtensionPlugin>>[];

  @override
  ExtensionsState build() => _initial;

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<void> installPlugins(
    List<ExtensionPlugin> plugins, {
    bool quiet = false,
  }) async {
    installs.add(plugins);
  }
}

class _Manager extends ExtensionManager {
  @override
  List<SkyStreamProvider> build() => [];

  @override
  List<PluginSubProvider> getProvidersForPlugin(ExtensionPlugin plugin) => [];

  @override
  Future<List<PluginSettingDefinition>> getSettingsForPlugin(
    ExtensionPlugin plugin,
  ) async => [];
}

/// [name] at [version]: as [listedBy] lists it, or as installed from [from]
/// (null: an install from before the address was kept).
ExtensionPlugin _plugin(
  String name,
  int version, {
  String? listedBy,
  String? from,
}) => ExtensionPlugin(
  packageName: 'com.example.${name.toLowerCase()}',
  name: name,
  repositoryId: 'repo',
  repositoryUrl: listedBy ?? from,
  sourceUrl: 'https://cdn.test/${name.toLowerCase()}-v$version.sky',
  version: version,
);

/// Repository A and repository B, with [installed] on disk and [listedByB]
/// in B's listing - A lists what is installed from it - opened on the
/// Repositories tab with [expand] expanded.
Future<_Recorder> _openB(
  WidgetTester tester, {
  required List<ExtensionPlugin> installed,
  required List<ExtensionPlugin> listedByB,
  String expand = 'Repo B',
}) async {
  tester.view.physicalSize = const Size(1400, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final controller = _Recorder(
    ExtensionsSuccess(
      repositories: [
        ExtensionRepository(name: 'Repo A', url: _a, pluginLists: const []),
        ExtensionRepository(name: 'Repo B', url: _b, pluginLists: const []),
      ],
      installedPlugins: installed,
      availablePlugins: {
        _a: [
          for (final plugin in installed)
            if (plugin.repositoryUrl == _a)
              _plugin(plugin.name, plugin.version, listedBy: _a),
        ],
        _b: listedByB,
      },
      availableUpdates: const {},
      installingPlugins: const {},
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        extensionsControllerProvider.overrideWith(() => controller),
        extensionManagerProvider.overrideWith(() => _Manager()),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ExtensionsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Repositories'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(expand));
  await tester.pumpAndSettle();
  return controller;
}

/// The row of the plugin called [name].
Finder _row(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(ListTile));

/// The action that installs a repository's copy of a plugin the user has
/// from another, in [name]'s row.
Finder _installHere(String name) => find.descendant(
  of: _row(name),
  matching: find.byTooltip('Install from this repository'),
);

/// The tooltip of the button holding the focus, if one does.
String? _focusedTooltip() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<IconButton>()
    ?.tooltip;

void main() {
  testWidgets('Download All installs what is missing, and updates only what '
      'came from this repository', (tester) async {
    final controller = await _openB(
      tester,
      installed: [
        _plugin('Xray', 1, from: _a),
        // The same repository, its address spelled another way.
        _plugin('Yankee', 2, from: 'HTTPS://B.test/repo.json/'),
        _plugin('Victor', 2, from: _b),
        _plugin('Whiskey', 1),
      ],
      listedByB: [
        _plugin('Xray', 9, listedBy: _b),
        _plugin('Yankee', 3, listedBy: _b),
        _plugin('Victor', 2, listedBy: _b),
        _plugin('Whiskey', 5, listedBy: _b),
        _plugin('Zulu', 1, listedBy: _b),
      ],
    );

    await tester.tap(find.text('Download All'));
    await tester.pumpAndSettle();

    expect(
      [
        for (final batch in controller.installs)
          for (final plugin in batch) '${plugin.name} v${plugin.version}',
      ],
      <String>['Yankee v3', 'Zulu v1'],
    );
  });

  // A plugin whose repository is gone - removed, or followed under another
  // spelling now - could never update again, with no way to move it.
  group('a plugin installed from another repository', () {
    testWidgets('can be installed from this one, with a remote, once the user '
        'is told where it came from', (tester) async {
      final controller = await _openB(
        tester,
        installed: [_plugin('Alpha', 1, from: _a)],
        listedByB: [_plugin('Alpha', 2, listedBy: _b)],
      );

      // From the row's last button, the way a remote walks it.
      Focus.maybeOf(
        tester.element(
          find.descendant(
            of: _row('Alpha'),
            matching: find.byIcon(Icons.delete),
          ),
        ),
      )!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(_focusedTooltip(), 'Install from this repository');

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining(_a),
        ),
        findsOneWidget,
        reason: 'the dialog does not say where the installed copy came from',
      );
      expect(controller.installs, isEmpty, reason: 'installed before asking');

      await tester.tap(find.widgetWithText(TextButton, 'Install'));
      await tester.pumpAndSettle();

      final installed = controller.installs.single.single;
      expect(installed.packageName, 'com.example.alpha');
      expect(installed.version, 2);
      expect(installed.repositoryUrl, _b);
    });

    testWidgets('stays where it is when the user cancels', (tester) async {
      final controller = await _openB(
        tester,
        installed: [_plugin('Alpha', 1, from: _a)],
        listedByB: [_plugin('Alpha', 2, listedBy: _b)],
      );

      await tester.tap(_installHere('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(controller.installs, isEmpty);
    });

    testWidgets('is offered on no card but another repository\'s', (
      tester,
    ) async {
      await _openB(
        tester,
        installed: [
          _plugin('Alpha', 1, from: _a),
          // The same repository, its address spelled another way.
          _plugin('Bravo', 1, from: 'https://B.test/repo.json/'),
          // From before addresses were kept: where from is not known.
          _plugin('Charlie', 1),
        ],
        listedByB: [
          _plugin('Bravo', 2, listedBy: _b),
          _plugin('Charlie', 2, listedBy: _b),
        ],
        expand: 'Repo A',
      );
      await tester.tap(find.text('Repo B'));
      await tester.pumpAndSettle();

      // Alpha on A's own card, and B's plugins on B's.
      expect(find.text('Alpha'), findsOneWidget);
      expect(_installHere('Alpha'), findsNothing);
      expect(_installHere('Bravo'), findsNothing);
      expect(_installHere('Charlie'), findsNothing);

      // Nor on the Installed tab.
      await tester.tap(find.text('Installed'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Install from this repository'), findsNothing);
    });
  });
}
