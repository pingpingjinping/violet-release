import 'package:flutter_test/flutter_test.dart';
import 'package:violet/pages/viewer/others/scrollable_positioned_list/src/item_positions_listener.dart';
import 'package:violet/pages/viewer/vertical_scroll_anchor.dart';

void main() {
  ItemPosition position(int index, double start, double end) {
    return ItemPosition(
      index: index,
      itemLeadingEdge: start,
      itemTrailingEdge: end,
    );
  }

  test('uses the most visible loaded neighbor', () {
    final candidates = [
      position(99, -0.3, 0.25),
      position(100, 0.25, 0.75),
      position(101, 0.75, 1.4),
    ];
    final anchor = selectVisibleLoadedAnchor(
      candidates,
      excludedIndex: 100,
      isLoaded: (i) => i == 99 || i == 101,
    );
    expect(anchor?.index, 99);
  });

  test('does not pin the page whose height is changing', () {
    final anchor = selectVisibleLoadedAnchor(
      [position(100, -0.5, 1.5)],
      excludedIndex: 100,
      isLoaded: (_) => true,
    );
    expect(anchor, isNull);
  });

  test('ignores missing or off-screen pages', () {
    final anchor = selectVisibleLoadedAnchor(
      [position(98, -1.3, -0.1), position(99, 0.1, 0.8)],
      excludedIndex: 100,
      isLoaded: (i) => i == 98,
    );
    expect(anchor, isNull);
  });
}
