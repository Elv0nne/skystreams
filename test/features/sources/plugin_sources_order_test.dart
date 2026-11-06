import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/nuvio/models/nuvio_models.dart';
import 'package:skystream/features/sources/presentation/plugin_sources_sheet.dart';

void main() {
  NuvioStreamResult row(String scraper, String title) =>
      NuvioStreamResult.fromJson(
        {'title': title, 'url': 'https://cdn.test/$scraper.mkv'},
        scraperId: scraper,
        scraperName: scraper,
      )!;

  test('rows of one height keep their providers\' order, HDR or not', () {
    final rows = [
      row('Beta', 'Film 1080p HDR WEB-DL'),
      row('Alpha', 'Film 1080p WEB-DL'),
    ]..sort(comparePluginStreams);
    expect([for (final r in rows) r.scraperName], ['Alpha', 'Beta']);
  });

  test('height still comes first', () {
    final rows = [
      row('Alpha', 'Film 720p WEB-DL'),
      row('Beta', 'Film 1080p WEB-DL'),
    ]..sort(comparePluginStreams);
    expect([for (final r in rows) r.scraperName], ['Beta', 'Alpha']);
  });
}
