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
    expect(
      state.candidate([6], start.add(const Duration(minutes: 5))),
      isNull,
    );
    expect(state.automaticAttempts(6), 2);

    state.imageLoaded(6);
    state.imageFailed(6, start.add(const Duration(minutes: 6)));
    expect(state.automaticAttempts(6), 0);
    expect(
      state.candidate(
        [6],
        start.add(const Duration(minutes: 6, seconds: 6)),
      ),
      isNotNull,
    );
  });
}
