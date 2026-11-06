import 'package:flutter/widgets.dart';

/// Reading order, with UP and DOWN that step one row at a time.
///
/// Flutter's directional search looks for the next control in the focused
/// one's own column first, and only when that column is empty for the control
/// nearest across. A list whose rows end in different controls defeats it:
/// Nuvio's scraper rows all end in a play button and a switch, but only some
/// have a settings gear to their left, so DOWN from the repository's buttons
/// went straight to the first gear, and from there to the next gear, over
/// every scraper in between.
///
/// Here UP and DOWN go to the nearest row of this group above or below, and in
/// that row to the control nearest across. Where the group has no row that
/// way, and for LEFT and RIGHT, Flutter decides as before.
class RowTraversalPolicy extends ReadingOrderTraversalPolicy {
  RowTraversalPolicy({super.requestFocusCallback});

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    final down = direction == TraversalDirection.down;
    if (!down && direction != TraversalDirection.up) {
      return super.inDirection(currentNode, direction);
    }
    final scope = currentNode.nearestScope;
    final focused = scope?.focusedChild;
    if (scope == null || focused == null) {
      return super.inDirection(currentNode, direction);
    }
    final from = focused.rect;
    final beyond = [
      for (final node in scope.traversalDescendants)
        if (node != focused &&
            FocusTraversalGroup.maybeOfNode(node) == this &&
            (down
                ? node.rect.center.dy > from.bottom
                : node.rect.center.dy < from.top))
          node,
    ];
    if (beyond.isEmpty) return super.inDirection(currentNode, direction);

    double rise(FocusNode node) => (node.rect.center.dy - from.center.dy).abs();
    final nearest = beyond.reduce((a, b) => rise(a) <= rise(b) ? a : b).rect;
    double across(FocusNode node) =>
        (node.rect.center.dx - from.center.dx).abs();
    final target = beyond
        .where(
          (node) =>
              node.rect.top < nearest.bottom && node.rect.bottom > nearest.top,
        )
        .reduce((a, b) => across(a) <= across(b) ? a : b);

    // A vertical step leaves Flutter's record of horizontal ones behind, so a
    // later LEFT or RIGHT doesn't retrace a move made in another row.
    invalidateScopeData(scope);
    requestFocusCallback(
      target,
      alignmentPolicy: down
          ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
          : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
    );
    return true;
  }
}
