import 'dart:async';

/// Stable per-page metadata loading shared by all online gallery providers.
/// Retries transient failures, then preserves terminal error for a retry UI.
class OnlinePageLoadCoordinator {
  final Map<int, Future<void>> _pageRequests = {};
  final List<Duration> retryDelays;
  final Future<void> Function(Duration) wait;

  OnlinePageLoadCoordinator({
    this.retryDelays = const [
      Duration(milliseconds: 500),
      Duration(milliseconds: 1200),
    ],
    Future<void> Function(Duration)? wait,
  }) : wait = wait ?? Future<void>.delayed;

  Future<void> load(int index, Future<void> Function() attempt) =>
      _pageRequests.putIfAbsent(index, () => _loadWithRetry(attempt));

  void reset(int index) => _pageRequests.remove(index);

  Future<void> _loadWithRetry(Future<void> Function() attempt) async {
    for (var i = 0; ; i++) {
      try {
        await attempt();
        return;
      } catch (_) {
        if (i >= retryDelays.length) rethrow;
        await wait(retryDelays[i]);
      }
    }
  }
}
