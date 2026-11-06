import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vlc_player/vlc_player.dart';

void main() {
  group('VlcPlayerValue', () {
    test('defaults remain backward compatible', () {
      const value = VlcPlayerValue();

      expect(value.state, VlcPlaybackState.idle);
      expect(value.position, Duration.zero);
      expect(value.duration, Duration.zero);
      expect(value.volume, 100);
      expect(value.playbackSpeed, 1);
      expect(value.audioDelay, Duration.zero);
      expect(value.subtitleDelay, Duration.zero);
      expect(value.isReady, isFalse);
      expect(value.isSeekable, isFalse);
      expect(value.isLive, isFalse);
      expect(value.isStalled, isFalse);
      expect(value.videoSize, isNull);
      expect(value.bufferingProgress, isNull);
      expect(value.error, isNull);
      expect(value.errorDescription, isNull);
    });

    test('isStalled takes part in equality and copyWith', () {
      const running = VlcPlayerValue(state: VlcPlaybackState.playing);
      final stalled = running.copyWith(isStalled: true);

      expect(stalled.isStalled, isTrue);
      expect(stalled, isNot(running));
      expect(stalled.hashCode, isNot(running.hashCode));
      expect(
        stalled.copyWith(position: const Duration(seconds: 1)).isStalled,
        isTrue,
      );
      expect(stalled.copyWith(isStalled: false), running);
    });

    test('fromEvent leaves isStalled to the previous value', () {
      // No native backend can report a stall - libVLC 3 stays `playing`
      // through a rebuffer - so the controller owns the flag and an event
      // must neither set nor clear it, whatever keys it carries.
      const stalled = VlcPlayerValue(
        state: VlcPlaybackState.playing,
        isStalled: true,
      );
      final next = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'playing',
        'position': 5000,
        'isStalled': false,
      }, stalled);
      expect(next.isStalled, isTrue);

      final fromClear = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'playing',
        'position': 5000,
        'isStalled': true,
      }, const VlcPlayerValue(state: VlcPlaybackState.playing));
      expect(fromClear.isStalled, isFalse);
    });

    test('compares snapshots by value', () {
      const error = VlcPlayerError(
        code: VlcPlayerErrorCode.playbackError,
        message: 'VLC failed',
        details: <String, Object?>{'viewId': 1},
      );
      const first = VlcPlayerValue(
        state: VlcPlaybackState.playing,
        position: Duration(seconds: 1),
        duration: Duration(seconds: 10),
        volume: 80,
        playbackSpeed: 1.25,
        audioDelay: Duration(milliseconds: -120),
        subtitleDelay: Duration(milliseconds: 250),
        isReady: true,
        isSeekable: true,
        isLive: false,
        videoSize: Size(640, 360),
        bufferingProgress: 0.5,
        error: error,
        errorDescription: 'VLC failed',
      );
      const second = VlcPlayerValue(
        state: VlcPlaybackState.playing,
        position: Duration(seconds: 1),
        duration: Duration(seconds: 10),
        volume: 80,
        playbackSpeed: 1.25,
        audioDelay: Duration(milliseconds: -120),
        subtitleDelay: Duration(milliseconds: 250),
        isReady: true,
        isSeekable: true,
        isLive: false,
        videoSize: Size(640, 360),
        bufferingProgress: 0.5,
        error: error,
        errorDescription: 'VLC failed',
      );

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(
        first,
        isNot(second.copyWith(position: const Duration(seconds: 2))),
      );
    });

    test('parses readiness, seekability, live, video size, and buffering', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'buffering',
        'position': 1200,
        'duration': 10000,
        'volume': 80,
        'playbackSpeed': 1.25,
        'audioDelay': -120000,
        'subtitleDelay': 250000,
        'isReady': false,
        'isSeekable': true,
        'isLive': false,
        'videoSize': <String, Object?>{'width': 1920, 'height': 1080},
        'bufferingProgress': 0.42,
      }, const VlcPlayerValue());

      expect(value.state, VlcPlaybackState.buffering);
      expect(value.position, const Duration(milliseconds: 1200));
      expect(value.duration, const Duration(seconds: 10));
      expect(value.volume, 80);
      expect(value.playbackSpeed, 1.25);
      expect(value.audioDelay, const Duration(milliseconds: -120));
      expect(value.subtitleDelay, const Duration(milliseconds: 250));
      expect(value.isReady, isFalse);
      expect(value.isSeekable, isTrue);
      expect(value.isLive, isFalse);
      expect(value.videoSize, const Size(1920, 1080));
      expect(value.bufferingProgress, 0.42);
    });

    test('reads where playback is in a live window, as a fraction', () {
      const previous = VlcPlayerValue();
      final inWindow = VlcPlayerValue.fromEvent(<String, Object?>{
        'positionFraction': 0.75,
      }, previous);
      expect(inWindow.positionFraction, 0.75);

      // A snapshot without it keeps the last reading.
      expect(
        VlcPlayerValue.fromEvent(<String, Object?>{
          'position': 1000,
        }, inWindow).positionFraction,
        0.75,
      );
      // libVLC's -1 for no media, or anything outside 0..1, clears it.
      expect(
        VlcPlayerValue.fromEvent(<String, Object?>{
          'positionFraction': -1,
        }, inWindow).positionFraction,
        isNull,
      );
      expect(inWindow, isNot(previous));
    });

    test('accepts numeric variants from platform event channels', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'playing',
        'position': 1200.6,
        'duration': 10000.4,
        'volume': 80.6,
        'playbackSpeed': 2,
        'audioDelay': -999.6,
        'subtitleDelay': 1000.4,
        'videoSize': <String, Object?>{'width': 1920.5, 'height': 1080},
      }, const VlcPlayerValue());

      expect(value.position, const Duration(milliseconds: 1201));
      expect(value.duration, const Duration(milliseconds: 10000));
      expect(value.volume, 81);
      expect(value.playbackSpeed, 2.0);
      expect(value.audioDelay, const Duration(microseconds: -1000));
      expect(value.subtitleDelay, const Duration(microseconds: 1000));
      expect(value.videoSize, const Size(1920.5, 1080));
    });

    test('ignores malformed platform event fields without throwing', () {
      const previous = VlcPlayerValue(
        state: VlcPlaybackState.playing,
        position: Duration(seconds: 3),
        duration: Duration(seconds: 30),
        volume: 55,
        playbackSpeed: 1.5,
        audioDelay: Duration(milliseconds: -20),
        subtitleDelay: Duration(milliseconds: 30),
        isReady: true,
        isSeekable: true,
        isLive: true,
      );

      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 3,
        'position': '5000',
        'duration': double.nan,
        'volume': '80',
        'playbackSpeed': Object(),
        'audioDelay': Object(),
        'subtitleDelay': double.nan,
        'isReady': 'true',
        'isSeekable': 1,
        'isLive': 'false',
        'errorCode': 42,
        'errorDescription': Object(),
      }, previous);

      expect(value.state, VlcPlaybackState.playing);
      expect(value.position, const Duration(seconds: 3));
      expect(value.duration, const Duration(seconds: 30));
      expect(value.volume, 55);
      expect(value.playbackSpeed, 1.5);
      expect(value.audioDelay, const Duration(milliseconds: -20));
      expect(value.subtitleDelay, const Duration(milliseconds: 30));
      expect(value.isReady, isTrue);
      expect(value.isSeekable, isTrue);
      expect(value.isLive, isTrue);
      expect(value.error, isNull);
      expect(value.errorDescription, isNull);
    });

    test('keeps optional fields when an event omits them', () {
      const previous = VlcPlayerValue(
        state: VlcPlaybackState.playing,
        isReady: true,
        isSeekable: true,
        isLive: false,
        videoSize: Size(1280, 720),
      );

      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'position': 5000,
      }, previous);

      expect(value.state, VlcPlaybackState.playing);
      expect(value.position, const Duration(seconds: 5));
      expect(value.isReady, isTrue);
      expect(value.isSeekable, isTrue);
      expect(value.isLive, isFalse);
      expect(value.videoSize, const Size(1280, 720));
    });

    test('derives readiness from playback state when native omits it', () {
      final playing = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'playing',
      }, const VlcPlayerValue());
      final buffering = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'buffering',
      }, playing);

      expect(playing.isReady, isTrue);
      expect(buffering.isReady, isFalse);
    });

    test('clears stale video size when a new source starts opening', () {
      const previous = VlcPlayerValue(
        state: VlcPlaybackState.playing,
        videoSize: Size(1920, 1080),
      );

      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'opening',
      }, previous);

      expect(value.videoSize, isNull);
    });

    test('ignores invalid duration, position, size, and progress values', () {
      const previous = VlcPlayerValue(
        position: Duration(seconds: 3),
        duration: Duration(seconds: 30),
        videoSize: Size(640, 360),
        bufferingProgress: 0.5,
      );

      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'buffering',
        'position': -1,
        'duration': double.nan,
        'videoSize': <String, Object?>{'width': 'wide', 'height': 360},
        'bufferingProgress': double.nan,
      }, previous);

      expect(value.position, const Duration(seconds: 3));
      expect(value.duration, const Duration(seconds: 30));
      expect(value.videoSize, isNull);
      expect(value.bufferingProgress, isNull);
    });

    test('clamps buffering progress to a normalized range', () {
      final low = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'buffering',
        'bufferingProgress': -0.5,
      }, const VlcPlayerValue());
      final high = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'buffering',
        'bufferingProgress': 2,
      }, const VlcPlayerValue());

      expect(low.bufferingProgress, 0);
      expect(high.bufferingProgress, 1);
    });

    test('clears buffering progress outside buffering state', () {
      const previous = VlcPlayerValue(
        state: VlcPlaybackState.buffering,
        bufferingProgress: 0.5,
      );

      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'playing',
      }, previous);

      expect(value.bufferingProgress, isNull);
    });

    test('parses structured playback errors and keeps errorDescription', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'error',
        'errorCode': 'playback_error',
        'errorDescription': 'VLC failed',
        'errorDetails': <String, Object?>{'state': 'error'},
      }, const VlcPlayerValue());

      expect(value.state, VlcPlaybackState.error);
      expect(value.error, isNotNull);
      expect(value.error!.code, VlcPlayerErrorCode.playbackError);
      expect(value.error!.message, 'VLC failed');
      expect(value.error!.details, <String, Object?>{'state': 'error'});
      expect(value.errorDescription, 'VLC failed');
      expect(value.hasError, isTrue);
    });

    test('parses nested error payloads', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'error',
        'error': <Object?, Object?>{
          'code': 'set_source_failed',
          'message': 'Bad media',
        },
      }, const VlcPlayerValue());

      expect(value.error!.code, VlcPlayerErrorCode.setSourceFailed);
      expect(value.error!.message, 'Bad media');
      expect(value.errorDescription, 'Bad media');
    });

    test('clears structured errors on a normal event', () {
      const previous = VlcPlayerValue(
        state: VlcPlaybackState.error,
        error: VlcPlayerError(
          code: VlcPlayerErrorCode.playbackError,
          message: 'VLC failed',
        ),
        errorDescription: 'VLC failed',
      );

      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'playing',
      }, previous);

      expect(value.error, isNull);
      expect(value.errorDescription, isNull);
    });

    test('copyWith can clear nullable optional fields', () {
      const previous = VlcPlayerValue(
        state: VlcPlaybackState.error,
        videoSize: Size(640, 360),
        bufferingProgress: 0.5,
        error: VlcPlayerError(
          code: VlcPlayerErrorCode.playbackError,
          message: 'VLC failed',
        ),
        errorDescription: 'VLC failed',
      );

      final value = previous.copyWith(
        clearVideoSize: true,
        clearBufferingProgress: true,
        clearError: true,
      );

      expect(value.videoSize, isNull);
      expect(value.bufferingProgress, isNull);
      expect(value.error, isNull);
      expect(value.errorDescription, isNull);
    });
  });

  group('active tracks and track revision', () {
    const previous = VlcPlayerValue(
      state: VlcPlaybackState.playing,
      activeAudioTrackId: 2,
      activeSubtitleTrackId: 5,
      trackRevision: 4,
    );

    test('defaults are null ids and revision zero', () {
      const value = VlcPlayerValue();
      expect(value.activeAudioTrackId, isNull);
      expect(value.activeSubtitleTrackId, isNull);
      expect(value.trackRevision, 0);
    });

    test('fromEvent parses audioTrack and subtitleTrack ids', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'audioTrack': 2,
        'subtitleTrack': 7,
      }, const VlcPlayerValue());
      expect(value.activeAudioTrackId, 2);
      expect(value.activeSubtitleTrackId, 7);
    });

    test('zero is a legal track id, not "none"', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'audioTrack': 0,
        'subtitleTrack': 0,
      }, previous);
      expect(value.activeAudioTrackId, 0);
      expect(value.activeSubtitleTrackId, 0);
    });

    test('libVLC -1 is normalised to null and clears a previous id', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'audioTrack': -1,
        'subtitleTrack': -1,
      }, previous);
      expect(value.activeAudioTrackId, isNull);
      expect(value.activeSubtitleTrackId, isNull);
    });

    test('an absent key keeps the previous id and revision', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'playing',
        'position': 1000,
      }, previous);
      expect(value.activeAudioTrackId, 2);
      expect(value.activeSubtitleTrackId, 5);
      expect(value.trackRevision, 4);
    });

    test('each id is independent of the other', () {
      final audioOnly = VlcPlayerValue.fromEvent(<String, Object?>{
        'audioTrack': 3,
      }, previous);
      expect(audioOnly.activeAudioTrackId, 3);
      expect(audioOnly.activeSubtitleTrackId, 5);

      final subtitleOff = VlcPlayerValue.fromEvent(<String, Object?>{
        'subtitleTrack': -1,
      }, previous);
      expect(subtitleOff.activeAudioTrackId, 2);
      expect(subtitleOff.activeSubtitleTrackId, isNull);
    });

    test('malformed ids are treated as none without throwing', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'audioTrack': 'two',
        'subtitleTrack': double.nan,
        'trackRevision': 'later',
      }, previous);
      expect(value.activeAudioTrackId, isNull);
      expect(value.activeSubtitleTrackId, isNull);
      expect(value.trackRevision, 4);
    });

    test('accepts numeric variants for ids and revision', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'audioTrack': 2.0,
        'subtitleTrack': 1.0,
        'trackRevision': 9.0,
      }, const VlcPlayerValue());
      expect(value.activeAudioTrackId, 2);
      expect(value.activeSubtitleTrackId, 1);
      expect(value.trackRevision, 9);
    });

    test('fromEvent parses trackRevision', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'trackRevision': 3,
      }, const VlcPlayerValue());
      expect(value.trackRevision, 3);
    });

    test('take part in equality and hashCode', () {
      const base = VlcPlayerValue(state: VlcPlaybackState.playing);
      final audio = base.copyWith(activeAudioTrackId: 1);
      final subtitle = base.copyWith(activeSubtitleTrackId: 1);
      final revision = base.copyWith(trackRevision: 1);

      expect(audio, isNot(equals(base)));
      expect(subtitle, isNot(equals(base)));
      expect(revision, isNot(equals(base)));
      expect(audio, isNot(equals(subtitle)));
      expect(subtitle.hashCode, isNot(equals(base.hashCode)));
      expect(
        base.copyWith(activeSubtitleTrackId: 1),
        equals(base.copyWith(activeSubtitleTrackId: 1)),
      );
    });

    test('copyWith keeps ids unless asked to clear them', () {
      final kept = previous.copyWith(position: const Duration(seconds: 1));
      expect(kept.activeAudioTrackId, 2);
      expect(kept.activeSubtitleTrackId, 5);
      expect(kept.trackRevision, 4);

      final audioCleared = previous.copyWith(clearActiveAudioTrack: true);
      expect(audioCleared.activeAudioTrackId, isNull);
      expect(audioCleared.activeSubtitleTrackId, 5);

      final subtitleCleared = previous.copyWith(clearActiveSubtitleTrack: true);
      expect(subtitleCleared.activeAudioTrackId, 2);
      expect(subtitleCleared.activeSubtitleTrackId, isNull);

      expect(previous.copyWith(trackRevision: 6).trackRevision, 6);
    });
  });

  group('spurious buffering correction', () {
    // libVLC reports `buffering` throughout healthy playback on some builds -
    // VLCKit with isPlaying false, and Android emitting a Buffering event on
    // nearly every tick. Left uncorrected, a consumer shows a spinner over a
    // playing video and never learns that playback started.
    const playing = VlcPlayerValue(
      state: VlcPlaybackState.playing,
      position: Duration(seconds: 10),
    );

    test('buffering during playback with an advancing position is playing', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'buffering',
        'position': 11000,
      }, playing);
      expect(value.state, VlcPlaybackState.playing);
    });

    // A real rebuffer stalls, so the position does not move.
    test('buffering with a stalled position stays buffering', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'buffering',
        'position': 10000,
      }, playing);
      expect(value.state, VlcPlaybackState.buffering);
    });

    // Startup buffering arrives from opening, never from playing.
    test('buffering at startup is left alone', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'buffering',
        'position': 1200,
      }, const VlcPlayerValue(state: VlcPlaybackState.opening));
      expect(value.state, VlcPlaybackState.buffering);
    });

    test('a backwards position after a seek is not treated as playing', () {
      final value = VlcPlayerValue.fromEvent(<String, Object?>{
        'state': 'buffering',
        'position': 5000,
      }, playing);
      expect(value.state, VlcPlaybackState.buffering);
    });

    test('paused, stopped and ended are never corrected', () {
      for (final name in const ['paused', 'stopped', 'ended']) {
        final value = VlcPlayerValue.fromEvent(<String, Object?>{
          'state': name,
          'position': 11000,
        }, playing);
        expect(value.state.name, name);
      }
    });
  });

  group('a held picture', () {
    const held = VlcPlayerValue(
      state: VlcPlaybackState.playing,
      videoSize: Size(1920, 1080),
      codedVideoSize: Size(1920, 1088),
      videoOrientation: VlcVideoOrientation.topLeft,
    );

    test('keeps its size through the new media\'s opening', () {
      final next = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'opening',
        'pictureHeld': true,
      }, held);

      expect(next.isPictureHeld, isTrue);
      expect(next.videoSize, const Size(1920, 1080));
      expect(next.codedVideoSize, const Size(1920, 1088));
      expect(next.videoOrientation, VlcVideoOrientation.topLeft);
    });

    test('ignores the new media\'s size until the hold ends', () {
      final during = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'playing',
        'pictureHeld': true,
        'videoSize': <String, Object?>{'width': 1280, 'height': 720},
        'codedSize': <String, Object?>{'width': 1280, 'height': 720},
      }, held);
      expect(during.videoSize, const Size(1920, 1080));
      expect(during.codedVideoSize, const Size(1920, 1088));

      final after = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'playing',
        'pictureHeld': false,
        'videoSize': <String, Object?>{'width': 1280, 'height': 720},
        'codedSize': <String, Object?>{'width': 1280, 'height': 720},
      }, during);
      expect(after.isPictureHeld, isFalse);
      expect(after.videoSize, const Size(1280, 720));
      expect(after.codedVideoSize, const Size(1280, 720));
    });

    test('a backend that never says it holds clears the size on opening, as '
        'before', () {
      final next = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'opening',
      }, held);

      expect(next.isPictureHeld, isFalse);
      expect(next.videoSize, isNull);
      expect(next.codedVideoSize, isNull);
    });
  });

  group('a held picture\'s media', () {
    // What a screen draws its controls from while it waits over the held
    // picture: the media before's, until the hold ends (FORK.md 33).
    const before = VlcPlayerValue(
      state: VlcPlaybackState.playing,
      position: Duration(minutes: 40),
      duration: Duration(minutes: 50),
      isSeekable: true,
      videoSize: Size(1920, 1080),
    );

    test('keeps the length, the seeking and the liveness while it opens', () {
      final opening = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'opening',
        'position': 0,
        'duration': 0,
        'isSeekable': false,
        'isLive': true,
        'pictureHeld': true,
      }, before);

      expect(opening.position, Duration.zero);
      expect(opening.duration, const Duration(minutes: 50));
      expect(opening.isSeekable, isTrue);
      expect(opening.isLive, isFalse);
    });

    test('takes a length and seeking the new media knows', () {
      final buffering = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'buffering',
        'duration': 3060000,
        'isSeekable': true,
        'pictureHeld': true,
      }, before.copyWith(isSeekable: false));

      expect(buffering.duration, const Duration(milliseconds: 3060000));
      expect(buffering.isSeekable, isTrue);
    });

    test('lets go of them with the hold', () {
      final played = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'playing',
        'position': 2400000,
        'duration': 0,
        'isSeekable': false,
        'isLive': true,
        'pictureHeld': false,
      }, before.copyWith(isPictureHeld: true));

      expect(played.isPictureHeld, isFalse);
      expect(played.duration, Duration.zero);
      expect(played.isSeekable, isFalse);
      expect(played.isLive, isTrue);
    });
  });

  test('an error keeps the size of the picture still on screen', () {
    // The output keeps showing a picture after a failure - a held one, or
    // the failed media's last - and a screen offers its retry over it.
    const playing = VlcPlayerValue(
      state: VlcPlaybackState.playing,
      videoSize: Size(1920, 1080),
      codedVideoSize: Size(1920, 1088),
      videoOrientation: VlcVideoOrientation.topLeft,
    );

    final failed = VlcPlayerValue.fromEvent(const <String, Object?>{
      'state': 'error',
    }, playing);

    expect(failed.state, VlcPlaybackState.error);
    expect(failed.videoSize, const Size(1920, 1080));
    expect(failed.codedVideoSize, const Size(1920, 1088));
    expect(failed.videoOrientation, VlcVideoOrientation.topLeft);
  });

  test('the wait for the video surface is read and kept', () {
    final waited = VlcPlayerValue.fromEvent(const <String, Object?>{
      'state': 'opening',
      'videoSurfaceWaitMs': 3200,
    }, const VlcPlayerValue());
    expect(waited.videoSurfaceWait, const Duration(milliseconds: 3200));

    final later = VlcPlayerValue.fromEvent(const <String, Object?>{
      'state': 'playing',
    }, waited);
    expect(later.videoSurfaceWait, const Duration(milliseconds: 3200));
  });

  group('the prebuffer', () {
    test('is kept while the media opens', () {
      final next = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'opening',
        'bufferingProgress': 0.4,
      }, const VlcPlayerValue());

      expect(next.bufferingProgress, 0.4);
    });

    test('is cleared once the media plays', () {
      final opening = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'opening',
        'bufferingProgress': 0.4,
      }, const VlcPlayerValue());
      final playing = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'playing',
      }, opening);

      expect(playing.bufferingProgress, isNull);
    });
  });

  group('the start gate', () {
    test('is read from Android\'s startGated', () {
      final gated = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'opening',
        'startGated': true,
      }, const VlcPlayerValue());
      expect(gated.isStartGated, isTrue);

      final started = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'buffering',
        'startGated': false,
      }, gated);
      expect(started.isStartGated, isFalse);
    });

    test('is false where a backend never says', () {
      final next = VlcPlayerValue.fromEvent(const <String, Object?>{
        'state': 'opening',
      }, const VlcPlayerValue(isStartGated: true));

      expect(next.isStartGated, isFalse);
    });

    test('takes part in equality, hashCode and copyWith', () {
      const value = VlcPlayerValue();
      final gated = value.copyWith(isStartGated: true);

      expect(value.isStartGated, isFalse);
      expect(gated, isNot(value));
      expect(gated.hashCode, isNot(value.hashCode));
      expect(gated.copyWith(isStartGated: false), value);
    });
  });
}
