import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../skip/data/skip_service.dart';
import '../../domain/live_window.dart';
import '../widgets/player_stream_widgets.dart';

/// The seek bar for the VLC engine.
///
/// Thin by design: it holds only the drag position, and renders through the
/// shared [PlayerScrubber], so the overlay cannot drift from the design the
/// other engine gets.
///
/// It listens to the controller directly rather than through Riverpod, so a
/// position tick rebuilds this widget and nothing above it.
///
/// A seek on its way: the controller keeps publishing the engine's own
/// position - a faked one would poison the resume point writer - and libVLC
/// reports the place it left until the new one has been reached and
/// refilled, which on a slow network file is seconds. The thumb shows the
/// controller's [VlcPlayerController.pendingSeekTarget] in its place, from
/// the moment any seek is asked for - this bar's, a double tap, a D-pad step,
/// the skip chip - until the engine arrives, the way Media3 and the browsers
/// report a seek. A slow one shows the spinner over a thumb that is still on
/// the target. Relative D-pad steps chain from the target as a side effect,
/// because the bar reads its start value from what is displayed.
class VlcProgressBar extends StatefulWidget {
  const VlcProgressBar({
    this.bufferedFraction,
    required this.controller,
    this.isTv = false,
    this.isLive = false,
    this.skipSegments = const <SkipSegment>[],
    this.displayPosition,
    this.focusNode,
    this.onSeekStart,
    this.onSeekEnd,
    this.liveSegment,
    this.onLiveSeek,
    super.key,
  });

  final VlcPlayerController controller;

  /// How much of the media has been fetched ahead of the playhead, 0..1.
  ///
  /// A notifier so a stats sample repaints the band alone. Null on hosts that
  /// do not measure it, and the band then stays empty.
  final ValueListenable<double>? bufferedFraction;

  /// Ten-foot sizing, passed straight to [PlayerScrubber], where the numbers
  /// live.
  final bool isTv;

  /// Decided by the app from the item and URL, not by the engine.
  ///
  /// libVLC derives its own `isLive` as "no duration and not seekable", which
  /// is false for any live stream with a DVR window: those report a
  /// `timeShiftBufferDepth` and are seekable, so the engine calls them VOD and
  /// the bar renders an absolute timeline over the shift window. The app knows
  /// better from the manifest and the content type.
  final bool isLive;

  /// Painted as bands on the track so the viewer can see an intro coming.
  final List<SkipSegment> skipSegments;

  /// Where this bar publishes the position it is *showing*, for a clock drawn
  /// outside it.
  ///
  /// Not the engine's position: the two disagree for the length of a drag
  /// and while a seek is on its way. A clock reading the controller directly
  /// would sit at the old time while the thumb stood at the new one, which is
  /// exactly what a viewer reads as a seek that did not take.
  ///
  /// Owned by the caller and written here, the way the screen owns the lock
  /// notifier the controls write. Null where nothing outside draws a clock.
  final ValueNotifier<Duration>? displayPosition;

  final FocusNode? focusNode;

  /// Called when a drag begins, so the overlay can hold its chrome open.
  final VoidCallback? onSeekStart;

  /// Called with the position handed to the engine, so the overlay can restart
  /// its hide timer and count its next relative step from the seek that just
  /// happened rather than from the one it made itself. Fires for a pointer
  /// release and for a D-pad burst, whose Left/Right presses the bar coalesces
  /// into one seek.
  ///
  /// Exactly one end follows each [onSeekStart], with a null target when the
  /// bar gave the seek up instead of committing it: the overlay holds its
  /// chrome open between the two, and a start with no end pins the bars up for
  /// the rest of the session.
  final void Function(Duration? target)? onSeekEnd;

  /// A live stream's target duration, which sets the stretch of its window
  /// the bar offers; null assumes [kAssumedTargetDuration].
  final Duration? liveSegment;

  /// Seeks a live stream to a fraction of its window. Null asks the
  /// controller directly ([VlcPlayerController.seekToWindowFraction]).
  final ValueChanged<double>? onLiveSeek;

  @override
  State<VlcProgressBar> createState() => _VlcProgressBarState();
}

class _VlcProgressBarState extends State<VlcProgressBar> {
  /// Set only while the user is dragging. The engine keeps reporting its own
  /// position during a scrub, and showing that would fight the thumb.
  Duration? _dragTo;

  /// Whether [VlcProgressBar.onSeekStart] has been reported without its end.
  bool _seeking = false;

  @override
  void initState() {
    super.initState();
    _listen(widget.controller);
    // The clock's own seed covers the frame this runs after; this is what
    // corrects it if the bar was handed a notifier another controller filled.
    _publishAfterFrame();
  }

  void _listen(VlcPlayerController controller) {
    controller.addListener(_publish);
    controller.pendingSeekTarget.addListener(_onSeekTarget);
  }

  void _stopListening(VlcPlayerController controller) {
    controller.removeListener(_publish);
    controller.pendingSeekTarget.removeListener(_onSeekTarget);
  }

  /// The position this bar is showing: the finger, then a seek the engine has
  /// not arrived at, then the engine. The one rule, so [build] and
  /// [VlcProgressBar.displayPosition] cannot answer differently.
  ///
  /// A target needs a length to be drawn against; with none, the media under
  /// the controller has changed and the target was the old one's.
  ///
  /// On a live stream with a window, the same three, counted from the
  /// window's start.
  Duration get _shown {
    final value = widget.controller.value;
    final target = value.duration > Duration.zero
        ? widget.controller.pendingSeekTarget.value
        : null;
    final window = _window(value);
    if (window == null) return _dragTo ?? target ?? value.position;
    final dragged = _dragTo;
    if (dragged != null) return dragged;
    final start = value.position - window.length * window.fraction;
    final at = (target ?? value.position) - start;
    if (at < Duration.zero) return Duration.zero;
    return at > window.length ? window.length : at;
  }

  /// The window a live stream can be moved in, or null: not live, or a feed
  /// with no window (spec section 8).
  LiveWindow? _window(VlcPlayerValue value) => widget.isLive
      ? LiveWindow.of(value, targetDuration: widget.liveSegment)
      : null;

  /// A seek was asked for, or arrived: the thumb and the clock move with it.
  /// Both are outside a build - [VlcPlayerController.seekTo] and the
  /// controller's own notifications - so a setState is owed.
  void _onSeekTarget() {
    if (!mounted) return;
    setState(() {});
    _publish();
  }

  /// Hands the current answer to the outside clock.
  ///
  /// Called from every place that changes one of the three inputs, and all of
  /// them are outside a build - a gesture callback, the controller's
  /// notification, a timer - so notifying listeners here can never be a write
  /// during build.
  void _publish() {
    if (!mounted) return;
    widget.displayPosition?.value = _shown;
  }

  /// [_publish], for the callers that run inside a build.
  ///
  /// A notifier written during a build rebuilds its listeners during that same
  /// build, and the clock is one of them. [didUpdateWidget] is the only such
  /// caller, and a frame of the outgoing engine's position on the way into a
  /// new one costs nothing.
  void _publishAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  @override
  void didUpdateWidget(VlcProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    _stopListening(oldWidget.controller);
    _listen(widget.controller);
    // New media, new engine: a seek on its way was the old one's, and the new
    // controller has none of its own yet.
    _endSeek(null);
    _publishAfterFrame();
  }

  @override
  void dispose() {
    _stopListening(widget.controller);
    // A drag or a D-pad burst this bar opened never gets its end once the
    // bar is gone - the lock takes it away under a finger - and the controls'
    // seek hold would stay up, hiding the spinner. Told after this frame:
    // the controls rebuild, which they can't inside this unmount.
    if (_seeking) {
      _seeking = false;
      final onSeekEnd = widget.onSeekEnd;
      if (onSeekEnd != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => onSeekEnd(null));
      }
    }
    super.dispose();
  }

  /// Reports the start of a drag or a D-pad burst, at most once per seek.
  void _beginSeek() {
    if (_seeking) return;
    _seeking = true;
    widget.onSeekStart?.call();
  }

  /// Reports the end of the seek [_beginSeek] opened - [target] committed, or
  /// null if it was given up - and never twice for the same one.
  void _endSeek(Duration? target) {
    if (!_seeking) return;
    _seeking = false;
    widget.onSeekEnd?.call(target);
  }

  /// Reports the end of a seek this bar can no longer commit, and lets the
  /// frozen thumb go with it.
  ///
  /// [PlayerScrubber] nulls `onChangeEnd` the frame `canSeek` goes false, so
  /// the end the burst was promised can never arrive from below - which
  /// happens on every failover, recovery and episode advance, where the
  /// duration drops back to zero under the finger.
  void _abandonSeek() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_dragTo != null) setState(() => _dragTo = null);
      _endSeek(null);
      _publish();
    });
  }

  /// Hands [target] to the engine, which publishes it as the seek on its way
  /// - see [_shown].
  void _commitSeek(Duration target) {
    widget.controller.seekTo(target);
    setState(() => _dragTo = null);
    _publish();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VlcPlayerValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final listenable = widget.bufferedFraction;
        if (listenable == null) return _body(value, 0);
        return ValueListenableBuilder<double>(
          valueListenable: listenable,
          builder: (context, buffered, _) => _body(value, buffered),
        );
      },
    );
  }

  Widget _body(VlcPlayerValue value, double buffered) {
    final window = _window(value);
    if (window != null) return _liveBody(window);
    final duration = value.duration;
    final hasDuration = duration > Duration.zero;
    // Live is a verdict - the app's or the engine's, which every native
    // computes as playing/paused && no length && not seekable. A length
    // that has not arrived yet is not a verdict: seekable media with an
    // unknown duration keeps its scrubber until the engine reports one.
    final isLive = widget.isLive || value.isLive;
    // Drag, track tap and D-pad steps on the bar need a scale.
    final canSeek = !isLive && value.isSeekable && hasDuration;
    if (!canSeek && _seeking) _abandonSeek();

    return PlayerScrubber(
      // The finger, then the seek the engine has not arrived at, then the
      // engine. The clock reads the same value, so it follows too - wherever
      // it is drawn. See [_shown].
      position: _shown,
      duration: duration,
      hasDuration: hasDuration,
      // libVLC reports buffering as a 0..100 percentage of the current
      // fill operation, not of the media, and it sits at 100 during steady
      // playback, so the band stays empty until there is a real figure.
      bufferRatio: buffered,
      canSeek: canSeek,
      isLive: isLive,
      skipSegments: widget.skipSegments,
      isTv: widget.isTv,
      focusNode: widget.focusNode,
      onChangeStart: (ms) {
        _beginSeek();
        setState(() => _dragTo = Duration(milliseconds: ms.round()));
        _publish();
      },
      onChanged: (ms) {
        setState(() => _dragTo = Duration(milliseconds: ms.round()));
        _publish();
      },
      onChangeEnd: (ms) {
        final target = Duration(milliseconds: ms.round());
        _commitSeek(target);
        _endSeek(target);
      },
    );
  }

  /// The bar over a live window: it spans the window with live at its right
  /// end, and only the stretch libVLC will play from can be picked. A release
  /// goes to the engine as a fraction of the window.
  Widget _liveBody(LiveWindow window) {
    final lengthMs = window.length.inMilliseconds;
    Duration within(double ms) => Duration(
      milliseconds: ms
          .clamp(window.startFraction * lengthMs, window.endFraction * lengthMs)
          .round(),
    );
    return PlayerScrubber(
      position: _shown,
      duration: window.length,
      // libVLC keeps nothing it has played, so there is no band to show.
      bufferRatio: 0,
      canSeek: true,
      isTv: widget.isTv,
      focusNode: widget.focusNode,
      onChangeStart: (ms) {
        _beginSeek();
        setState(() => _dragTo = within(ms));
        _publish();
      },
      onChanged: (ms) {
        setState(() => _dragTo = within(ms));
        _publish();
      },
      onChangeEnd: (ms) {
        final fraction = within(ms).inMilliseconds / lengthMs;
        final seek = widget.onLiveSeek;
        if (seek != null) {
          seek(fraction);
        } else {
          widget.controller.seekToWindowFraction(fraction);
        }
        setState(() => _dragTo = null);
        _publish();
        // A place in the window is not a position the overlay can count its
        // next step from: it steps from the seek on its way instead.
        _endSeek(null);
      },
    );
  }
}
