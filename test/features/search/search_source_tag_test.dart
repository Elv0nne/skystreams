import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/search/presentation/search_sources.dart';
import 'package:skystream/features/search/presentation/widgets/search_source_tag.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// The tag naming a search section's system.
void main() {
  testWidgets('names each system', (tester) async {
    for (final (kind, label) in [
      (SearchSourceKind.skystream, 'SkyStream'),
      (SearchSourceKind.cloudstream, 'CloudStream'),
      (SearchSourceKind.stremio, 'Stremio'),
      (SearchSourceKind.nuvio, 'Nuvio'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: Center(child: SearchSourceTag(kind))),
        ),
      );
      expect(find.text(label), findsOneWidget, reason: '$kind');
    }
  });
}
