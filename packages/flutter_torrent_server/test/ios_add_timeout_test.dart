import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// iOS's add is a URLRequest, pinned as source: no test here builds the
/// Swift. TorrServer answers an add only once the torrent's metadata has
/// come (`web/api/torrents.go`), which takes minutes on a cold magnet, and
/// URLRequest's own 60 s would give up inside the player's 3-minute rule.
void main() {
  test("iOS waits for a torrent's metadata as long as TorrServer does", () {
    final source = File(
      'ios/Classes/FlutterTorrentServerPlugin.swift',
    ).readAsStringSync();
    final start = source.indexOf('private func addTorrent(');
    final end = source.indexOf('private func getTorrentStatus(');
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    expect(
      source.substring(start, end),
      contains('request.timeoutInterval = 300'),
    );
  });
}
