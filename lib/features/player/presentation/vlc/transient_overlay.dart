import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Something shown briefly over the video and then taken away - a seek toast,
/// the volume rail.
///
/// Owns its own hide timer so the widget that shows it never has to setState
/// to remove it. That is the whole point: a swipe-seek or a volume drag writes
/// here on every pointer move, and if those writes landed on the controls'
/// State the entire overlay - both bars, every button, the scrubber - would
/// rebuild at pointer rate. Here they reach one [TransientOverlay] and nothing
/// else.
class TransientValue<T extends Object> extends ValueNotifier<T?> {
  TransientValue() : super(null);

  Timer? _timer;

  /// Shows [value]. With [hideAfter] it clears itself; without, it stays until
  /// [clear] or [clearAfter] - the shape a drag wants, where the finger decides
  /// when the rail goes.
  void show(T value, {Duration? hideAfter}) {
    _timer?.cancel();
    _timer = null;
    this.value = value;
    if (hideAfter != null) _timer = Timer(hideAfter, clear);
  }

  /// Starts the clock on whatever is showing, for the end of a drag.
  void clearAfter(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, clear);
  }

  void clear() {
    _timer?.cancel();
    _timer = null;
    value = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// The one place a [TransientValue] is rendered.
///
/// Always in the tree and empty when idle, so the Stack that holds it never
/// changes shape. Its own [RepaintBoundary] because it sits over the video
/// surface: a toast appearing must not repaint the bars, and a bar repainting
/// must not touch the toast.
class TransientOverlay<T extends Object> extends StatelessWidget {
  const TransientOverlay({
    required this.value,
    required this.builder,
    super.key,
  });

  final ValueListenable<T?> value;
  final Widget Function(BuildContext context, T value) builder;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: IgnorePointer(
        child: ValueListenableBuilder<T?>(
          valueListenable: value,
          builder: (context, current, _) => current == null
              ? const SizedBox.shrink()
              : builder(context, current),
        ),
      ),
    );
  }
}

/// The brief centred message: a seek delta, a speed, the resize mode.
///
/// [alignment] exists for one reason: where the touch build puts a big centred
/// play/pause over the video, dead centre is taken, and a toast landing on the
/// disc is unreadable. The caller nudges it up rather than hiding the glyph
/// for the length of a drag - a setState at pointer rate is exactly what this
/// file exists to avoid.
class PlayerToast extends StatelessWidget {
  const PlayerToast(
    this.message, {
    this.alignment = Alignment.center,
    super.key,
  });

  final String message;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Text(
            message,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// What a double-tap seek has to say: which half of the screen fired, and how
/// far the whole chain of taps has moved playback.
///
/// [revision] is bumped on every press. It is what tells [PlayerSeekBurst] to
/// replay its ripple when the same direction is tapped twice in a row and
/// nothing else about the value changed - a new outer `Key` would do it too,
/// but that remounts the State and throws away the ticker mid-animation.
@immutable
class SeekBurst {
  const SeekBurst({
    required this.forward,
    required this.seconds,
    required this.revision,
  });

  /// The half that was tapped, not the sign of [seconds]: saying *which side
  /// fired* is the whole point of this readout.
  final bool forward;

  /// The cumulative offset of the seek chain, measured in the direction that
  /// was tapped. Negative only in the odd case where a reversal has carried
  /// the chain back past where it started, and then the minus sign is the
  /// honest thing to show.
  final int seconds;

  final int revision;

  @override
  bool operator ==(Object other) =>
      other is SeekBurst &&
      other.forward == forward &&
      other.seconds == seconds &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(forward, seconds, revision);
}

/// The double-tap seek readout, drawn on the half of the screen that was
/// tapped.
///
/// Replaces a screen-centred pill that was byte-identical to the swipe pill,
/// the 2x pill and the resize pill: nothing about it said which half of the
/// frame had been tapped, or even that a tap - rather than a swipe - was what
/// had happened.
///
/// Deliberately *not* YouTube's half-screen semicircular wash. Over the
/// macOS/iOS platform view a wash that size is a window-scale effect layer,
/// which is the IOSurface churn [TransientOverlay]'s owner documents and which
/// controls_layer_shape_test forbids outright. What is here is a bounded disc
/// inside a fixed square: alpha and transform only, no filters, and its paint
/// bounds never exceed [_maxSide].
class PlayerSeekBurst extends StatefulWidget {
  const PlayerSeekBurst({
    required this.forward,
    required this.seconds,
    this.revision = 0,
    super.key,
  });

  final bool forward;
  final int seconds;

  /// See [SeekBurst.revision].
  final int revision;

  /// Off-centre by 0.62 so the burst sits over the half it belongs to and well
  /// clear of the centre play/pause disc.
  static const double alignmentX = 0.62;

  static const Duration rippleDuration = Duration(milliseconds: 320);

  static const double _maxSide = 176;

  @override
  State<PlayerSeekBurst> createState() => _PlayerSeekBurstState();
}

class _PlayerSeekBurstState extends State<PlayerSeekBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: PlayerSeekBurst.rippleDuration,
  );

  @override
  void initState() {
    super.initState();
    _ripple.forward();
  }

  @override
  void didUpdateWidget(covariant PlayerSeekBurst oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same widget, new press: replay rather than remount.
    if (oldWidget.revision != widget.revision) _ripple.forward(from: 0);
  }

  @override
  void dispose() {
    // Before super.dispose(), so the ticker is already stopped when
    // SingleTickerProviderStateMixin checks it - a burst is routinely still
    // animating when the route goes.
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double side = math.min(
      MediaQuery.sizeOf(context).shortestSide * 0.44,
      PlayerSeekBurst._maxSide,
    );
    return Align(
      alignment: Alignment(
        widget.forward
            ? PlayerSeekBurst.alignmentX
            : -PlayerSeekBurst.alignmentX,
        0,
      ),
      // No `label:` literal here: the seconds are already spoken by the
      // scrubber's own announcement, and a hardcoded label in this package is
      // what test/l10n/hardcoded_strings_test.dart exists to stop.
      child: ExcludeSemantics(
        child: SizedBox.square(
          dimension: side,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // The ripple. A scale transform over a solid disc whose alpha
              // fades out - no opacity layer, so nothing here is composited
              // separately over the video.
              AnimatedBuilder(
                animation: _ripple,
                builder: (context, _) {
                  final double t = Curves.easeOutCubic.transform(_ripple.value);
                  return Transform.scale(
                    scale: 0.55 + 0.45 * t,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.22 * (1 - t)),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  );
                },
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    widget.forward
                        ? Icons.keyboard_double_arrow_right_rounded
                        : Icons.keyboard_double_arrow_left_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                  Text(
                    '${widget.seconds}s',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      // So a chain ticking 10 -> 20 -> 30 does not jitter.
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
