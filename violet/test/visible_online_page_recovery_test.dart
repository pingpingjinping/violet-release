import 'package:flutter_test/flutter_test.dart';
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

  test('Hitomi quickly retries twice before refreshing the image URL', () {
    final state = VisibleOnlinePageRecovery(stagedImageRetries: true);
    state.imageFailed(1, start);
    expect(
      state.candidate([1], start.add(const Duration(milliseconds: 999))),
      isNull,
    );

    const stages = [
      VisiblePageRetryType.image,
      VisiblePageRetryType.image,
      VisiblePageRetryType.imageWithRefreshedUrl,
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
    expect(next?.type, VisiblePageRetryType.image);
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
      VisiblePageRetryType.image,
    );
  });
}
