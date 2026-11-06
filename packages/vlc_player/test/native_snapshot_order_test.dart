import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The desktop plugins' snapshot order, pinned as source (FORK.md 37).
///
/// Windows and Linux make snapshots on two threads, the update pump's and the
/// platform thread's after a command, and outside any lock. One the pump
/// began before a park's SetSource reached Dart after SetSource's own: the
/// failed player's "playing", with no hold, read as the parked media playing,
/// and the reopen dropped the picture (P1 Part 3's Windows outage rows). No
/// machine that runs this suite builds these plugins, so the order is what is
/// asserted here; the shared ordering itself is
/// `test/native/vlc_snapshot_order_test_suite.h`.
void main() {
  test('the core numbers a snapshot before it reads the player', () {
    final snapshot = _functionBody(
      _fileText('src/native/vlc_player_core.cc'),
      'VlcSnapshot VlcPlayerCore::Snapshot()',
    );
    final numbered = snapshot.indexOf(
      'snapshot.sequence = ++snapshot_sequence_',
    );
    expect(numbered, isNonNegative);
    expect(numbered, lessThan(snapshot.indexOf('CurrentPlayer()')));
    expect(numbered, lessThan(snapshot.indexOf('picture_hold_.held()')));
  });

  test(
    'Windows admits each snapshot in order under the lock it sends under',
    () {
      final send = _functionBody(
        _fileText('windows/vlc_player_plugin.cpp'),
        'void SendSnapshot(bool lock_messenger = false, bool force = false)',
      );
      final locked = send.indexOf(
        'std::lock_guard<std::mutex> lock(event_mutex_)',
      );
      final admitted = send.indexOf('order_.Admit(snapshot, force)');
      expect(locked, isNonNegative);
      expect(admitted, greaterThan(locked));
      expect(admitted, lessThan(send.indexOf('event_sink_->Success(')));
      expect(send, isNot(contains('last_sent_snapshot_')));
    },
  );

  test(
    'Linux admits each snapshot where it delivers it, on the main thread',
    () {
      // A command's snapshot is delivered at once on the main thread and the
      // pump's queued to it, so only there do the two meet in order. Admitted
      // on the pump's thread, a queued snapshot could be taken first and the
      // command's dropped as a repeat or as older, and setSource answered
      // before any snapshot said the picture was held (FORK.md 33, 37).
      final source = _fileText('linux/vlc_player_plugin.cc');
      final send = _functionBody(
        source,
        'void SendSnapshot(bool force = false)',
      );
      expect(send, isNot(contains('Admit(')));
      expect(send, contains('snapshot,'));
      expect(send, contains('force,'));
      expect(send, isNot(contains('last_sent_snapshot_')));

      final deliver = _functionBody(
        source,
        'static gboolean SendEventOnMain(gpointer data)',
      );
      final admitted = deliver.indexOf(
        'payload->gate->order.Admit(payload->snapshot, payload->force)',
      );
      expect(admitted, isNonNegative);
      expect(admitted, lessThan(deliver.indexOf('fl_event_channel_send(')));
    },
  );

  test('both desktop plugins send each snapshot with its number', () {
    // Windows delivers a send from libVLC's event thread after one from the
    // platform thread made later, so the order admitted is not the order
    // Dart sees: the controller applies none older than the last it applied
    // (vlc_player_snapshot_order_test.dart).
    final windows = _functionBody(
      _fileText('windows/vlc_player_plugin.cpp'),
      'void SendSnapshot(bool lock_messenger = false, bool force = false)',
    );
    expect(
      windows,
      matches(
        RegExp(
          r'event\[EncodableValue\("sequence"\)\]\s*=\s*'
          r'EncodableValue\(static_cast<int64_t>\(snapshot\.sequence\)\)',
        ),
      ),
    );

    final linux = _functionBody(
      _fileText('linux/vlc_player_plugin.cc'),
      'void SendSnapshot(bool force = false)',
    );
    expect(
      linux,
      matches(
        RegExp(
          r'fl_value_set_string_take\(\s*event,\s*"sequence",\s*'
          r'fl_value_new_int\(static_cast<int64_t>\(snapshot\.sequence\)\)\)',
        ),
      ),
    );
  });
}

String _fileText(String path) => File(path).readAsStringSync();

/// The body of the function whose declaration starts with [signature],
/// brace-matched so a nested lambda cannot end it early.
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
