// Network images may be unmounted when the list scrolls past them.
// Recreating a loader must not collapse a previously measured full-height
// image back to the default 300px placeholder.
double onlineImagePlaceholderHeight({
  double? heldHeight,
  required double cachedHeight,
  required double estimatedHeight,
  double? neighborHeight,
  double fallbackHeight = 300.0,
}) {
  if (heldHeight != null && heldHeight.isFinite && heldHeight > 0) {
    return heldHeight;
  }
  if (cachedHeight.isFinite && cachedHeight > 0) return cachedHeight;
  if (estimatedHeight.isFinite && estimatedHeight > 0) {
    return estimatedHeight;
  }
  if (neighborHeight != null && neighborHeight.isFinite && neighborHeight > 0) {
    return neighborHeight;
  }
  return fallbackHeight;
}

/// Best-effort height for an unseen page. Choose the median of the closest
/// measured pages rather than allowing distant/unrelated pages to influence
/// layout. Callers should cache this once per page to avoid relayout feedback.
double? nearestKnownImageHeight({
  required List<double> heights,
  required int index,
  int maxDistance = 5,
  int maxSamples = 4,
}) {
  if (index < 0 || index >= heights.length || maxDistance < 1 || maxSamples < 1)
    return null;
  final samples = <double>[];
  for (var d = 1; d <= maxDistance && samples.length < maxSamples; d++) {
    for (final i in [index - d, index + d]) {
      if (i < 0 || i >= heights.length) continue;
      final h = heights[i];
      if (h.isFinite && h > 0) samples.add(h);
      if (samples.length >= maxSamples) break;
    }
  }
  if (samples.isEmpty) return null;
  samples.sort();
  final middle = samples.length ~/ 2;
  return samples.length.isOdd
      ? samples[middle]
      : (samples[middle - 1] + samples[middle]) / 2;
}
