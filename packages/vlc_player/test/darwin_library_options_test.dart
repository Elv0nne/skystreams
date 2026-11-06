import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every libVLC instance the Darwin plugins make turns two of VLCKit's
/// defaults off after the host's options, so they win over VLCKit's own, which
/// VLCKit puts in front (FORK.md 32): the pause at every end, and the volume
/// saved into libVLC's configuration. On macOS, retired players stop one at a
/// time. Pinned as source: no Dart test builds the plugins.
void main() {
  for (final platform in <String>['ios', 'macos']) {
    test('$platform: every library ends at the end and saves no volume', () {
      final library = _functionBody(
        File(
          '$platform/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift',
        ).readAsStringSync(),
        'private static func library(for options: [String]) -> VLCLibrary',
      );
      expect(
        library,
        contains(
          'VLCLibrary(options: options + '
          '["--no-play-and-pause", "--no-volume-save"])',
        ),
      );
      expect(library, isNot(contains('VLCLibrary(options: options)')));
    });
  }

  test('macos: a new player starts at the volume last set on any', () {
    // libVLC did it through the volume it saved in its configuration, which
    // the library's --no-volume-save turns off; iOS never carried it.
    final source = File(
      'macos/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift',
    ).readAsStringSync();
    expect(
      _functionBody(source, 'func setVolume(_ volume: Int)'),
      contains('Self.lastVolume = clamped'),
    );
    expect(
      _functionBody(source, 'init(\n    viewId: Int64,'),
      contains('if let volume = Self.lastVolume {'),
    );
  });

  test('macos: retired players stop one at a time', () {
    // A retired player's close saves libVLC's configuration under a read lock
    // it takes twice, and its audio output's close writes that configuration:
    // two retired players closing at once deadlocked.
    final source = File(
      'macos/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift',
    ).readAsStringSync();
    expect(source, contains('label: "vlc_player.retire", qos: .utility)'));
    final replace = _functionBody(source, 'private func replacePlayer()');
    expect(replace, contains('Self.retire(old)'));
    expect(replace, isNot(contains('old.stop()')));
    final dispose = _functionBody(source, 'func dispose()');
    expect(dispose, contains('Self.retire(player)'));
    expect(dispose, isNot(contains('player.stop()')));
  });
}

/// The body of the function whose declaration starts with [signature],
/// brace-matched so a nested block cannot end it early.
String _functionBody(String source, String signature) {
  final declaration = source.indexOf(signature);
  if (declaration == -1) {
    fail('Could not find $signature.');
  }
  final start = source.indexOf('{', declaration);
  if (start == -1) {
    fail('Could not find the opening brace of $signature.');
  }
  var depth = 0;
  for (var index = start; index < source.length; index += 1) {
    final char = source.codeUnitAt(index);
    if (char == 0x7b) {
      depth += 1;
    } else if (char == 0x7d) {
      depth -= 1;
      if (depth == 0) {
        return source.substring(start, index + 1);
      }
    }
  }
  fail('Could not find the closing brace of $signature.');
}
