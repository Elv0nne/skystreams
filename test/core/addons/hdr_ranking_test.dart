import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/addons/models/addon_stream_source.dart';

/// HDR earns no rank: every SkyStream path shows it washed out (P1 spec 6;
/// the HDR research of 2026-10-11). The label stays.
void main() {
  AddonStreamSource parse(String title) => AddonStreamSource.fromJson(
    {'name': 'Torrentio 1080p', 'title': title, 'infoHash': 'aa'},
    addonId: 'a',
    addonName: 'Addon',
  );

  test('an HDR stream scores what its SDR twin scores', () {
    final sdr = parse('Film.2019.1080p.WEB-DL 👤 10');
    final hdr = parse('Film.2019.1080p.HDR.WEB-DL 👤 10');
    expect(hdr.isHdr, isTrue);
    expect(hdr.score, sdr.score);
  });

  test('so more seeders come first, HDR or not', () {
    final ranked = rankAddonStreams([
      parse('Film.2019.1080p.HDR.WEB-DL 👤 10'),
      parse('Film.2019.1080p.WEB-DL 👤 30'),
    ]);
    expect(ranked.first.isHdr, isFalse);
  });
}
