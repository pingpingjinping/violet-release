import 'package:flutter_test/flutter_test.dart';
import 'package:violet/pages/viewer/image/online_image_failure_tracker.dart';

void main() {
  test('only confirmed image failures are retried, not ongoing downloads', () {
    final tracker = OnlineImageFailureTracker();
    tracker.markFailed(2);
    tracker.markFailed(3);
    tracker.markLoading(3); // A previously failed page is now downloading.
    tracker.markLoaded(4);

    expect(tracker.retryablePages(pageCount: 6, hasUrl: (_) => true), [2]);
  });

  test('purple retry includes all failed pages with resolved URLs', () {
    final tracker = OnlineImageFailureTracker();
    tracker.markFailed(1);
    tracker.markFailed(4);
    tracker.markFailed(7);

    expect(
      tracker.retryablePages(pageCount: 8, hasUrl: (index) => index != 4),
      [1, 7],
    );
  });

  test('loaded and retried images are removed from failure set', () {
    final tracker = OnlineImageFailureTracker();
    tracker.markFailed(1);
    tracker.markFailed(2);
    tracker.markLoading(1);
    tracker.markLoaded(2);

    expect(tracker.retryablePages(pageCount: 3, hasUrl: (_) => true), isEmpty);

    tracker.markFailed(1);
    expect(tracker.retryablePages(pageCount: 3, hasUrl: (_) => true), [1]);
  });

  test('other pages remain failed until their own state changes', () {
    final tracker = OnlineImageFailureTracker();
    tracker.markFailed(1);
    tracker.markFailed(3);
    tracker.markLoaded(1);

    expect(tracker.retryablePages(pageCount: 5, hasUrl: (_) => true), [3]);
  });
}
