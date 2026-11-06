import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `pictureHeld` is the shared hold decision on every backend that can hold,
/// pinned as source: no Dart test builds the backends, and the difference
/// between the decision and an output's own state is one line in each
/// (FORK.md 30).
void main() {
  test('the C++ core reports the decision, not the sink', () {
    final snapshot = _functionBody(
      _fileText('src/native/vlc_player_core.cc'),
      'VlcSnapshot VlcPlayerCore::Snapshot()',
    );
    expect(snapshot, contains('snapshot.picture_held = picture_hold_.held();'));
    expect(snapshot, isNot(contains('frame_sink_->held()')));
  });

  test('Darwin reports the decision, while the renderer bridges every '
      'source', () {
    final source = _fileText('darwin/VlcPlayerEvents.mm');
    final pictureHeld = _functionBody(source, '- (BOOL)pictureHeld');
    expect(pictureHeld, contains('_hold.held()'));
    expect(pictureHeld, isNot(contains('_renderer.pictureHeld')));
    // The renderer still holds at every source: the new video output's
    // Configure drops the picture it was showing, and a nil buffer paints
    // black.
    final arm = _functionBody(source, '- (void)armWithKeepPicture:');
    expect(arm, contains('[_renderer holdPicture]'));
  });

  test('Darwin sends the snapshot that ends a hold at once', () {
    final source = _fileText('darwin/VlcPlayerEvents.mm');
    final start = source.indexOf('case libvlc_MediaPlayerTimeChanged:');
    final end = source.indexOf('case libvlc_MediaPlayerStopped:', start);
    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final timeChanged = source.substring(start, end);
    final release = timeChanged.indexOf('[_renderer releasePicture];');
    expect(release, isNonNegative);
    // After a release the case breaks out to scheduleChanged rather than
    // returning: VLCKit's own time callback can be a second away.
    final breakOut = timeChanged.indexOf('break;', release);
    expect(breakOut, isNonNegative);
    expect(breakOut, lessThan(timeChanged.indexOf('return;', release)));
  });

  test('Darwin ends a hold at libVLC\'s first time report: PositionChanged, '
      'which comes before TimeChanged and VLCKit\'s listener for it', () {
    // lib/media_player.c sends a new time as PositionChanged, then
    // TimeChanged (INPUT_EVENT_POSITION), and VLCKit's listeners come before
    // the plugin's: its TimeChanged one queues the time the next snapshot
    // reads. A hold ended at TimeChanged could still be on when that snapshot
    // went out, the first report that moved, still held, at the old
    // picture's shape (test/native/darwin_player_events_test.mm).
    final source = _fileText('darwin/VlcPlayerEvents.mm');
    final list = source.indexOf('constexpr libvlc_event_e kEvents[] = {');
    expect(list, isNonNegative);
    expect(
      source.substring(list, source.indexOf('};', list)),
      contains('libvlc_MediaPlayerPositionChanged'),
    );
    final position = source.indexOf('case libvlc_MediaPlayerPositionChanged:');
    expect(position, isNonNegative);
    final release = source.indexOf('_hold.OnTimeChanged()', position);
    expect(release, greaterThan(position));
    final between = source.substring(position, release);
    expect(between, isNot(contains('break;')));
    expect(between, isNot(contains('return;')));
  });

  test('Darwin sends a snapshot made on the main thread at once, so '
      'setSource\'s opening snapshot comes before its answer', () {
    // A host reads the hold right after `await setMedia` (FORK.md 33). Darwin
    // queued every event for a later turn of the main queue, so the answer,
    // sent at once, came first.
    for (final platform in const ['ios', 'macos']) {
      final send = _functionBody(
        _fileText(
          '$platform/vlc_player/Sources/vlc_player/VlcPlayerPlugin.swift',
        ),
        'func send(_ event: [String: Any])',
      );
      final direct = send.indexOf('if Thread.isMainThread {');
      expect(direct, isNonNegative, reason: platform);
      expect(
        direct,
        lessThan(send.indexOf('DispatchQueue.main.async')),
        reason: platform,
      );
    }
  });

  test('Android reports the decision, not the overlay', () {
    final snapshot = _functionBody(
      _fileText(
        'android/src/main/kotlin/com/lingjhf/vlc_player/'
        'VlcPlayerPlatformView.kt',
      ),
      'private fun sendSnapshot(',
    );
    expect(snapshot, contains('event["pictureHeld"] = pictureHold.held'));
    expect(snapshot, isNot(contains('heldPicture != null')));
  });

  test('Android ends a hold at libVLC\'s first time report: PositionChanged, '
      'which comes before TimeChanged', () {
    // lib/media_player.c sends a new time as PositionChanged, then
    // TimeChanged (INPUT_EVENT_POSITION). A snapshot sent on the first with
    // the hold still on was the first report that moved, still held, at the
    // old picture's shape.
    final source = _fileText(
      'android/src/main/kotlin/com/lingjhf/vlc_player/'
      'VlcPlayerPlatformView.kt',
    );
    final start = source.indexOf('MediaPlayer.Event.PositionChanged -> {');
    expect(start, isNonNegative);
    final branch = source.substring(
      start,
      source.indexOf('sendSnapshot()', start),
    );
    expect(branch, contains('applyHold(pictureHold.onTimeChanged())'));
  });
}

String _fileText(String path) => File(path).readAsStringSync();

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
