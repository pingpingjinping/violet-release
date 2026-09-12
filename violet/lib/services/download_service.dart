import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/download.dart';
import 'package:violet/database/user/user.dart';
import 'package:synchronized/synchronized.dart';
import 'package:violet/downloader/isolate_downloader.dart';
import 'package:violet/pages/download/download_routine.dart';
import 'package:violet/services/download_work_queue.dart';

class GalleryDownloadProgress extends ChangeNotifier {
  GalleryDownloadProgress(this.item);
  final DownloadItemModel item;
  int extracted = 0, total = 0, completed = 0;
  double bytes = 0, bytesPerSecond = 0;
  bool cancelled = false;
  DownloadRoutine? routine;
  Future<void>? finished;

  void changed() => notifyListeners();
}

/// Owns downloads independently of page creation, scrolling and widget disposal.
class DownloadService {
  DownloadService._();
  static final instance = DownloadService._();
  static const _screen = MethodChannel('xyz.project.violet/downloadScreen');
  final changes = ValueNotifier<int>(0);
  final completed = ValueNotifier<DownloadItemModel?>(null);
  final Map<int, GalleryDownloadProgress> _jobs = {};
  Future<void>? _initializing;
  final _submission = Lock();
  late final queue = DownloadWorkQueue(keepAwake: (enabled) async {
    if (Platform.isIOS || Platform.isAndroid) {
      await _screen.invokeMethod<void>('setKeepAwake', enabled);
    }
  });

  Future<void> initialize() => _initializing ??= _initialize().catchError((Object error, StackTrace stack) {
    _initializing = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _initialize() async {
    final downloader = await IsolateDownloader.getInstance();
    while (!downloader.isReady()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Download.getInstance();
    final db = await CommonUserDatabase.getInstance();
    final items = (await db.query('SELECT * FROM DownloadItem WHERE State BETWEEN 1 AND 4'))
        .map((row) => DownloadItemModel(result: row));
    for (final item in items) {
      if (item.state() == 1) {
        _start(item);
      } else if (item.state() >= 2 && item.state() <= 4) {
        // Interrupted work remains available for the existing retry/recovery menu.
        item.result = {...item.result, 'State': 6};
        await item.update();
      }
    }
  }

  GalleryDownloadProgress? progress(int id) => _jobs[id];

  Future<List<DownloadItemModel>> items() async {
    await initialize();
    return (await (await Download.getInstance()).getDownloadItems())
        .map((item) => _jobs[item.id()]?.item ?? item).toList();
  }

  Future<void> enqueue(String url, {QueryResult? queryResult}) async {
    await initialize();
    await _submission.synchronized(() async {
      final item = await (await Download.getInstance()).createNew(url);
      item.download = true;
      item.queryResult = queryResult;
      _start(item);
      changes.value++;
    });
  }

  void retry(DownloadItemModel item, {bool recover = false}) {
    if (queue.contains(item.id())) return;
    item.result = {...item.result, 'State': 1};
    _start(item, recover: recover);
    changes.value++;
  }

  void _start(DownloadItemModel item, {bool recover = false}) {
    if (queue.contains(item.id())) return;
    final job = GalleryDownloadProgress(item);
    _jobs[item.id()] = job;
    job.finished = queue.submit(item.id(), () => _run(job, recover));
    // Failures are stored in the item, so callers do not need to await completion.
    unawaited(job.finished!.catchError((Object error) {
      debugPrint('Download failed: $error');
    }));
  }

  Future<void> _run(GalleryDownloadProgress job, bool recover) async {
    if (job.cancelled) return;
    final routine = DownloadRoutine(job.item, job.changed, job.changed, shouldCancel: () => job.cancelled);
    job.routine = routine;
    final clock = Stopwatch()..start();
    var lastTime = 0;
    var lastBytes = 0.0;
    final timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = clock.elapsedMilliseconds;
      final elapsed = now - lastTime;
      if (elapsed > 0) job.bytesPerSecond = (job.bytes - lastBytes) * 1000 / elapsed;
      lastBytes = job.bytes;
      lastTime = now;
      job.changed();
    });
    try {
      await job.item.update();
      await routine.selectExtractor();
      await routine.createTasks(progressCallback: (current, total) async {
        job.extracted = current;
        job.total = total;
      });
      if (job.cancelled) return;
      if (job.item.state() >= 5) return;
      if (await routine.checkNothingToDownload()) return;
      await routine.extractFilePath();
      job.total = routine.tasks!.length;
      job.completed = 0;

      void complete() => job.completed++;
      void bytes(double value) => job.bytes += value;
      void error(String message) => job.completed++;
      Future<void> wait() async {
        while (!job.cancelled && job.completed < job.total) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      // Reuse complete files on retry; only missing/invalid pages are submitted.
      final missing = await routine.checkDownloadFiles();
      if (job.cancelled) return;
      job.completed = job.total - missing.length;
      if (!recover || missing.isNotEmpty) {
        await routine.retryInvalidDownloadFiles(missing,
          completeCallback: complete, downloadCallback: bytes, errorCallback: error);
        await wait();
      }
      for (var attempt = 0; attempt < 2 && !job.cancelled; attempt++) {
        final invalid = await routine.checkDownloadFiles();
        if (job.cancelled) return;
        if (invalid.isEmpty) break;
        job.completed = job.total - invalid.length;
        await routine.retryInvalidDownloadFiles(invalid,
          completeCallback: complete, downloadCallback: bytes, errorCallback: error);
        await wait();
      }
      if (job.cancelled) return;
      if ((await routine.checkDownloadFiles()).isNotEmpty) {
        await routine.setFailed('일부 페이지를 받지 못했습니다. 재시도하면 누락된 페이지를 받습니다.');
      } else {
        await routine.setDownloadComplete();
        completed.value = job.item;
      }
    } catch (error) {
      if (!job.cancelled) await routine.setFailed(error.toString());
    } finally {
      timer.cancel();
      clock.stop();
      job.routine = null;
      job.bytesPerSecond = 0;
      job.changed();
      changes.value++;
    }
  }

  Future<void> delete(DownloadItemModel item) async {
    final job = _jobs[item.id()];
    if (job != null && queue.contains(item.id())) {
      job.cancelled = true;
      queue.cancelPending(item.id());
      final taskIds = job.routine?.submittedTaskIds;
      if (taskIds != null) {
        final downloader = await IsolateDownloader.getInstance();
        for (final id in taskIds) {
          downloader.cancel(id);
        }
      }
      await job.finished;
    }
    if (item.state() == 0) {
      for (final filename in item.rawFiles()) {
        final file = File(filename);
        if (await file.exists()) await file.delete();
      }
    }
    await item.delete();
    _jobs.remove(item.id());
    await (await Download.getInstance()).refresh();
    changes.value++;
  }
}
