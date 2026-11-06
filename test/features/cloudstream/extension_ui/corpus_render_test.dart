/// Every real settings screen Android captured (the corpus run's trees, kept locally in
/// docs/superpowers/plans/2026-10-05-extension-ui-corpus-android.jsonl) drawn by SkyStream's renderer
/// without a layout error. Skipped where that file isn't present.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/cloudstream/extension_ui/extension_ui_session.dart';
import 'package:skystream/core/cloudstream/extension_ui/ui_tree.dart';
import 'package:skystream/features/cloudstream/presentation/extension_ui/ui_node_view.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

const _corpus = 'docs/superpowers/plans/2026-10-05-extension-ui-corpus-android.jsonl';

class _Api implements ExtensionUiApi {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();

  @override
  Future<int> openSettings(String plugin) async => 1;

  @override
  Future<int> openPopups(String plugin) async => 1;

  @override
  Future<Map<String, dynamic>> uiAction(int session, int node, String action, [Object? value]) async => {'done': true};

  @override
  Future<void> closeUi(int session, {bool force = false}) async {}
}

void main() {
  final file = File(_corpus);
  final screens = <(String, List<UiWindow>)>[];
  if (file.existsSync()) {
    for (final line in file.readAsLinesSync()) {
      final at = line.indexOf('CS3-UI {');
      if (at < 0) continue;
      final report = jsonDecode(line.substring(at + 7)) as Map<String, dynamic>;
      final tree = report['tree'] as List?;
      if (tree == null || tree.isEmpty) continue;
      screens.add((
        report['extension'] as String,
        [for (final w in tree) UiWindow.fromJson(Map<String, dynamic>.from(w as Map))],
      ));
    }
  }

  for (final (name, windows) in screens) {
    for (final (size, ratio) in const [(Size(1080, 2400), 2.625), (Size(2560, 1600), 2.0)]) {
      testWidgets('$name draws without a layout error at ${size.width.toInt()}×${size.height.toInt()}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = ratio;
        addTearDown(tester.view.reset);
        final session = ExtensionUiSession.test(_Api(), windows: windows);
        addTearDown(session.dispose);
        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (details) => errors.add(details.exceptionAsString().split('\n').first);
        try {
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    children: [for (final w in windows) UiNodeView(node: w.root, session: session)],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
        } finally {
          FlutterError.onError = previous;
        }
        expect(errors, isEmpty);
      });
    }
  }

  test('the corpus is there to draw', () {}, skip: screens.isEmpty ? 'no local corpus at $_corpus' : null);
}
