import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/widgets/hotstar_player_style.dart';

/// The bottom bar's clock, labels and scrubber sit on the video with only the
/// scrim under them, so they have to read over the brightest scene there is:
/// white. WCAG asks 4.5:1 for text (1.4.3) and 3:1 for the track (1.4.11).
void main() {
  const white = Color(0xFFFFFFFF);
  final scrim = HotstarPlayerStyle.bottomGradient.colors;

  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  /// [ink] on the scene darkened by the scrim's [stop].
  double over(Color ink, int stop) {
    final scene = Color.alphaBlend(scrim[stop], white);
    return contrast(Color.alphaBlend(ink, scene), scene);
  }

  test('the clock reads even halfway up the bar', () {
    expect(over(HotstarPlayerStyle.primaryText, 1), greaterThanOrEqualTo(4.5));
  });

  test('the muted labels read at the bar', () {
    expect(over(HotstarPlayerStyle.mutedText, 0), greaterThanOrEqualTo(4.5));
  });

  test('the unplayed track shows at the bar', () {
    expect(
      over(HotstarPlayerStyle.trackInactive, 0),
      greaterThanOrEqualTo(3.0),
    );
  });
}
