import 'package:flutter_test/flutter_test.dart';
import 'package:violet/pages/viewer/image/online_image_failure_tracker.dart';
import 'package:violet/pages/viewer/image/visible_online_page_recovery.dart';

void main() {
  final start = DateTime.utc(2026, 11, 4);

  test('only actually visible failed pages are automatic candidates', () {
    final state = VisibleOnlinePageRecovery();
    state.imageFailed(1, start);
    state.imageFailed(2, start);

    final retry = state.candidate([2], start.add(const Duration(seconds: 7)));
    expect(retry?.index, 2);
    expect(retry?.type, VisiblePageRetryType.image);
    expect(state.candidate([], start.add(const Duration(minutes: 1))), isNull);
  });

  test('metadata failure retries only after delay, not while loading', () {
    final state = VisibleOnlinePageRecovery();
    state.metadataLoading(3, start);
    expect(state.candidate([3], start.add(const Duration(minutes: 1))), isNull);

    state.metadataFailed(3, start);
    expect(state.candidate([3], start.add(const Duration(seconds: 5))), isNull);
    expect(
      state.candidate([3], start.add(const Duration(seconds: 6)))?.type,
      VisiblePageRetryType.metadata,
    );
    state.metadataReady(3);
    expect(state.candidate([3], start.add(const Duration(minutes: 2))), isNull);
  });

  test('progressing image is not mistaken for a stalled transfer', () {
    final state = VisibleOnlinePageRecovery();
    state.imageLoading(4, start, receivedBytes: 0);
    state.imageLoading(
      4,
      start.add(const Duration(seconds: 20)),
      receivedBytes: 1000,
    );
    final progressStillActive = start.add(const Duration(seconds: 40));
    expect(state.candidate([4], progressStillActive), isNull);
    expect(
      state.candidate([4], start.add(const Duration(seconds: 50)))?.type,
      VisiblePageRetryType.image,
    );
  });

  test('unchanged bytes remain stalled across rebuilds', () {
    final state = VisibleOnlinePageRecovery();
    state.imageLoading(4, start);
    state.imageLoading(4, start.add(const Duration(seconds: 25)));
    expect(
      state.candidate([4], start.add(const Duration(seconds: 31)))?.index,
      4,
    );
  });

  test('limited retries are backed off and never loop indefinitely', () {
    final state = VisibleOnlinePageRecovery();
    state.imageFailed(6, start);
    final first = state.candidate([6], start.add(const Duration(seconds: 6)))!;
    state.beginAutomaticRetry(first, start.add(const Duration(seconds: 6)));
    state.imageFailed(6, start.add(const Duration(seconds: 7)));
    final withinCooldown = start.add(const Duration(seconds: 20));
    expect(state.candidate([6], withinCooldown), isNull);

    final secondAt = start.add(const Duration(seconds: 26));
    final second = state.candidate([6], secondAt)!;
    state.beginAutomaticRetry(second, secondAt);
    state.imageFailed(6, start.add(const Duration(seconds: 27)));
    expect(state.candidate([6], start.add(const Duration(minutes: 5))), isNull);
    expect(state.automaticAttempts(6), 2);

    state.imageLoaded(6);
    state.imageFailed(6, start.add(const Duration(minutes: 6)));
    expect(state.automaticAttempts(6), 0);
    expect(
      state.candidate([6], start.add(const Duration(minutes: 6, seconds: 6))),
      isNotNull,
    );
  });

  test('Hitomi recovers only failed pages seven ahead and three behind', () {
    final failures = OnlineImageFailureTracker();
    for (final index in [2, 6, 7, 8, 10, 14, 15, 16]) {
      failures.markFailed(index);
    }
    failures.markLoading(10); // Still downloading; must not be interrupted.

    // The actual viewport spans pages 7-8. Look ahead through page 15,
    // and behind through page 4, without retrying page 2 or 16.
    final nearbyFailures = VisibleOnlinePageRecovery.failedNearbyPages(
      firstVisibleIndex: 7,
      lastVisibleIndex: 8,
      pageCount: 20,
      isFailed: failures.isFailed,
    ).toList();
    expect(nearbyFailures, [14, 15, 6]);

    final recovery = VisibleOnlinePageRecovery(stagedImageRetries: true);
    for (final index in nearbyFailures) {
      recovery.imageFailed(index, start);
    }
    expect(
      recovery.candidate(
        nearbyFailures,
        start.add(const Duration(seconds: 1)),
      )?.index,
      14,
    );
  });

  test('nearby recovery clamps to the beginning and end of the gallery', () {
    final failures = OnlineImageFailureTracker();
    failures.markFailed(0);
    failures.markFailed(1);
    failures.markFailed(13);
    failures.markFailed(14);
    expect(
      VisibleOnlinePageRecovery.failedNearbyPages(
        firstVisibleIndex: 2,
        lastVisibleIndex: 3,
        pageCount: 15,
        isFailed: failures.isFailed,
      ).toList(),
      [1, 0],
    );
    expect(
      VisibleOnlinePageRecovery.failedNearbyPages(
        firstVisibleIndex: 11,
        lastVisibleIndex: 12,
        pageCount: 15,
        isFailed: failures.isFailed,
      ).toList(),
      [13, 14],
    );
    expect(
      VisibleOnlinePageRecovery.failedNearbyPages(
        firstVisibleIndex: 0,
        lastVisibleIndex: 0,
        pageCount: 15,
        isFailed: (_) => false,
      ).toList(),
      isEmpty,
    );
  });

  test('Hitomi refreshes the URL first, then retries it twice', () {
    final state = VisibleOnlinePageRecovery(stagedImageRetries: true);
    state.imageFailed(1, start);
    expect(
      state.candidate([1], start.add(const Duration(milliseconds: 999))),
      isNull,
    );

    const stages = [
      VisiblePageRetryType.imageWithRefreshedUrl,
      VisiblePageRetryType.image,
      VisiblePageRetryType.image,
    ];
    for (var i = 0; i < stages.length; i++) {
      final at = start.add(Duration(seconds: i + 1));
      final retry = state.candidate([1], at)!;
      expect(retry.type, stages[i]);
      state.beginAutomaticRetry(retry, at);
      state.imageFailed(1, at);
    }
    expect(state.candidate([1], start.add(const Duration(minutes: 2))), isNull);
  });

  test('Hitomi gives each visible failure a turn before its next stage', () {
    final state = VisibleOnlinePageRecovery(stagedImageRetries: true);
    state.imageFailed(1, start);
    state.imageFailed(2, start);
    final firstAt = start.add(const Duration(seconds: 1));
    final first = state.candidate([1, 2], firstAt)!;
    state.beginAutomaticRetry(first, firstAt);
    state.imageFailed(first.index, firstAt);

    final next = state.candidate([1, 2], start.add(const Duration(seconds: 2)));
    expect(next?.index, first.index == 1 ? 2 : 1);
    expect(next?.type, VisiblePageRetryType.imageWithRefreshedUrl);
  });

  test('Hitomi metadata recovery does not spend image retries', () {
    final state = VisibleOnlinePageRecovery(stagedImageRetries: true);
    state.metadataFailed(1, start);
    final at = start.add(const Duration(seconds: 6));
    final retry = state.candidate([1], at)!;
    expect(retry.type, VisiblePageRetryType.metadata);
    state.beginAutomaticRetry(retry, at);
    state.metadataReady(1);
    state.imageFailed(1, at);

    expect(state.automaticAttempts(1), 0);
    expect(
      state.candidate([1], at.add(const Duration(seconds: 1)))?.type,
      VisiblePageRetryType.imageWithRefreshedUrl,
    );
  });
}
