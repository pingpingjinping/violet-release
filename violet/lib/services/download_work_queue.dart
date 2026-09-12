import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// One gallery at a time; image transfers still use the downloader's thread limit.
class DownloadWorkQueue extends ChangeNotifier {
  DownloadWorkQueue({required this.keepAwake});

  final Future<void> Function(bool) keepAwake;
  final Queue<(int, Future<void> Function(), Completer<void>)> _pending =
      Queue();
  final Map<int, Future<void>> _submitted = {};
  bool _draining = false;
  int? activeId;

  int get pendingCount => _pending.length;
  int get totalCount => _submitted.length;
  bool contains(int id) => _submitted.containsKey(id);

  bool cancelPending(int id) {
    for (final entry in _pending) {
      if (entry.$1 != id) continue;
      _pending.remove(entry);
      _submitted.remove(id);
      entry.$3.complete();
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<void> submit(int id, Future<void> Function() work) {
    final existing = _submitted[id];
    if (existing != null) return existing;
    final done = Completer<void>();
    _submitted[id] = done.future;
    _pending.add((id, work, done));
    notifyListeners();
    if (!_draining) unawaited(_drain());
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

  Future<void> _drain() async {
    _draining = true;
    await _awake(true);
    while (_pending.isNotEmpty) {
      final (id, work, done) = _pending.removeFirst();
      activeId = id;
      notifyListeners();
      try {
        await work();
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        _submitted.remove(id);
        activeId = null;
        notifyListeners();
      }
    }
    await _awake(false);
    _draining = false;
    // A new request may arrive while the platform is releasing its lock.
    if (_pending.isNotEmpty) unawaited(_drain());
  }
}
