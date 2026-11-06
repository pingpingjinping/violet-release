import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:violet/pages/viewer/image/online_page_load_coordinator.dart';
import 'package:violet/pages/viewer/image/visible_online_page_recovery.dart';

void main() {
  OnlinePageLoadCoordinator coordinator() => OnlinePageLoadCoordinator(
    retryDelays: const [Duration.zero, Duration.zero],
    wait: (_) async {},
  );

  test('retries transient metadata failures and then succeeds', () async {
    var attempts = 0;
    final loader = coordinator();
    await loader.load(4, () async {
      attempts++;
      if (attempts < 3) throw StateError('transient failure');
    });
    expect(attempts, 3);
    await loader.load(4, () async {
      attempts++;
    });
    expect(attempts, 3);
  });

  test('terminal error remains stable until manual retry', () async {
    var attempts = 0;
    final loader = coordinator();
    Future<void> fail() async {
      attempts++;
      throw StateError('metadata unavailable');
    }

    final failed = loader.load(5, fail);
    await expectLater(failed, throwsStateError);
    expect(attempts, 3);
    expect(identical(loader.load(5, fail), failed), isTrue);
    await expectLater(loader.load(5, fail), throwsStateError);
    expect(attempts, 3);

    loader.reset(5);
    await expectLater(loader.load(5, fail), throwsStateError);
    expect(attempts, 6);
  });

  test('simultaneous requests for one page share one future', () async {
    final loader = coordinator();
    var attempts = 0;
    final first = loader.load(7, () async {
      attempts++;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    });
    final second = loader.load(7, () async {
      attempts++;
    });
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(attempts, 1);
  });

  test('retrying one failed page keeps other pages cached', () async {
    final loader = coordinator();
    var firstCount = 0;
    var secondCount = 0;
    await loader.load(1, () async {
      firstCount++;
    });
    await loader.load(2, () async {
      secondCount++;
    });
    loader.reset(1);
    await loader.load(1, () async {
      firstCount++;
    });
    await loader.load(2, () async {
      secondCount++;
    });
    expect(firstCount, 2);
    expect(secondCount, 1);
  });

  test(
    'manual image retry waits for automatic recovery and runs once',
    () async {
      final retries = OnlineImageRetryCoordinator();
      final releaseAutomatic = Completer<void>();
      final calls = <String>[];
      final automatic = retries.tryAutomatic(() async {
        calls.add('automatic');
        await releaseAutomatic.future;
      });

      final manual = retries.runManual(() async {
        calls.add('manual');
      });
      expect(
        identical(
          manual,
          retries.runManual(() async => fail('duplicate retry')),
        ),
        isTrue,
      );
      expect(calls, ['automatic']);
      expect(await retries.tryAutomatic(() async => fail('overlap')), isFalse);

      releaseAutomatic.complete();
      expect(await automatic, isTrue);
      await manual;
      expect(calls, ['automatic', 'manual']);
      expect(retries.isBusy, isFalse);
    },
  );

  test('busy retry coordinator does not consume a Hitomi attempt', () async {
    final retries = OnlineImageRetryCoordinator();
    final recovery = VisibleOnlinePageRecovery(stagedImageRetries: true);
    final start = DateTime.utc(2026, 11, 6);
    recovery.imageFailed(7, start);
    final firstAttemptAt = start.add(const Duration(seconds: 1));
    final retry = recovery.candidate([7], firstAttemptAt)!;
    expect(retry.type, VisiblePageRetryType.imageWithRefreshedUrl);

    final releaseManual = Completer<void>();
    final manual = retries.runManual(() => releaseManual.future);
    final accepted = await retries.tryAutomatic(() async {
      recovery.beginAutomaticRetry(retry, firstAttemptAt);
    });
    expect(accepted, isFalse);
    expect(recovery.automaticAttempts(7), 0);

    releaseManual.complete();
    await manual;
    expect(
      recovery.candidate([7], start.add(const Duration(seconds: 2)))?.type,
      VisiblePageRetryType.imageWithRefreshedUrl,
    );
  });

  test('automatic recovery failure still lets the manual retry run', () async {
    final retries = OnlineImageRetryCoordinator();
    final releaseAutomatic = Completer<void>();
    final automatic = retries.tryAutomatic(() => releaseAutomatic.future);
    final error = expectLater(automatic, throwsStateError);
    var manualRan = false;
    final manual = retries.runManual(() async {
      manualRan = true;
    });

    releaseAutomatic.completeError(StateError('automatic retry failed'));
    await error;
    await manual;
    expect(manualRan, isTrue);
    expect(retries.isBusy, isFalse);
  });
}
