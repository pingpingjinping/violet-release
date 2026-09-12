// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';
import 'package:violet/services/server_config.dart';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:violet/database/database.dart';
import 'package:violet/log/log.dart';
import 'package:violet/version/sync.dart';

/// Complete Korean snapshots have their own version, separate from bookmarks
/// and incremental chunk synchronization. User databases are never replaced.
class ContentDbSync {
  static Future<bool>? _inFlight;
  static bool _checkedThisSession = false;

  static Future<bool> startup({
    required bool Function() canApply,
    void Function(String stage, int received, int total)? onProgress,
  }) async {
    if (_checkedThisSession) return false;
    _checkedThisSession = true;
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('auto_content_db_update') ?? true)) return false;
    return _inFlight ??= _exchange(canApply, onProgress).whenComplete(() {
      _inFlight = null;
    });
  }

  static Future<bool> _exchange(
    bool Function() canApply,
    void Function(String stage, int received, int total)? onProgress,
  ) async {
    File? temporary;
    final client = http.Client();
    try {
      if (!Platform.isIOS && !Platform.isAndroid && !Platform.isMacOS) {
        return false;
      }
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt('db_exists') != 1 ||
          prefs.getString('databasetype') == 'dummy') {
        return false;
      }
      onProgress?.call('DB 최신 버전 확인 중', 0, 0);
      final manifest = await client
          .get(Uri.parse(SyncManager.syncInfoURL('main')))
          .timeout(const Duration(seconds: 10));
      if (manifest.statusCode != 200) return false;
      final lines = manifest.body.split('\n').reversed;
      int? version;
      Uri? download;
      for (final line in lines) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 3 || fields.first != 'db') continue;
        version = int.tryParse(fields[1]);
        download = Uri.tryParse(ServerConfig.downloadUrl('${fields[2]}-korean.db', ServerConfig.webBase));
        break;
      }
      if (version == null ||
          version <= 0 ||
          download == null ||
          !['http', 'https'].contains(download.scheme))
        return false;
      if ((prefs.getString('content-snapshot-server') ?? ServerConfig.defaultUrl) == ServerConfig.webBase &&
          (prefs.getInt('content-snapshot-version') ??
              prefs.getInt('synclatest')) ==
          version) {
        return false;
      }
      if (!canApply()) return false;
      final manager = await DataBaseManager.getInstance();
      final destination = File(manager.dbPath!);
      temporary = File('${destination.path}.updating');
      onProgress?.call('DB 다운로드 중', 0, 0);
      var lastProgress = 0;
      await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(minutes: 2),
        ),
      ).download(
        download.toString(),
        temporary.path,
        onReceiveProgress: (received, total) {
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - lastProgress >= 100 || received == total) {
            lastProgress = now;
            onProgress?.call('DB 다운로드 중', received, total);
          }
        },
      );
      onProgress?.call('DB 검사 중', 0, 0);
      final candidate = await openDatabase(
        temporary.path,
        readOnly: true,
        singleInstance: false,
      );
      try {
        final check = await candidate.rawQuery('PRAGMA quick_check');
        final count = await candidate.rawQuery(
          'SELECT COUNT(*) AS count FROM HitomiColumnModel',
        );
        if (check.isEmpty ||
            check.first.values.first != 'ok' ||
            (count.first['count'] as int) == 0) {
          throw StateError('Invalid content snapshot');
        }
      } finally {
        await candidate.close();
      }
      onProgress?.call('DB 적용 중', 0, 0);
      if (!canApply()) return false;
      await DataBaseManager.instanceLock.synchronized(() async {
        await DataBaseManager.openLock.synchronized(() async {
          await DataBaseManager.reloadInstance();
          final wal = File('${destination.path}-wal');
          if (await wal.exists() && await wal.length() > 0) {
            throw StateError('Content database is still in use');
          }
          for (final suffix in ['-wal', '-shm']) {
            final sidecar = File('${destination.path}$suffix');
            if (await sidecar.exists()) await sidecar.delete();
          }
          await temporary!.rename(destination.path);
        });
      });
      onProgress?.call('검색 데이터 준비 중', 0, 0);
      await manager.checkOpen();
      await prefs.setString('content-snapshot-server', ServerConfig.webBase);
      await prefs.setInt('content-snapshot-version', version);
      await prefs.setInt('synclatest', version);
      await prefs.setString(
        'databasesync',
        DateTime.fromMillisecondsSinceEpoch(version * 1000).toString(),
      );
      return true;
    } catch (error) {
      Logger.error('[ContentDbSync] Update failed; retry on next launch');
      return false;
    } finally {
      client.close();
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {
        Logger.error('[ContentDbSync] Could not remove temporary snapshot');
      }
    }
  }
}
