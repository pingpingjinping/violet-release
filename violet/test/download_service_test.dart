import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/downloadable.dart';
import 'package:violet/downloader/isolate_downloader.dart';
import 'package:violet/services/download_work_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Work starts without a download page, runs two galleries and holds the screen until idle',
    () async {
      final wake = <bool>[];
      final first = Completer<void>();
      final second = Completer<void>();
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final thirdStarted = Completer<void>();
      final order = <int>[];
      final queue = DownloadWorkQueue(
        keepAwake: (value) async {
          wake.add(value);
        },
      );
      final a = queue.submit(1, () async {
        order.add(1);
        firstStarted.complete();
        await first.future;
      });
      final duplicate = queue.submit(1, () async {
        fail('duplicate gallery ran');
      });
      final b = queue.submit(2, () async {
        order.add(2);
        secondStarted.complete();
        await second.future;
      });
      final c = queue.submit(3, () async {
        order.add(3);
        thirdStarted.complete();
      });

      expect(duplicate, same(a));
      await Future.wait([firstStarted.future, secondStarted.future]);
      expect(order, [1, 2]);
      expect(queue.activeIds, {1, 2});
      expect(queue.pendingCount, 1);
      expect(wake, [true]);

      first.complete();
      await thirdStarted.future;
      expect(order, [1, 2, 3]);
      expect(queue.activeIds.contains(2), true);

      second.complete();
      await Future.wait([a, b, c]);
      await Future<void>.delayed(Duration.zero);
      expect(queue.totalCount, 0);
      expect(wake, [true, false]);
      queue.dispose();
    },
  );

  test(
    'A failed gallery releases the screen and does not block the next gallery',
    () async {
      final wake = <bool>[];
      var secondRan = false;
      final queue = DownloadWorkQueue(
        keepAwake: (value) async {
          wake.add(value);
        },
      );
      final failed = queue.submit(1, () async {
        throw StateError('failed');
      });
      final checked = expectLater(failed, throwsStateError);
      final next = queue.submit(2, () async {
        secondRan = true;
      });
      await checked;
      await next;
      await Future<void>.delayed(Duration.zero);
      expect(secondRan, true);
      expect(wake, [true, false]);
      queue.dispose();
    },
  );

  test(
    'A request arriving while the screen lock releases is not lost',
    () async {
      final releasing = Completer<void>();
      final release = Completer<void>();
      var firstRelease = true, secondRan = false;
      final wake = <bool>[];
      final queue = DownloadWorkQueue(
        keepAwake: (value) async {
          wake.add(value);
          if (!value && firstRelease) {
            firstRelease = false;
            releasing.complete();
            await release.future;
          }
        },
      );
      await queue.submit(1, () async {});
      await releasing.future;
      final second = queue.submit(2, () async {
        secondRan = true;
      });
      release.complete();
      await second;
      await Future<void>.delayed(Duration.zero);
      expect(secondRan, true);
      expect(wake, [true, false, true, false]);
      queue.dispose();
    },
  );

  test('Platform screen-lock errors do not prevent downloading', () async {
    var ran = false;
    final queue = DownloadWorkQueue(
      keepAwake: (_) async {
        throw StateError('platform');
      },
    );
    await queue.submit(1, () async {
      ran = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(ran, true);
    expect(queue.totalCount, 0);
    queue.dispose();
  });

  test(
    'Removing pending work completes immediately without waiting for active galleries',
    () async {
      final first = Completer<void>();
      final second = Completer<void>();
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      var removedRan = false;
      final queue = DownloadWorkQueue(keepAwake: (_) async {});
      final activeA = queue.submit(1, () async {
        firstStarted.complete();
        await first.future;
      });
      final activeB = queue.submit(2, () async {
        secondStarted.complete();
        await second.future;
      });
      final pending = queue.submit(3, () async {
        removedRan = true;
      });

      await Future.wait([firstStarted.future, secondStarted.future]);
      expect(queue.cancelPending(3), true);
      await pending;
      expect(removedRan, false);
      expect(queue.contains(3), false);
      expect(queue.activeIds, {1, 2});

      first.complete();
      second.complete();
      await Future.wait([activeA, activeB]);
      await Future<void>.delayed(Duration.zero);
      queue.dispose();
    },
  );

  test(
    'Real downloader cancels queued files and retry byte counts start from zero',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'violet-download-test-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstRequest = Completer<void>();
      final release = Completer<void>();
      final requested = <String>[];
      final serving = server.listen((request) async {
        requested.add(request.uri.path);
        if (request.uri.path == '/slow') {
          firstRequest.complete();
          await release.future;
        }
        request.response.add(List<int>.filled(8192, 42));
        await request.response.close();
      });
      final downloader = IsolateDownloader();
      try {
        await downloader.init();
        while (!downloader.isReady()) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        downloader.changeThreadCount(1);
        final completed = Completer<void>();
        final first = DownloadTask(
          url: 'http://127.0.0.1:${server.port}/slow',
          downloadPath: '${root.path}/first',
          headers: {},
        );
        first.completeCallback = () {
          completed.complete();
        };
        final cancelled = DownloadTask(
          url: 'http://127.0.0.1:${server.port}/cancelled',
          downloadPath: '${root.path}/cancelled',
          headers: {},
        );
        downloader.appendTasks([first, cancelled]);
        await firstRequest.future;
        downloader.cancel(cancelled.taskId);
        expect(
          downloader.getStatus(cancelled.taskId).state,
          DownloadTaskState.cancel,
        );
        release.complete();
        await completed.future.timeout(const Duration(seconds: 10));
        expect(await File(first.downloadPath!).length(), 8192);
        final retryDone = Completer<void>();
        var received = 0.0;
        final retry = DownloadTask(
          url: 'http://127.0.0.1:${server.port}/retry',
          downloadPath: '${root.path}/retry',
          headers: {},
        );
        retry.accDownloadSize = 8192;
        retry.isSizeEnsued = true;
        retry.completeCallback = () {
          retryDone.complete();
        };
        retry.downloadCallback = (bytes) {
          received += bytes;
        };
        downloader.appendTask(retry);
        await retryDone.future.timeout(const Duration(seconds: 10));
        expect(received, 8192);
        expect(requested, ['/slow', '/retry']);
        expect(await File(cancelled.downloadPath!).exists(), false);
      } finally {
        if (!release.isCompleted) release.complete();
        downloader.close();
        await serving.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    },
  );
}
