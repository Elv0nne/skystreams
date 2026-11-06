/// How long each hero slide stays up, whatever the system's animation setting.
///
/// The slide dwell is a clock, not an animation. It used to be an
/// [AnimationController] with the default [AnimationBehavior.normal], which
/// Flutter shortens to 5% of its duration whenever the platform asks for
/// animations to be removed - Android's "Animation off" transition scale, and
/// the fast animation modes some phones map onto it. The five-second dwell
/// became a quarter of a second and the carousel spun through its slides. The
/// slide *transition* may still collapse under that setting; the dwell may not.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/explore/presentation/widgets/explore_carousel.dart';
import 'package:visibility_detector/visibility_detector.dart';

MultimediaItem _movie(int i) => MultimediaItem(
  title: 'Title $i',
  url: 'https://fake.test/$i',
  posterUrl: '',
  bannerUrl: '',
  contentType: MultimediaContentType.movie,
);

void main() {
  setUp(() {
    // The carousel is wrapped in a VisibilityDetector, which otherwise leaves
    // a 500 ms debounce Timer pending past the end of the test.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    VisibilityDetectorController.instance.updateInterval = const Duration(
      milliseconds: 500,
    );
    debugSemanticsDisableAnimations = null;
  });

  testWidgets('a slide stays up for its full dwell with animations removed', (
    tester,
  ) async {
    debugSemanticsDisableAnimations = true;
    tester.view.physicalSize = const Size(1233, 2745);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: ExploreCarousel(
              movies: List<MultimediaItem>.generate(7, _movie),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('TITLE 0'), findsOneWidget);

    // A second in: still the first slide. Scaled to 5%, the dwell had already
    // run out four times over by now.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('TITLE 0'), findsOneWidget);
    expect(find.text('TITLE 1'), findsNothing);

    // Past the five seconds, it moves on - once.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('TITLE 1'), findsOneWidget);
    expect(find.text('TITLE 2'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
