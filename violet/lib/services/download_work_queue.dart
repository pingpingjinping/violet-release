import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Runs a small number of gallery jobs in parallel while image transfers still
/// share the downloader's global thread limit.
class DownloadWorkQueue extends ChangeNotifier {
  DownloadWorkQueue({
    required this.keepAwake,
    this.maxConcurrent = 2,
  }) : assert(maxConcurrent > 0);

  final Future<void> Function(bool) keepAwake;
  final int maxConcurrent;
  final Queue<(int, Future<void> Function(), Completer<void>)> _pending =
      Queue();
  final Map<int, Future<void>> _submitted = {};
  final Set<int> _activeIds = <int>{};

  bool _pumping = false;
  bool _wakeHeld = false;

  int get pendingCount => _pending.length;
  int get totalCount => _submitted.length;
  bool contains(int id) => _submitted.containsKey(id);

  Set<int> get activeIds => Set<int>.unmodifiable(_activeIds);

  // Kept for existing UI/tests that only need one representative active id.
  int? get activeId => _activeIds.isEmpty ? null : _activeIds.first;

  bool cancelPending(int id) {
    (int, Future<void> Function(), Completer<void>)? target;
    for (final entry in _pending) {
      if (entry.$1 == id) {
        target = entry;
        break;
      }
    }
    if (target == null) return false;

    _pending.remove(target);
    _submitted.remove(id);
    if (!target.$3.isCompleted) target.$3.complete();
    notifyListeners();
    unawaited(_pump());
    return true;
  }

  Future<void> submit(int id, Future<void> Function() work) {
    final existing = _submitted[id];
    if (existing != null) return existing;

    final done = Completer<void>();
    _submitted[id] = done.future;
    _pending.add((id, work, done));
    notifyListeners();
    unawaited(_pump());
    return done.future;
  }

  Future<void> _awake(bool enabled) async {
    // A platform wake-lock failure must not prevent downloads.
    try {
      await keepAwake(enabled);
    } catch (error) {
      debugPrint('Download keep-awake: $error');
    }
  }

  Future<void> _run(
    int id,
    Future<void> Function() work,
    Completer<void> done,
  ) async {
    try {
      await work();
      if (!done.isCompleted) done.complete();
    } catch (error, stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    } finally {
      _activeIds.remove(id);
      _submitted.remove(id);
      notifyListeners();
      unawaited(_pump());
    }
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;

    try {
      if ((_pending.isNotEmpty || _activeIds.isNotEmpty) && !_wakeHeld) {
        _wakeHeld = true;
        await _awake(true);
      }

      while (_pending.isNotEmpty && _activeIds.length < maxConcurrent) {
        final (id, work, done) = _pending.removeFirst();
        _activeIds.add(id);
        notifyListeners();
        unawaited(_run(id, work, done));
      }

      if (_pending.isEmpty && _activeIds.isEmpty && _wakeHeld) {
        _wakeHeld = false;
        await _awake(false);
      }
    } finally {
      _pumping = false;

      if ((_pending.isNotEmpty && _activeIds.length < maxConcurrent) ||
          (_pending.isEmpty && _activeIds.isEmpty && _wakeHeld)) {
        unawaited(_pump());
      }
    }
  }
}
