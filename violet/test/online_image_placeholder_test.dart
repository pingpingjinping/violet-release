import 'package:flutter_test/flutter_test.dart';
import 'package:violet/pages/viewer/image/online_image_placeholder.dart';

void main() {
  test('known page height survives network image remount', () {
    expect(
      onlineImagePlaceholderHeight(
        cachedHeight: 1800,
        estimatedHeight: 300,
      ),
      1800,
    );
  });

  test('held scrolling height wins until the gesture ends', () {
    expect(
      onlineImagePlaceholderHeight(
        heldHeight: 300,
        cachedHeight: 1800,
        estimatedHeight: 1000,
      ),
      300,
    );
  });

  test('estimate is used before any real image height is available', () {
    expect(
      onlineImagePlaceholderHeight(cachedHeight: 0, estimatedHeight: 1250),
      1250,
    );
  });

  test('unseen page uses nearby known heights when available', () {
    final known = [0.0, 900.0, 0.0, 1100.0, 1200.0, 0.0];
    expect(nearestKnownImageHeight(heights: known, index: 2), 1100);
    expect(
      onlineImagePlaceholderHeight(
        cachedHeight: 0,
        estimatedHeight: 0,
        neighborHeight: 1100,
      ),
      1100,
    );
  });

  test('no known neighboring pages leaves the normal 300px fallback', () {
    expect(nearestKnownImageHeight(heights: [0, 0, 0], index: 1), isNull);
    expect(
      onlineImagePlaceholderHeight(
        cachedHeight: 0,
        estimatedHeight: 0,
      ),
      300,
    );
  });

  test('invalid heights fall back to a finite placeholder', () {
    expect(
      onlineImagePlaceholderHeight(
        heldHeight: double.nan,
        cachedHeight: double.infinity,
        estimatedHeight: -1,
      ),
      300,
    );
  });
}
