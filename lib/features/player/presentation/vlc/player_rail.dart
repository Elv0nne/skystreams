import 'package:flutter/material.dart';

import '../widgets/hotstar_player_style.dart';

/// The vertical brightness / volume indicator shown while dragging.
///
/// Kept deliberately dumb: it renders a value someone else owns. The gesture
/// that changes it, the engine call and the timer that hides it all live in the
/// controls, so this cannot become a second owner of player state — which is
/// what the old player's gesture handler became.
class PlayerRail extends StatelessWidget {
  const PlayerRail({
    required this.icon,
    required this.value,
    required this.label,
    this.onLeft = true,
    this.boostFrom,
    super.key,
  });

  /// The track, the white level and the boost on top of it, for tests.
  static const Key trackKey = ValueKey<String>('player-rail-track');
  static const Key levelKey = ValueKey<String>('player-rail-level');
  static const Key boostKey = ValueKey<String>('player-rail-boost');

  static const double _trackHeight = 132;

  final IconData icon;

  /// 0..1 of the track, already normalised by the caller. Volume can exceed
  /// 100%, so this is the fraction of the *maximum*, not of 100%.
  final double value;

  /// Text shown above the track, e.g. `140%`.
  final String label;

  /// Which edge the rail is drawn against.
  ///
  /// Volume on the left, brightness on the right — fixed, not a reflection of
  /// which edge the drag began on. The two edges are configurable, so a viewer
  /// can put volume on both of them or on neither, and a rail that followed
  /// the finger would then be the same rail in two places or in a place the
  /// setting had moved. A fixed side is one a viewer learns once, and it is
  /// also the side each of them was on before the engine rewrite.
  final bool onLeft;

  /// Where the volume's boost starts, 0..1 of the track - 100 % of the
  /// maximum - or null where there is none (brightness, a maximum of 100 %).
  ///
  /// As VLC's player draws it: the level is white up to here, and the share of
  /// it above, which libVLC amplifies, is orange on top.
  final double? boostFrom;

  @override
  Widget build(BuildContext context) {
    final filled = value.clamp(0.0, 1.0);
    final from = boostFrom?.clamp(0.0, 1.0);
    // The white level stops where the boost starts; the rest is the boost's.
    final level = from == null || filled <= from ? filled : from;
    final boost = filled - level;
    return Align(
      alignment: onLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        // 12 inside the chrome's side inset, which clears a notch or camera
        // cutout on either side.
        padding: EdgeInsets.only(
          left: onLeft ? HotstarPlayerStyle.sideInsetOf(context) + 12 : 0,
          right: onLeft ? 0 : HotstarPlayerStyle.sideInsetOf(context) + 12,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: HotstarPlayerStyle.primaryText,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  key: trackKey,
                  width: 6,
                  height: _trackHeight,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Stack(
                      children: [
                        const Positioned.fill(
                          child: ColoredBox(
                            color: HotstarPlayerStyle.trackInactive,
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: _trackHeight * level,
                          child: const ColoredBox(
                            key: levelKey,
                            color: HotstarPlayerStyle.primaryText,
                          ),
                        ),
                        if (boost > 0)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: _trackHeight * level,
                            height: _trackHeight * boost,
                            child: const ColoredBox(
                              key: boostKey,
                              color: HotstarPlayerStyle.volumeBoost,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Icon(icon, color: HotstarPlayerStyle.primaryText, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
