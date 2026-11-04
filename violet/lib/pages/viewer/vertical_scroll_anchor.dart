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

/// Only a page preceding the anchor can push it down when its height changes.
/// Changes to the anchor itself are left to natural layout.
bool heightChangeCanMoveAnchor(int changedIndex, int anchorIndex) =>
    changedIndex < anchorIndex;

/// Choose the page crossing the viewport center at scroll end, or otherwise
/// the largest visible page. This is measured *now*, never reused from a
/// previous position before the drag.
ItemPosition? selectScrollEndPage(Iterable<ItemPosition> positions) {
  ItemPosition? best;
  double bestScore = -1;
  for (final position in positions) {
    final start = position.itemLeadingEdge.clamp(0.0, 1.0).toDouble();
    final end = position.itemTrailingEdge.clamp(0.0, 1.0).toDouble();
    if (end <= start) continue;
    final coversCenter =
        position.itemLeadingEdge <= 0.5 && position.itemTrailingEdge >= 0.5;
    final score = (coversCenter ? 2.0 : 0.0) + end - start;
    if (score > bestScore) {
      best = position;
      bestScore = score;
    }
  }
  return best;
}

/// Scale the intrinsic image size to the available display width, using the
/// same 1.5 px safety inset as the legacy viewer's measured height.
double? realHeightFromImage({
  required double width,
  required int imageWidth,
  required int imageHeight,
}) {
  if (!width.isFinite || width <= 0 || imageWidth <= 0 || imageHeight <= 0) {
    return null;
  }
  final height = (width * imageHeight / imageWidth - 1.5).floorToDouble();
  return height >= 1 && height.isFinite ? height : 1;
}
