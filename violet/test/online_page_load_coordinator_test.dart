import 'package:flutter_test/flutter_test.dart';
import 'package:violet/pages/viewer/image/online_page_load_coordinator.dart';

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
}
