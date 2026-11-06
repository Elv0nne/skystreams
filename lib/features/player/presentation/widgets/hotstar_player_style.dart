import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Visual and layout tokens for the player chrome: colors, motion, gradients,
/// and the layout metrics the chrome, subtitle offset and floating prompts
/// all share.
class HotstarPlayerStyle {
  // --- Colors ---
  static const Color background = Color(0xFF000000);
  static const Color panel = Color(0xFF05070B);
  static const Color panelElevated = Color(0xFF090D14);
  static const Color accent = Color(0xFF0A84FF);
  static const Color hotstar = Color(0xFF1F80E0);
  static const Color accentAlt = Color(0xFFDD3EFF);
  static const Color primaryText = Color(0xF2FFFFFF);
  static const Color secondaryText = Color(0xA6FFFFFF);

  /// Status on the panel's rows, in muted tones: they mark a row without
  /// competing with its label, and the row's icon says the same thing for
  /// whoever does not tell the colours apart.
  static const Color statusGood = Color(0xFF8DBAA0);
  static const Color statusWarning = Color(0xFFC5AD83);
  static const Color statusBad = Color(0xFFCF9292);

  /// A badge that is information, not a status: an episode's dub or sub.
  static const Color badgeNeutral = Color(0xFFA0ADC5);

  /// Quiet labels over the video, using the control surface's charcoal tone.
  static const BoxDecoration tooltipDecoration = BoxDecoration(
    color: Color(0xE620252B),
    borderRadius: BorderRadius.all(Radius.circular(6)),
  );
  static const TextStyle tooltipTextStyle = TextStyle(
    color: Color(0xDEFFFFFF),
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.25,
    letterSpacing: 0.1,
  );

  /// The smallest type in the chrome: panel secondary lines, torrent stats,
  /// the countdown's caption. Alpha 0x75 is the first step that clears WCAG AA
  /// against the black under the scrim (4.56:1); 0x73 measured 4.43:1.
  static const Color mutedText = Color(0x75FFFFFF);
  static const Color divider = Color(0x1FFFFFFF);
  static const Color track = Color(0x55FFFFFF);

  /// Unfilled part of a progress track - the next-episode ring and the
  /// torrent progress bar. It tells a viewer how much is left, so it is a UI
  /// component under WCAG 1.4.11 and owes 3:1; 0x5C measures 3.14:1.
  static const Color trackInactive = Color(0x5CFFFFFF);
  static const Color focus = Color(0x660A84FF);
  static const Color liveRed = Color(0xFFE53935);

  /// The focus ring, everywhere in the player chrome.
  ///
  /// White, not [accent], and the same decision the rest of the app made in
  /// `shared/focus/app_focus.dart`: the chrome sits over a picture that can be
  /// any colour, and an accent ring competes with it while a white one reads
  /// on anything. It also keeps the accent meaning one thing - this control is
  /// *on* - rather than two.
  static const Color focusRing = Color(0xFFFFFFFF);

  /// Ring thickness. Matches the app's [AppFocus.ringWidth].
  static const double focusRingWidth = 2;

  /// The wash behind a focused control. Neutral for the same reason the ring
  /// is, and low enough not to lift a control off a bright scene.
  static const Color focusFill = Color(0x26FFFFFF);

  /// Marker on the scrubber for skip segments (intro / recap / outro). A warm
  /// amber so it reads clearly against the blue progress and grey track.
  static const Color skipSegment = Color(0xFFFFC107);

  /// The volume rail above 100 %, where libVLC amplifies: VLC's player draws
  /// its boost in this orange (its `orange700`).
  static const Color volumeBoost = Color(0xFFF57C00);

  // --- Motion ---
  static const Duration controlFadeDuration = Duration(milliseconds: 220);
  static const Duration fastMotionDuration = Duration(milliseconds: 160);
  static const Duration panelMotionDuration = Duration(milliseconds: 240);

  // --- Layout tokens ---
  /// Horizontal edge inset for the chrome, the same on every device: one
  /// player layout wherever it runs.
  static const double edgeInset = 16;

  /// Kept clear of a television's edges by the Options drawer: many sets cut
  /// off about 5 % of the picture (overscan), and the drawer's close button
  /// and every row's badges would sit in that band. The controls do not use
  /// it; their inset is [edgeInset] on every device.
  static const double tvOverscanInset = 48;

  /// How far the scrubber's painted track is held inside the chrome's edge
  /// inset, and with it everything that lines up against the track: the
  /// control line's pills, the Back button's arrow, and every floating overlay
  /// anchored to the same edge - the resume hint on the left, the up-next card
  /// and the skip chip on the right.
  ///
  /// The arrow's ink starts about this far into its button, so the track and
  /// the pills, held in by the same amount, start where the arrow does.
  static const double trackInset = 16;

  /// The same at the far end: the pills' edges are the line's ends there too.
  static const double trackEndInset = trackInset;

  /// How far the chrome stays from each side of the screen: [edgeInset], or
  /// the safe inset of a notch or camera cutout where that is larger.
  ///
  /// The larger of the two sides, on both, as iOS reports them in landscape.
  /// Android reports a cutout on its own side only, and padding just that
  /// side would push the controls off the centre of a centred picture and
  /// move them across the screen whenever the phone is turned the other way
  /// up. The picture itself still runs under the cutout.
  static double sideInsetOf(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    return math.max(edgeInset, math.max(padding.left, padding.right));
  }

  /// The vertical line the whole player answers to on each side: the side
  /// inset plus the track's.
  static double lineOf(BuildContext context) =>
      sideInsetOf(context) + trackInset;

  /// Height of the bottom chrome on a phone, a tablet or a desktop window,
  /// excluding the safe-area bottom inset.
  ///
  /// A ceiling, not an average, because everything anchored off a number
  /// smaller than the bar's real height lands *on* the bar. Measured: 88 dp on
  /// a handset, where the transport cluster is in the middle of the frame, and
  /// 88 on a desktop window too, whose play/pause is in the bar at the height
  /// of every other button.
  /// `controls_focus_test` holds the real bar under this on every form factor
  /// - raise this rather than the overlays if a row ever grows.
  ///
  /// It came down from 148 when the clock moved off the scrubber and into the
  /// transport row: the bar lost a whole text row, and the overlays were
  /// holding a band of empty video above it.
  ///
  /// Still not a clamp: a large text scale can push the bar past it, and the
  /// overlays would rather ride a little high than be clipped.
  static const double bottomChromeHeight = 108;

  /// The same on a television, where every rung of the ramp is bigger and the
  /// bar measures 100 dp.
  ///
  /// Its own number rather than one ceiling over both, because a single value
  /// would have to clear the ten-foot bar and would then float every handset
  /// overlay 24 dp above nothing.
  static const double tvBottomChromeHeight = 112;

  /// The clearance for this form factor. Every overlay that floats above the
  /// bottom bar asks this rather than picking one of the two.
  static double bottomChromeHeightFor({required bool isTv}) =>
      isTv ? tvBottomChromeHeight : bottomChromeHeight;

  /// Focus-ring scale shared by every focusable control, so play/pause, seek,
  /// scrubber, action and utility buttons look identical when focused.
  static const double focusScale = 1.04;

  // --- Gradients ---
  static const LinearGradient topGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xCC000000), Color(0x66000000), Color(0x00000000)],
    stops: [0.0, 0.55, 1.0],
  );

  static const LinearGradient bottomGradient = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: [Color(0xE6000000), Color(0x99000000), Color(0x00000000)],
    stops: [0.0, 0.5, 1.0],
  );
}
