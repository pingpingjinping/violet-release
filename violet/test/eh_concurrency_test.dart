import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/ordered_extraction.dart';
import 'package:violet/thread/semaphore.dart';

void main() {
  test('bounded extraction starts concurrently and delivers in order', () async {
    final requests = List.generate(4, (_) => Completer<int>());
    final started = <int>[];
    final delivered = <int>[];

    final finished = processOrderedBatches<int>(
      total: 4,
      concurrency: () => 2,
      fetch: (index) {
        started.add(index);
        return requests[index].future;
      },
      deliver: (value) async => delivered.add(value),
    );
    expect(started, [0, 1]);

    requests[1].complete(1);
    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);

    requests[0].complete(0);
    await Future<void>.delayed(Duration.zero);
    expect(delivered, [0, 1]);
    expect(started, [0, 1, 2, 3]);

    requests[3].complete(3);
    requests[2].complete(2);
    await finished;
    expect(delivered, [0, 1, 2, 3]);
  });

  test('resizing a semaphore allows increases and respects decreases', () async {
    final semaphore = Semaphore(maxCount: 1);
    final first = await semaphore.acquire();
    final secondFuture = semaphore.acquire();

    semaphore.setMaxCount(2);
    final second = await secondFuture;

    semaphore.setMaxCount(1);
    var thirdStarted = false;
    final thirdFuture = semaphore.acquire().then((permit) {
      thirdStarted = true;
      return permit;
    });

    first();
    await Future<void>.delayed(Duration.zero);
    expect(thirdStarted, isFalse);

    second();
    final third = await thirdFuture;
    expect(thirdStarted, isTrue);
    third();
  });
}
