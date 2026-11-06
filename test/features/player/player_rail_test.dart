import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/vlc/player_rail.dart';
import 'package:skystream/features/player/presentation/widgets/hotstar_player_style.dart';

/// The volume and brightness rail. The volume's boost - the part above 100 %,
/// which libVLC amplifies - is drawn in orange on top of the white level, as
/// VLC's player draws it.
void main() {
  Future<void> pump(WidgetTester tester, PlayerRail rail) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(backgroundColor: Colors.black, body: rail),
    ),
  );

  Rect rectOf(WidgetTester tester, Key key) => tester.getRect(find.byKey(key));

  Color colorOf(WidgetTester tester, Key key) =>
      tester.widget<ColoredBox>(find.byKey(key)).color;

  testWidgets('a boost fills its share of the track in orange, on top of the '
      'level', (tester) async {
    await pump(
      tester,
      const PlayerRail(
        icon: Icons.volume_up_rounded,
        value: 0.75,
        label: '150%',
        boostFrom: 0.5,
      ),
    );
    final track = rectOf(tester, PlayerRail.trackKey);
    final level = rectOf(tester, PlayerRail.levelKey);
    final boost = rectOf(tester, PlayerRail.boostKey);

    expect(level.height, moreOrLessEquals(track.height * 0.5, epsilon: 0.5));
    expect(level.bottom, moreOrLessEquals(track.bottom, epsilon: 0.5));
    expect(
      colorOf(tester, PlayerRail.levelKey),
      HotstarPlayerStyle.primaryText,
    );
    expect(boost.height, moreOrLessEquals(track.height * 0.25, epsilon: 0.5));
    expect(boost.bottom, moreOrLessEquals(level.top, epsilon: 0.5));
    expect(
      colorOf(tester, PlayerRail.boostKey),
      HotstarPlayerStyle.volumeBoost,
    );
  });

  testWidgets('under the boost, the level is all white', (tester) async {
    await pump(
      tester,
      const PlayerRail(
        icon: Icons.volume_down_rounded,
        value: 0.4,
        label: '80%',
        boostFrom: 0.5,
      ),
    );
    final track = rectOf(tester, PlayerRail.trackKey);
    expect(
      rectOf(tester, PlayerRail.levelKey).height,
      moreOrLessEquals(track.height * 0.4, epsilon: 0.5),
    );
    expect(find.byKey(PlayerRail.boostKey), findsNothing);
  });

  testWidgets('brightness has no boost, and the empty track still shows', (
    tester,
  ) async {
    await pump(
      tester,
      const PlayerRail(
        icon: Icons.brightness_6_rounded,
        value: 0.9,
        label: '90%',
        onLeft: false,
      ),
    );
    expect(find.byKey(PlayerRail.boostKey), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(PlayerRail.trackKey),
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == HotstarPlayerStyle.trackInactive,
        ),
      ),
      findsOneWidget,
    );
  });
}
