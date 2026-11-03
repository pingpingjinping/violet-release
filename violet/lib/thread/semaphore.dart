// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:violet/util/call_once.dart';

enum Priority { urgent, normal }

// https://github.com/mezoni/semaphore/blob/master/lib/src/semaphore/semaphore.dart
class Semaphore {
  int maxCount;

  int _currentCount = 0;

  Semaphore({required this.maxCount});

  // Adjust limits in place; existing permit holders keep their permits.
  // Decreasing the limit does not start new work until active work drains.
  void setMaxCount(int count) {
    if (count < 1) throw ArgumentError.value(count, 'count');
    maxCount = count;
    _drainWaitQueue();
  }

  void _drainWaitQueue() {
    while (_currentCount < maxCount && _waitQueue.isNotEmpty) {
      _currentCount++;
      final completer = _waitQueue.removeFirst();
      completer.$2.complete(CallOnce(release));
    }
  }

  final PriorityQueue<(Priority, Completer<CallOnce>)> _waitQueue =
      PriorityQueue<(Priority, Completer<CallOnce>)>(
        (a, b) => a.$1.index.compareTo(b.$1.index),
      );

  Future<CallOnce> acquire([Priority priority = Priority.normal]) {
    var completer = Completer<CallOnce>();

    if (_currentCount + 1 <= maxCount) {
      _currentCount++;
      completer.complete(CallOnce(release));
    } else {
      _waitQueue.add((priority, completer));
    }

    return completer.future;
  }

  void drop() {
    _waitQueue.clear();
  }

  void dropUrgents() {
    while (_waitQueue.first.$1 == Priority.urgent) {
      _waitQueue.removeFirst();
    }
  }

  void release() {
    _currentCount--;
    _drainWaitQueue();
  }
}
