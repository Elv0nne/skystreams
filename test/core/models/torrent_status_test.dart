import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/models/torrent_status.dart';

void main() {
  test('reads the peers known, the bytes loaded and the hash', () {
    final status = TorrentStatus.fromMap(<dynamic, dynamic>{
      'active_peers': 12,
      'total_peers': 80,
      'connected_seeders': 3,
      'loaded_size': 24000000,
      'torrent_size': 129302391,
      'bytes_read': 30000000,
      'download_speed': 1400000.0,
      'hash': '08ada5a7a6183aae1e09d831df6748d566095a10',
    });
    expect(status.peers, 12);
    expect(status.totalPeers, 80);
    expect(status.loadedBytes, 24000000);
    expect(status.hash, '08ada5a7a6183aae1e09d831df6748d566095a10');
  });

  test('a number the server left out reads as 0', () {
    // TorrServer marks every number omitempty: a zero is never sent.
    final status = TorrentStatus.fromMap(<dynamic, dynamic>{'title': 'Film'});
    expect(status.totalPeers, 0);
    expect(status.loadedBytes, 0);
    expect(status.hash, '');
  });

  test('progress is what is loaded, not what came over the wire', () {
    // bytes_read counts every file's wire bytes, overhead included, so it
    // ran ahead of what the server holds.
    final status = TorrentStatus.fromMap(<dynamic, dynamic>{
      'loaded_size': 50,
      'bytes_read': 80,
      'torrent_size': 100,
    });
    expect(status.progress, 0.5);
  });
}
