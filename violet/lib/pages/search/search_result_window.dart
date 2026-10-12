// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

/// The number of items returned by local search queries in HentaiManager.
const int localSearchBatchSize = 500;

/// The earlier window that must be loaded immediately before [firstOffset].
///
/// The last window may be smaller than a full local-search batch. It must be
/// trimmed to [count] because HentaiManager currently returns up to 500 rows
/// even when only the first few results are required.
({int offset, int count})? previousSearchWindow(
  int firstOffset, {
  int batchSize = localSearchBatchSize,
}) {
  if (firstOffset <= 0 || batchSize <= 0) return null;
  final offset = firstOffset > batchSize ? firstOffset - batchSize : 0;
  return (offset: offset, count: firstOffset - offset);
}
