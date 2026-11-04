/// Tracks only confirmed network image failures across lazily mounted pages.
///
/// A page whose image is still loading or whose URL is not yet available is
/// not eligible for the purple "retry failed images" action.
class OnlineImageFailureTracker {
  final Set<int> _failed = <int>{};

  void markFailed(int index) {
    if (index >= 0) _failed.add(index);
  }

  void markLoading(int index) {
    _failed.remove(index);
  }

  void markLoaded(int index) {
    _failed.remove(index);
  }

  List<int> retryablePages({
    required int pageCount,
    required bool Function(int index) hasUrl,
  }) => [
    for (var index = 0; index < pageCount; index++)
      if (_failed.contains(index) && hasUrl(index)) index,
  ];
}
