// Network images may be unmounted when the list scrolls past them.
// Recreating a loader must not collapse a previously measured full-height
// image back to the default 300px placeholder.
double onlineImagePlaceholderHeight({
  double? heldHeight,
  required double cachedHeight,
  required double estimatedHeight,
  double fallbackHeight = 300.0,
}) {
  if (heldHeight != null && heldHeight.isFinite && heldHeight > 0) {
    return heldHeight;
  }
  if (cachedHeight.isFinite && cachedHeight > 0) return cachedHeight;
  if (estimatedHeight.isFinite && estimatedHeight > 0) {
    return estimatedHeight;
  }
  return fallbackHeight;
}
