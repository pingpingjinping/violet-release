import 'package:violet/pages/viewer/others/scrollable_positioned_list/src/item_positions_listener.dart';

/// Pick the largest currently visible, already rendered neighbor. The page
/// whose height is changing is intentionally excluded: its own relayout is
/// allowed to move naturally without fighting the user.
ItemPosition? selectVisibleLoadedAnchor(
  Iterable<ItemPosition> positions, {
  required int excludedIndex,
  required bool Function(int index) isLoaded,
}) {
  ItemPosition? best;
  var coverage = 0.0;

  for (final position in positions) {
    if (position.index == excludedIndex || !isLoaded(position.index)) {
      continue;
    }
    final start = position.itemLeadingEdge.clamp(0.0, 1.0).toDouble();
    final end = position.itemTrailingEdge.clamp(0.0, 1.0).toDouble();
    final visible = end - start;
    if (visible > coverage) {
      best = position;
      coverage = visible;
    }
  }
  return best;
}
