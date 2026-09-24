// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

part of '../isolate_downloader.dart';

enum SendPortType { init, append, cancel, terminate, tasksize, test }

class SendPortData {
  final dynamic data;
  final SendPortType type;

  const SendPortData({required this.type, this.data});
}

enum ReceivePortType { append, progresss, error, complete, retry }

class ReceivePortData {
  final dynamic data;
  final ReceivePortType type;

  const ReceivePortData({required this.type, this.data});
}

class IsolateDownloaderTask {
  final int id;
  final String url;
  final String fullpath;
  final Map<String, dynamic> header;

  CancelToken? cancelToken;

  IsolateDownloaderTask({
    required this.id,
    required this.url,
    required this.fullpath,
    required this.header,
  });

  static IsolateDownloaderTask fromDownloadTask(int taskId, DownloadTask task) {
    var header = <String, String>{};
    if (task.referer != null) header['referer'] = task.referer!;
    if (task.accept != null) header['accept'] = task.accept!;
    if (task.userAgent != null) header['user-agent'] = task.userAgent!;
    if (task.headers != null) {
      for (var element in task.headers!.entries) {
        header[element.key.toLowerCase()] = element.value;
      }
    }
    return IsolateDownloaderTask(
      id: taskId,
      url: task.url!,
      fullpath: task.downloadPath!,
      header: header,
    );
  }

  @override
  String toString() {
    return jsonEncode({
      'id': id,
      'url': url,
      'fullpath': fullpath,
      'header': header,
    });
  }
}

class IsolateDownloaderOption {
  final int threadCount;
  final int maxRetryCount;

  IsolateDownloaderOption({
    required this.threadCount,
    required this.maxRetryCount,
  });
}

class IsolateDownloaderProgressProtocolUnit {
  final int id;
  final int countSize;
  final int totalSize;

  IsolateDownloaderProgressProtocolUnit({
    required this.id,
    required this.countSize,
    required this.totalSize,
  });
}

class IsolateDownloaderErrorUnit {
  final int id;
  final String error;
  final String stackTrace;

  IsolateDownloaderErrorUnit({
    required this.id,
    required this.error,
    required this.stackTrace,
  });
}

int _taskCurrentCount = 0;
int _maxTaskCount = 0;
late int _maxRetryCount;
late SendPort _sendPort;
late Queue<IsolateDownloaderTask> _dqueue;
late Map<int, IsolateDownloaderTask> _workingMap;

Future<void> _processTask(IsolateDownloaderTask task) async {
  _sendPort.send(ReceivePortData(type: ReceivePortType.append, data: task.id));

  var options = BaseOptions(
    contentType: Headers.formUrlEncodedContentType,
    validateStatus: (status) => true,
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
  );
  var dio = Dio(options);

  for (var kv in task.header.entries) {
    dio.options.headers[kv.key] = kv.value;
  }

  // dio.interceptors.add(DioCacheManager(
  //   CacheConfig(
  //     skipDiskCache: true,
  //     maxMemoryCacheCount: 1000,
  //   ),
  // ).interceptor as Interceptor);

  try {
    var retryCount = 0;
    var finished = false;

    Future<bool> scheduleRetry({
      required int code,
      String? reason,
    }) async {
      if (retryCount >= _maxRetryCount) {
        return false;
      }

      retryCount++;
      _sendPort.send(
        ReceivePortData(
          type: ReceivePortType.retry,
          data: {
            'id': task.id,
            'url': task.url,
            'count': retryCount,
            'code': code,
            if (reason != null) 'reason': reason,
          },
        ),
      );

      // Back off a little so a stalled endpoint is not hammered repeatedly.
      await Future.delayed(const Duration(milliseconds: 500));
      return true;
    }

    while (!finished) {
      try {
        final res = await dio.download(
          task.url,
          task.fullpath,
          cancelToken: task.cancelToken,
          deleteOnError: true,
          onReceiveProgress: (count, total) {
            _sendPort.send(
              ReceivePortData(
                type: ReceivePortType.progresss,
                data: IsolateDownloaderProgressProtocolUnit(
                  id: task.id,
                  countSize: count,
                  totalSize: total,
                ),
              ),
            );
          },
        );

        if (res.statusCode == 200) {
          final file = File(task.fullpath);
          if (await file.exists() && await file.length() != 0) {
            _sendPort.send(
              ReceivePortData(type: ReceivePortType.complete, data: task.id),
            );
            finished = true;
            break;
          }
          if (await file.exists()) {
            await file.delete();
          }

          if (!await scheduleRetry(code: 200, reason: 'empty_file')) {
            break;
          }
          continue;
        }

        // 503 is normally temporary, so retry it just like a network stall.
        if (res.statusCode == 503) {
          if (!await scheduleRetry(
            code: 503,
            reason: 'service_unavailable',
          )) {
            break;
          }
          continue;
        }

        _sendPort.send(
          ReceivePortData(
            type: ReceivePortType.error,
            data: IsolateDownloaderErrorUnit(
              id: task.id,
              error: 'Code ${res.statusCode}',
              stackTrace: '',
            ),
          ),
        );
        finished = true;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          finished = true;
          break;
        }

        final retryable =
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.connectionError;

        if (!retryable) {
          rethrow;
        }

        if (!await scheduleRetry(code: -1, reason: e.type.name)) {
          break;
        }
      }
    }

    if (!finished) {
      _sendPort.send(
        ReceivePortData(
          type: ReceivePortType.error,
          data: IsolateDownloaderErrorUnit(
            id: task.id,
            error: 'Too many retries ($_maxRetryCount)',
            stackTrace: '',
          ),
        ),
      );
    }
  } catch (e, st) {
    _sendPort.send(
      ReceivePortData(
        type: ReceivePortType.error,
        data: IsolateDownloaderErrorUnit(
          id: task.id,
          error: e.toString(),
          stackTrace: st.toString(),
        ),
      ),
    );
  }
  _taskCurrentCount -= 1;
  _workingMap.remove(task.id);
  _resolveQueue();
}

void _resolveQueue() {
  if (_dqueue.isEmpty) return;
  if (_taskCurrentCount < _maxTaskCount) {
    _taskCurrentCount += 1;
    final itask = _dqueue.removeFirst();
    _workingMap[itask.id] = itask;
    _processTask(itask);
  }
}

void _appendTask(IsolateDownloaderTask task) {
  var token = CancelToken();
  task.cancelToken = token;
  _dqueue.add(task);
  _resolveQueue();
}

void _initIsolateDownloader(IsolateDownloaderOption option) {
  _dqueue = Queue<IsolateDownloaderTask>();
  _workingMap = <int, IsolateDownloaderTask>{};
  _maxTaskCount = option.threadCount;
  _maxRetryCount = option.maxRetryCount.clamp(1, 100).toInt();
}

void _cancelTask(int taskId) {
  _dqueue.removeWhere((task) => task.id == taskId);
  _workingMap[taskId]?.cancelToken?.cancel();
}

/// cancel all tasks and remove dqueue
void _terminate() {
  _dqueue.clear();
  for (var value in _workingMap.values) {
    value.cancelToken!.cancel();
  }
}

void _modifyTaskPoolSize(int sz) {
  _maxTaskCount = sz;
}

void _downloadIsolateRoutine(SendPort sendPort) {
  final ReceivePort receivePort = ReceivePort();
  sendPort.send(receivePort.sendPort);
  _sendPort = sendPort;

  receivePort.listen((dynamic message) async {
    if (message is SendPortData) {
      switch (message.type) {
        case SendPortType.init:
          _initIsolateDownloader(message.data as IsolateDownloaderOption);
          break;
        case SendPortType.append:
          _appendTask(message.data as IsolateDownloaderTask);
          break;
        case SendPortType.cancel:
          _cancelTask(message.data as int);
          break;
        case SendPortType.terminate:
          _terminate();
          break;
        case SendPortType.tasksize:
          _modifyTaskPoolSize(message.data as int);
          break;
        case SendPortType.test:
          // ignore: unused_local_variable
          var ttask = message.data as List<String>;
          break;
      }
    }
  });
}
