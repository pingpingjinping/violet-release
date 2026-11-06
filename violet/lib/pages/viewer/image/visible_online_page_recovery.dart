/// Conservative, viewport-scoped online-page recovery policy.
///
/// This class does not own timers or fetch images. The vertical viewer supplies
/// actual on-screen indices, while ProviderImage supplies byte progress.
/// Prefetched/off-screen pages never trigger automatic network requests.
enum VisiblePageRetryType { metadata, image, imageWithRefreshedUrl }

class VisiblePageRetry {
  final int index;
  final VisiblePageRetryType type;

  const VisiblePageRetry(this.index, this.type);
}

enum _VisiblePagePhase {
  idle,
  metadataLoading,
  metadataFailed,
  imageLoading,
  imageFailed,
}

class _PageRecoveryState {
  _VisiblePagePhase phase = _VisiblePagePhase.idle;
  DateTime? lastActivity;
  DateTime? lastAttempt;
  int? lastBytes;
  int automaticAttempts = 0;
}

/// Only terminal failures or image streams without *byte progress* may retry.
///
/// A successfully rendered image resets its budget; manual retries are separate.
class VisibleOnlinePageRecovery {
  static const Duration failureDelay = Duration(seconds: 6);
  static const Duration stalledImageDelay = Duration(seconds: 30);
  static const Duration retryCooldown = Duration(seconds: 20);
  static const int maxAutomaticAttempts = 2;
  static const Duration _quickFailureDelay = Duration(seconds: 1);
  // First attempt refreshes a potentially stale gallery URL; the remaining
  // two attempts reuse the resolved URL without additional gallery lookups.
  static const int _sameUrlAttempts = 2;

  final bool stagedImageRetries;
  final Map<int, _PageRecoveryState> _states = {};

  VisibleOnlinePageRecovery({this.stagedImageRetries = false});

  _PageRecoveryState _state(int index) =>
      _states.putIfAbsent(index, _PageRecoveryState.new);

  void metadataLoading(int index, DateTime now) {
    final state = _state(index);
    if (state.phase != _VisiblePagePhase.metadataLoading) {
      state.lastActivity = now;
    }
    state.phase = _VisiblePagePhase.metadataLoading;
  }

  void metadataFailed(int index, DateTime now) {
    final state = _state(index);
    if (state.phase != _VisiblePagePhase.metadataFailed) {
      state.lastActivity = now;
    }
    state.phase = _VisiblePagePhase.metadataFailed;
  }

  void metadataReady(int index) {
    final state = _states[index];
    if (state == null) return;
    if (state.phase == _VisiblePagePhase.metadataFailed ||
        state.phase == _VisiblePagePhase.metadataLoading) {
      state.phase = _VisiblePagePhase.idle;
      if (stagedImageRetries) {
        state.automaticAttempts = 0;
        state.lastAttempt = null;
      }
    }
  }

  void imageLoading(int index, DateTime now, {int? receivedBytes}) {
    final state = _state(index);
    if (state.phase != _VisiblePagePhase.imageLoading) {
      state.lastActivity = now;
      state.lastBytes = receivedBytes;
    } else if (receivedBytes != null &&
        (state.lastBytes == null || receivedBytes > state.lastBytes!)) {
      state.lastBytes = receivedBytes;
      state.lastActivity = now;
    }
    state.phase = _VisiblePagePhase.imageLoading;
  }

  void imageFailed(int index, DateTime now) {
    final state = _state(index);
    if (state.phase != _VisiblePagePhase.imageFailed) {
      state.lastActivity = now;
    }
    state.phase = _VisiblePagePhase.imageFailed;
  }

  void imageLoaded(int index) => _states.remove(index);

  /// The caller must pass indices truly intersecting the viewport, not cache
  /// extent/prefetch indices. Only one candidate is returned per timer tick.
  VisiblePageRetry? candidate(Iterable<int> visible, DateTime now) {
    // Give other visible pages their quick retries before a gallery lookup.
    final indices = stagedImageRetries
        ? (visible.toList()..sort(
            (left, right) =>
                automaticAttempts(left).compareTo(automaticAttempts(right)),
          ))
        : visible;
    for (final index in indices) {
      final state = _states[index];
      if (state == null || state.lastActivity == null) continue;
      final stagedImage =
          stagedImageRetries &&
          (state.phase == _VisiblePagePhase.imageFailed ||
              state.phase == _VisiblePagePhase.imageLoading);
      final maxAttempts = stagedImage
          ? _sameUrlAttempts + 1
          : maxAutomaticAttempts;
      if (state.automaticAttempts >= maxAttempts) continue;

      final cooldown = stagedImage ? _quickFailureDelay : retryCooldown;
      if (state.lastAttempt != null &&
          now.difference(state.lastAttempt!) < cooldown) {
        continue;
      }
      final elapsed = now.difference(state.lastActivity!);
      final imageType =
          stagedImage && state.automaticAttempts == 0
          ? VisiblePageRetryType.imageWithRefreshedUrl
          : VisiblePageRetryType.image;
      switch (state.phase) {
        case _VisiblePagePhase.metadataFailed:
          if (elapsed >= failureDelay) {
            return VisiblePageRetry(index, VisiblePageRetryType.metadata);
          }
        case _VisiblePagePhase.imageFailed:
          if (elapsed >= (stagedImage ? _quickFailureDelay : failureDelay)) {
            return VisiblePageRetry(index, imageType);
          }
        case _VisiblePagePhase.imageLoading:
          if (elapsed >= stalledImageDelay) {
            return VisiblePageRetry(index, imageType);
          }
        case _VisiblePagePhase.idle:
        case _VisiblePagePhase.metadataLoading:
          break;
      }
    }
    return null;
  }

  /// Reserve immediately before starting a request, preventing duplicate work
  /// even if the next UI frame has not rebuilt the failed image yet.
  void beginAutomaticRetry(VisiblePageRetry retry, DateTime now) {
    final state = _state(retry.index);
    state.automaticAttempts++;
    state.lastAttempt = now;
    state.lastActivity = now;
    state.lastBytes = null;
    state.phase = retry.type == VisiblePageRetryType.metadata
        ? _VisiblePagePhase.metadataLoading
        : _VisiblePagePhase.imageLoading;
  }

  int automaticAttempts(int index) => _states[index]?.automaticAttempts ?? 0;
}
