import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'vlc_player_error.dart';

/// Playback lifecycle states reported by the native VLC player.
enum VlcPlaybackState {
  idle,

  opening,

  buffering,

  playing,

  paused,

  stopped,

  /// The current media reached the end.
  ended,

  error,
}

/// Why the system, rather than the viewer, changed playback.
///
/// The native side pauses or ducks in the same instant the OS takes audio
/// away, so this reports what already happened rather than requesting it. A
/// host that ignores it is still correct: [VlcPlayerValue.state] already says
/// `paused`.
enum VlcAudioInterruption {
  /// Nothing is interrupting playback.
  none,

  /// Audio went to another app for good, and playback is paused.
  ///
  /// Only the viewer restarts this one. Android reports it as
  /// `AUDIOFOCUS_LOSS`, iOS as an interruption that ended without advising a
  /// resume.
  focusLost,

  /// Audio went to something short-lived — typically a phone call — and
  /// playback is paused until it comes back.
  ///
  /// This is the only interruption the controller resumes from by itself.
  focusLostTransient,

  /// Something is talking over the top and playback continues, attenuated.
  ///
  /// Android only (`AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK`). The viewer's chosen
  /// [VlcPlayerValue.volume] is untouched: the attenuation is applied under it
  /// and lifted when the prompt finishes.
  ducked,

  /// The output device went away and playback is paused.
  ///
  /// Headphones pulled out, or Bluetooth dropped. Resuming would blare the
  /// film out of the phone speaker, so this never resumes on its own.
  becameNoisy,
}

/// How a video's stored frames are turned the right way up for display.
///
/// libVLC's own `libvlc_video_orient_t` values, in libVLC's order, so a native
/// side can send the raw integer and Dart can name it. Each name says where
/// the stored image's first row and column belong.
///
/// A clip shot in portrait is not stored in portrait: phone cameras record
/// landscape frames and write a rotation beside them, so the stored width and
/// height say landscape for a video the viewer holds upright. [swapsAxes]
/// resolves that.
enum VlcVideoOrientation {
  /// Already upright. Top row is the top, left column is the left.
  topLeft,

  /// Mirrored left to right.
  topRight,

  /// Mirrored top to bottom.
  bottomLeft,

  /// Turned upside down.
  bottomRight,

  /// Transposed — reflected along the leading diagonal.
  leftTop,

  /// Rotated 90 degrees. What a handset held upright records.
  leftBottom,

  /// Rotated 270 degrees. What a handset held upright and turned the other way
  /// records.
  rightTop,

  /// Anti-transposed — reflected along the trailing diagonal.
  rightBottom;

  /// Whether displaying this video exchanges its stored width and height.
  ///
  /// The four quarter-turn orientations do; the four that only flip or rotate
  /// by half a turn do not. This is libVLC's own `ORIENT_IS_SWAP` test from
  /// `include/vlc_es.h`, the fourth bit.
  ///
  /// Deliberately not the test libVLC's Android bindings use: `VideoHelper`
  /// checks `orientation == 5 || orientation == 6`, which is wrong for the two
  /// transposes.
  bool get swapsAxes => index & 4 != 0;
}

/// Immutable snapshot of the native player state.
///
/// Listen to `VlcPlayerController` to receive updated values as VLC emits
/// playback events.
@immutable
class VlcPlayerValue {
  /// Creates a player value snapshot.
  const VlcPlayerValue({
    this.state = VlcPlaybackState.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 100,
    this.playbackSpeed = 1,
    this.audioDelay = Duration.zero,
    this.subtitleDelay = Duration.zero,
    this.activeAudioTrackId,
    this.activeSubtitleTrackId,
    this.trackRevision = 0,
    this.isReady = false,
    this.isSeekable = false,
    this.isLive = false,
    this.isStalled = false,
    this.isPictureHeld = false,
    this.isStartGated = false,
    this.videoSurfaceWait,
    this.interruption = VlcAudioInterruption.none,
    this.videoSize,
    this.videoOrientation,
    this.codedVideoSize,
    this.bufferingProgress,
    this.positionFraction,
    this.error,
    this.errorDescription,
  });

  final VlcPlaybackState state;

  final Duration position;

  /// Current media duration, or [Duration.zero] when unknown.
  final Duration duration;

  /// Current volume on VLC's `0..200` scale, where `100` is normal.
  final int volume;

  /// Playback speed multiplier, where `1` is normal.
  final double playbackSpeed;

  /// Positive values delay audio; negative values play audio earlier.
  final Duration audioDelay;

  /// Positive values delay subtitles; negative values show subtitles earlier.
  final Duration subtitleDelay;

  /// The id of the audio track the engine is currently playing, or null when
  /// there is none.
  ///
  /// libVLC's `-1` "none" pseudo-id is normalised to null here, so no consumer
  /// has to compare against it; `0` is a legal track id. Ids are the native
  /// ids [VlcTrackDescription.id] carries. Every backend re-sends its snapshot
  /// after `setAudioTrack` and after each seek.
  final int? activeAudioTrackId;

  /// The id of the subtitle track the engine is currently rendering, or null
  /// when subtitles are off.
  ///
  /// Null is libVLC's `-1` normalised, as for [activeAudioTrackId]; `0` is a
  /// legal id. Re-sent by every backend after `setSubtitleTrack`,
  /// `disableSubtitle` and each seek, all of which are synchronous writes that
  /// read straight back.
  ///
  /// `addSubtitle` is the exception: libVLC 3 hands an added slave to the
  /// input thread rather than applying it inline, so the snapshot forced right
  /// after the call still describes the pre-add state. The side-car surfaces
  /// when the engine announces the new elementary stream, which is what moves
  /// [trackRevision]. Key off [trackRevision], never off the `addSubtitle`
  /// future.
  final int? activeSubtitleTrackId;

  /// A counter that moves whenever the engine's track list changes shape.
  ///
  /// Monotonic per player, starting at `0`, and bumped when the audio plus
  /// subtitle track set changes, not merely when its size changes: a same-size
  /// swap such as an adaptive rendition change is caught too. Android bumps on
  /// an audio or subtitle `ESAdded` / `ESDeleted` and deliberately not on a
  /// video-only one.
  ///
  /// Consumers that cache `getAudioTracks()` / `getSubtitleTracks()` results
  /// should refetch when this differs from the revision they fetched under,
  /// rather than polling. The number carries no meaning beyond "changed
  /// since".
  final int trackRevision;

  /// Whether the native player has reached a playable active or terminal state.
  final bool isReady;

  /// Whether VLC reports that the current media can seek.
  final bool isSeekable;

  /// Whether the current media looks like a live stream.
  final bool isLive;

  /// Whether playback has visibly stopped making progress while [state] still
  /// says it is running.
  ///
  /// The mid-play spinner signal, and deliberately not libVLC's state machine:
  /// libVLC 3 keeps reporting `playing` through a rebuffer on every platform
  /// but Android, so [isBuffering] can only describe the startup buffer. The
  /// controller watches the position clock instead and raises this once it has
  /// stood still for `VlcPlayerController.stallIndicatorDelay`. Only ever true
  /// while [state] is [VlcPlaybackState.playing] or
  /// [VlcPlaybackState.buffering].
  final bool isStalled;

  /// Whether the output still shows the last picture of the media before
  /// this one, held by a [VlcPlayerController.setMedia] given `keepPicture`.
  ///
  /// libVLC 3 shows a new media's first decoded picture at once. For a media
  /// asked to start at a position, that picture is the one at 0, decoded
  /// before the start is sought, so a reopen at a position would show the
  /// film's opening for as long as the seek takes: seconds on a slow link
  /// (SkyStream's reopen spike, 2026-10-14). The native output holds instead.
  ///
  /// Every backend that can hold reports the same decision (FORK.md 30). A
  /// hold starts only at a media given `keepPicture`, when there is a picture
  /// to hold, and carries on through further ones. It ends at the current
  /// media's first reported time after it opened - libVLC reports none until
  /// playback runs from the start position - or at once at a plain
  /// [VlcPlayerController.setMedia] or a stop. A media that fails, ends or is
  /// stopped before then leaves it on: the held picture is still the right
  /// one on screen.
  ///
  /// While it holds, [videoSize], [codedVideoSize] and [videoOrientation]
  /// stay the held picture's: the new media's own would lay the held picture
  /// out at the wrong shape. The timeline stays the media before's where the
  /// new media's says nothing yet: a zero [duration] keeps the length before,
  /// an [isSeekable] of false keeps the answer before, and [isLive] keeps
  /// its value. A media still opening knows no length and says it cannot
  /// seek, and a screen drawing its controls over the held picture would
  /// lose its scrubber for the whole reopen. Backends that cannot hold never
  /// set it.
  final bool isPictureHeld;

  /// Whether a play waits at the engine's start gate: Android holds a
  /// player's start while it builds libVLC's font database, which only the
  /// first video after an install needs (FORK.md 26). Up to a minute, with
  /// nothing wrong with the media meanwhile, so a host watching for a stall
  /// waits it out. False on every other backend.
  final bool isStartGated;

  /// How long the engine held playback back for its video surface, when it
  /// had to (Android: libvlc-android starts only once the view's surface
  /// exists). Null when it never waited; kept until a report says otherwise.
  final Duration? videoSurfaceWait;

  /// Why the system last interrupted playback, if it has.
  final VlcAudioInterruption interruption;

  /// Decoded video size when VLC exposes it.
  ///
  /// The elementary stream's stored width and height, which carries no
  /// rotation. Use [displayVideoSize] for anything that cares which way up the
  /// picture is.
  final Size? videoSize;

  /// The rotation the backend will apply to [videoSize] before showing it.
  ///
  /// Null when the backend does not report one, which is not the same as
  /// [VlcVideoOrientation.topLeft]: it means "unknown", and [displayVideoSize]
  /// falls back to another source rather than assuming upright.
  final VlcVideoOrientation? videoOrientation;

  /// The decoder's buffer size on a texture-backed player, when it differs
  /// from [videoSize].
  ///
  /// Decoders pad height to a multiple of 16, so a 1080p stream decodes into
  /// 1920x1088 with eight rows nobody writes, and unwritten NV12 is green. The
  /// texture is that whole buffer; the widget uses this to clip it back to the
  /// visible picture. Null for view-backed players, whose drawable already
  /// crops.
  final Size? codedVideoSize;

  /// The shape the picture is shown at, with rotation already resolved.
  ///
  /// Backends reach that answer by different routes, reconciled here so
  /// callers need not know which platform they are on. A reported
  /// [videoOrientation] (Android) is applied to [videoSize]; otherwise
  /// [codedVideoSize] is used, because libVLC's `vmem` output applies the
  /// rotation before negotiating that buffer, so its shape is already the
  /// upright picture's.
  ///
  /// Null when neither is available, and deliberately not [videoSize] as a
  /// last resort: a portrait clip and a landscape film are both 1920x1080
  /// there, so this says "unknown" rather than guessing. Also null before any
  /// size arrives, which is every backend's answer while the player is still
  /// opening.
  Size? get displayVideoSize {
    final stored = videoSize;
    final orientation = videoOrientation;
    if (orientation != null && stored != null) {
      return orientation.swapsAxes
          ? Size(stored.height, stored.width)
          : stored;
    }
    return codedVideoSize;
  }

  /// libVLC's prebuffer, from `0.0` to `1.0`: present while libVLC fills its
  /// buffer at the start, after a seek or after a track change, and null
  /// otherwise. It is information, not a spinner: a stream that starves
  /// mid-play just stops the clock, which [isStalled] reads.
  final double? bufferingProgress;

  /// libVLC's own place as a fraction of [duration], from `0.0` to `1.0`
  /// (`libvlc_media_player_get_position`), or null when the engine gave none.
  ///
  /// For live HLS and DASH it is the one reading relative to the window:
  /// [duration] is the window the server still lists and this is where
  /// playback is inside it, while [position] runs on in the stream's own
  /// timeline. See [VlcPlayerController.seekToWindowFraction].
  final double? positionFraction;

  /// Structured playback error when [state] is [VlcPlaybackState.error].
  final VlcPlayerError? error;

  /// Human-readable playback error text when available.
  final String? errorDescription;

  bool get isPlaying => state == VlcPlaybackState.playing;

  bool get isBuffering => state == VlcPlaybackState.buffering;

  bool get hasError => state == VlcPlaybackState.error;

  bool get isInterrupted => interruption != VlcAudioInterruption.none;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is VlcPlayerValue &&
        other.state == state &&
        other.position == position &&
        other.duration == duration &&
        other.volume == volume &&
        other.playbackSpeed == playbackSpeed &&
        other.audioDelay == audioDelay &&
        other.subtitleDelay == subtitleDelay &&
        other.activeAudioTrackId == activeAudioTrackId &&
        other.activeSubtitleTrackId == activeSubtitleTrackId &&
        other.trackRevision == trackRevision &&
        other.isReady == isReady &&
        other.isSeekable == isSeekable &&
        other.isLive == isLive &&
        other.isStalled == isStalled &&
        other.isPictureHeld == isPictureHeld &&
        other.isStartGated == isStartGated &&
        other.videoSurfaceWait == videoSurfaceWait &&
        other.interruption == interruption &&
        other.videoSize == videoSize &&
        other.videoOrientation == videoOrientation &&
        other.codedVideoSize == codedVideoSize &&
        other.bufferingProgress == bufferingProgress &&
        other.positionFraction == positionFraction &&
        other.error == error &&
        other.errorDescription == errorDescription;
  }

  @override
  // hashAll rather than hash: Object.hash takes at most twenty positional
  // arguments and this snapshot carries twenty-five fields.
  int get hashCode => Object.hashAll([
    state,
    position,
    duration,
    volume,
    playbackSpeed,
    audioDelay,
    subtitleDelay,
    activeAudioTrackId,
    activeSubtitleTrackId,
    trackRevision,
    isReady,
    isSeekable,
    isLive,
    isStalled,
    isPictureHeld,
    isStartGated,
    videoSurfaceWait,
    interruption,
    videoSize,
    videoOrientation,
    codedVideoSize,
    bufferingProgress,
    positionFraction,
    error,
    errorDescription,
  ]);

  /// Returns a copy with selected fields replaced.
  ///
  /// Set [clearVideoSize], [clearBufferingProgress], [clearError],
  /// [clearActiveAudioTrack], or [clearActiveSubtitleTrack] to remove
  /// nullable values that would otherwise be preserved from the current value.
  VlcPlayerValue copyWith({
    VlcPlaybackState? state,
    Duration? position,
    Duration? duration,
    int? volume,
    double? playbackSpeed,
    Duration? audioDelay,
    Duration? subtitleDelay,
    int? activeAudioTrackId,
    bool clearActiveAudioTrack = false,
    int? activeSubtitleTrackId,
    bool clearActiveSubtitleTrack = false,
    int? trackRevision,
    bool? isReady,
    bool? isSeekable,
    bool? isLive,
    bool? isStalled,
    bool? isPictureHeld,
    bool? isStartGated,
    Duration? videoSurfaceWait,
    VlcAudioInterruption? interruption,
    Size? videoSize,
    VlcVideoOrientation? videoOrientation,
    bool clearVideoSize = false,
    Size? codedVideoSize,
    double? bufferingProgress,
    bool clearBufferingProgress = false,
    double? positionFraction,
    bool clearPositionFraction = false,
    VlcPlayerError? error,
    String? errorDescription,
    bool clearError = false,
  }) {
    final nextError = clearError
        ? null
        : error ??
              (errorDescription == null
                  ? this.error
                  : VlcPlayerError(
                      code: VlcPlayerErrorCode.playbackError,
                      message: errorDescription,
                    ));
    final nextErrorDescription = clearError
        ? null
        : error != null
        ? error.message
        : errorDescription ?? this.errorDescription;
    return VlcPlayerValue(
      state: state ?? this.state,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      audioDelay: audioDelay ?? this.audioDelay,
      subtitleDelay: subtitleDelay ?? this.subtitleDelay,
      activeAudioTrackId: clearActiveAudioTrack
          ? null
          : activeAudioTrackId ?? this.activeAudioTrackId,
      activeSubtitleTrackId: clearActiveSubtitleTrack
          ? null
          : activeSubtitleTrackId ?? this.activeSubtitleTrackId,
      trackRevision: trackRevision ?? this.trackRevision,
      isReady: isReady ?? this.isReady,
      isSeekable: isSeekable ?? this.isSeekable,
      isLive: isLive ?? this.isLive,
      isStalled: isStalled ?? this.isStalled,
      isPictureHeld: isPictureHeld ?? this.isPictureHeld,
      isStartGated: isStartGated ?? this.isStartGated,
      videoSurfaceWait: videoSurfaceWait ?? this.videoSurfaceWait,
      interruption: interruption ?? this.interruption,
      videoSize: clearVideoSize ? null : videoSize ?? this.videoSize,
      // Cleared with videoSize: all three describe the same picture, and last
      // clip's rotation or coded size against fresh dimensions would clip
      // wrongly or open a landscape film sideways.
      videoOrientation: clearVideoSize
          ? null
          : videoOrientation ?? this.videoOrientation,
      codedVideoSize: clearVideoSize
          ? null
          : codedVideoSize ?? this.codedVideoSize,
      bufferingProgress: clearBufferingProgress
          ? null
          : bufferingProgress ?? this.bufferingProgress,
      positionFraction: clearPositionFraction
          ? null
          : positionFraction ?? this.positionFraction,
      error: nextError,
      errorDescription: nextErrorDescription,
    );
  }

  /// Converts a native event-channel payload into a player value.
  ///
  /// Unknown or malformed events leave [previous] unchanged.
  static VlcPlayerValue fromEvent(Object? event, VlcPlayerValue previous) {
    if (event is! Map) {
      return previous;
    }

    var state =
        _stateFromString(_stringValue(event['state'])) ?? previous.state;

    // libVLC's state machine cannot be taken at face value: VLCKit reports
    // `buffering` for the whole of healthy playback with `isPlaying` false,
    // and libVLC on Android emits a Buffering event on nearly every tick. An
    // advancing position cannot lie, so it corrects the enum here for every
    // platform and consumer.
    //
    // Narrow on purpose: only when playback was already running and the
    // position moved forward. A genuine buffer at startup arrives from
    // `opening`, and a genuine rebuffer does not advance the position.
    if (state == VlcPlaybackState.buffering &&
        previous.state == VlcPlaybackState.playing) {
      final position = _durationFromMilliseconds(event['position']);
      if (position != null && position > previous.position) {
        state = VlcPlaybackState.playing;
      }
    }
    final hasVideoSize = event.containsKey('videoSize');
    final videoSize = hasVideoSize ? _sizeFromMap(event['videoSize']) : null;
    final codedVideoSize = event.containsKey('codedSize')
        ? _sizeFromMap(event['codedSize'])
        : null;
    final videoOrientation = _orientationValue(event['videoOrientation']);
    // A held picture keeps the size it is shown at; see [isPictureHeld].
    final pictureHeld = _boolValue(event['pictureHeld']) ?? false;
    // And its media keeps the timeline the controls are drawn from until the
    // hold ends: a media still opening knows no length, says it cannot seek,
    // and is called live or not from those two (FORK.md 33).
    final duration = _durationFromMilliseconds(event['duration']);
    final isSeekable = _boolValue(event['isSeekable']);
    final hasBufferingProgress = event.containsKey('bufferingProgress');
    final bufferingProgress = hasBufferingProgress
        ? _normalizedProgress(event['bufferingProgress'])
        : null;
    // An absent key keeps the previous reading; libVLC's -1 (no media) or
    // anything else outside 0..1 clears it.
    final hasPositionFraction = event.containsKey('positionFraction');
    final positionFraction = hasPositionFraction
        ? _fractionValue(event['positionFraction'])
        : null;
    final error = _errorFromEvent(event);
    // An absent track key keeps the previous value; a present key that is not
    // a usable id - libVLC's -1 for "none/off" - clears it to null.
    final hasAudioTrack = event.containsKey('audioTrack');
    final audioTrack = _trackIdValue(event['audioTrack']);
    final hasSubtitleTrack = event.containsKey('subtitleTrack');
    final subtitleTrack = _trackIdValue(event['subtitleTrack']);

    // isStalled is deliberately not read from the event: no native backend can
    // report it, so it is carried over from [previous] and owned entirely by
    // the controller's position clock.
    return previous.copyWith(
      state: state,
      position: _durationFromMilliseconds(event['position']),
      duration: pictureHeld && duration == Duration.zero ? null : duration,
      volume: _intValue(event['volume']),
      playbackSpeed: _doubleValue(event['playbackSpeed']),
      audioDelay: _durationFromMicroseconds(event['audioDelay']),
      subtitleDelay: _durationFromMicroseconds(event['subtitleDelay']),
      activeAudioTrackId: audioTrack,
      clearActiveAudioTrack: hasAudioTrack && audioTrack == null,
      activeSubtitleTrackId: subtitleTrack,
      clearActiveSubtitleTrack: hasSubtitleTrack && subtitleTrack == null,
      trackRevision: _intValue(event['trackRevision']),
      isReady: _boolValue(event['isReady']) ?? _isReadyState(state),
      isSeekable: pictureHeld && isSeekable == false ? null : isSeekable,
      isLive: pictureHeld ? null : _boolValue(event['isLive']),
      interruption: _interruptionFromString(
        _stringValue(event['interruption']),
      ),
      videoSize: pictureHeld ? null : videoSize,
      videoOrientation: pictureHeld ? null : videoOrientation,
      codedVideoSize: pictureHeld ? null : codedVideoSize,
      clearVideoSize:
          !pictureHeld &&
          ((hasVideoSize && videoSize == null) || _clearsVideoSize(state)),
      isPictureHeld: pictureHeld,
      // Only Android has a start gate, and every snapshot it sends says.
      isStartGated: _boolValue(event['startGated']) ?? false,
      videoSurfaceWait: _durationFromMilliseconds(event['videoSurfaceWaitMs']),
      bufferingProgress: bufferingProgress,
      positionFraction: positionFraction,
      clearPositionFraction: hasPositionFraction && positionFraction == null,
      // The prebuffer is reported while a media opens as well as while it
      // rebuffers: libVLC fills its buffer before the first picture too.
      clearBufferingProgress:
          (hasBufferingProgress && bufferingProgress == null) ||
          (state != VlcPlaybackState.buffering &&
              state != VlcPlaybackState.opening),
      error: error,
      errorDescription: error?.message,
      clearError: error == null,
    );
  }

  /// libVLC's `libvlc_video_orient_t`, as an integer off the wire.
  ///
  /// Anything outside the eight documented values reads as null rather than
  /// being clamped to upright: a wrong rotation turns a handset the wrong way,
  /// while an absent one falls through to the next source in
  /// [VlcPlayerValue.displayVideoSize].
  static VlcVideoOrientation? _orientationValue(Object? value) {
    if (value is! num || !value.isFinite) {
      return null;
    }
    final index = value.round();
    if (index < 0 || index >= VlcVideoOrientation.values.length) {
      return null;
    }
    return VlcVideoOrientation.values[index];
  }

  static Duration? _durationFromMilliseconds(Object? value) {
    if (value is! num || value < 0 || !value.isFinite) {
      return null;
    }
    return Duration(milliseconds: value.round());
  }

  static Duration? _durationFromMicroseconds(Object? value) {
    if (value is! num || !value.isFinite) {
      return null;
    }
    return Duration(microseconds: value.round());
  }

  static Size? _sizeFromMap(Object? value) {
    if (value is! Map) {
      return null;
    }
    final width = _doubleValue(value['width']);
    final height = _doubleValue(value['height']);
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width, height);
  }

  static double? _fractionValue(Object? value) {
    if (value is! num || !value.isFinite || value < 0 || value > 1) {
      return null;
    }
    return value.toDouble();
  }

  static double? _normalizedProgress(Object? value) {
    if (value is! num || !value.isFinite) {
      return null;
    }
    return value.toDouble().clamp(0.0, 1.0).toDouble();
  }

  static VlcPlayerError? _errorFromEvent(Map<Object?, Object?> event) {
    final rawError = event['error'];
    if (rawError is Map) {
      return VlcPlayerError.fromMap(rawError.cast<Object?, Object?>());
    }

    final code = _stringValue(event['errorCode']);
    final description = _stringValue(event['errorDescription']);
    if (code == null && description == null) {
      return null;
    }
    return VlcPlayerError(
      code: code ?? VlcPlayerErrorCode.playbackError,
      message: description,
      details: event['errorDetails'],
    );
  }

  static bool _isReadyState(VlcPlaybackState state) {
    return switch (state) {
      VlcPlaybackState.playing ||
      VlcPlaybackState.paused ||
      VlcPlaybackState.stopped ||
      VlcPlaybackState.ended => true,
      _ => false,
    };
  }

  /// The states whose picture is gone, or about to be replaced; `opening`
  /// only without a hold (see [fromEvent]). Not an error: the output still
  /// shows a picture after a failure - a held one, or the failed media's
  /// last - and a screen offers its retry over it (FORK.md 33).
  static bool _clearsVideoSize(VlcPlaybackState state) {
    return switch (state) {
      VlcPlaybackState.idle || VlcPlaybackState.opening => true,
      _ => false,
    };
  }

  static String? _stringValue(Object? value) => value is String ? value : null;

  /// A native track id, or null for anything that is not one: libVLC's `-1`
  /// "none" pseudo-id, non-numeric junk, NaN. `0` is a valid id.
  static int? _trackIdValue(Object? value) =>
      value is num && value.isFinite && value >= 0 ? value.round() : null;

  static int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num && value.isFinite) {
      return value.round();
    }
    return null;
  }

  static double? _doubleValue(Object? value) {
    if (value is! num || !value.isFinite) {
      return null;
    }
    return value.toDouble();
  }

  static bool? _boolValue(Object? value) => value is bool ? value : null;

  /// An absent or unrecognised name leaves the current interruption alone.
  ///
  /// Only Android and iOS have an audio session to report on, so most events
  /// carry no interruption at all; reading that as "the interruption ended"
  /// would resume a film in the middle of a phone call.
  static VlcAudioInterruption? _interruptionFromString(String? value) {
    return switch (value) {
      'none' => VlcAudioInterruption.none,
      'focusLost' => VlcAudioInterruption.focusLost,
      'focusLostTransient' => VlcAudioInterruption.focusLostTransient,
      'ducked' => VlcAudioInterruption.ducked,
      'becameNoisy' => VlcAudioInterruption.becameNoisy,
      _ => null,
    };
  }

  static VlcPlaybackState? _stateFromString(String? value) {
    return switch (value) {
      'idle' => VlcPlaybackState.idle,
      'opening' => VlcPlaybackState.opening,
      'buffering' => VlcPlaybackState.buffering,
      'playing' => VlcPlaybackState.playing,
      'paused' => VlcPlaybackState.paused,
      'stopped' => VlcPlaybackState.stopped,
      'ended' => VlcPlaybackState.ended,
      'error' => VlcPlaybackState.error,
      _ => null,
    };
  }
}
