// This source code is a part of Project Violet.
// Copyright (C) 2020-2024, violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';

// Fetch a small bounded batch concurrently, but publish tasks in page order.
// Read the limit before every batch so new settings apply during long jobs.
Future<void> processOrderedBatches<T>({
  required int total,
  required int Function() concurrency,
  required Future<T> Function(int index) fetch,
  required Future<void> Function(T item) deliver,
}) async {
  for (var start = 0; start < total;) {
    final count = concurrency().clamp(1, 8).toInt();
    final end = (start + count).clamp(0, total).toInt();
    final batch = await Future.wait([
      for (var index = start; index < end; index++) fetch(index),
    ]);
    for (final item in batch) {
      await deliver(item);
    }
    start = end;
  }
}
