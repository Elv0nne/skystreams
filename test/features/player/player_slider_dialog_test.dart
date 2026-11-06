/// The player's slider dialog, which picks the speed and the volume.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/player_slider_dialog.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

String _speed(double speed) {
  final text = speed.toStringAsFixed(2);
  final trimmed = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return '${trimmed}x';
}

void main() {
  // Seven speeds, up to the engine's 4x, on a small phone held upright: one
  // row of equal columns, which a remote walks with one arrow, and a label
  // too wide for its column is drawn smaller rather than cut.
  testWidgets(
    'a preset too wide for its column shrinks rather than being cut',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerSliderDialog(
              title: 'Playback speed',
              value: 1,
              min: 0.25,
              max: 4,
              step: 0.05,
              format: _speed,
              presets: const <double>[0.5, 1, 1.25, 1.5, 2, 3, 4],
              onChanged: (_) {},
            ),
          ),
        ),
      );

      final labels = tester.renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.byKey(kPlayerPresetRowKey),
          matching: find.byType(RichText),
        ),
      );
      expect(labels.map((p) => p.text.toPlainText()), <String>[
        '0.5x',
        '1x',
        '1.25x',
        '1.5x',
        '2x',
        '3x',
        '4x',
      ]);
      for (final label in labels) {
        expect(
          label.didExceedMaxLines,
          isFalse,
          reason: '${label.text.toPlainText()} is cut',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );
}
