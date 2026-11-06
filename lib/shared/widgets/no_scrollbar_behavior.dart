import 'package:flutter/material.dart';

/// The app's scroll behaviour with the scrollbar taken away.
///
/// For screens that draw their own edge hint - a gradient where the list
/// carries on - in place of a scrollbar.
///
/// A [MaterialScrollBehavior], not a bare [ScrollBehavior]: the base class
/// predates Material 3 and gives Android the pre-12 glow at the ends of a
/// list, where this one gives it the stretch that every other screen already
/// gets from [MaterialApp]. The scrollbar is the only thing that changes.
class NoScrollbarBehavior extends MaterialScrollBehavior {
  const NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
