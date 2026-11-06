import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/features/nuvio/presentation/nuvio_scraper_settings_dialog.dart';

/// A scraper's settings, on a television: a text setting doesn't hold the
/// remote, so Save stays in reach.
void main() {
  testWidgets('with the keyboard put away, DOWN leaves a text setting', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NuvioScraperSettingsDialog(
            scraperName: 'Scraper',
            fields: [
              NuvioSettingsField(
                type: 'text',
                key: 'token',
                label: 'Token',
                placeholder: 'Your token',
              ),
            ],
            initialValues: {},
          ),
        ),
      ),
    );
    await tester.pump();

    final field = tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode;
    field.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    expect(field.hasFocus, isFalse, reason: 'DOWN stayed in the text setting');
  });
}
