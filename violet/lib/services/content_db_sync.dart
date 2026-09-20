// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:violet/services/server_config.dart';
import 'package:violet/settings/settings.dart';

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
  static const lastSuccessfulSyncKey = 'content-snapshot-synced-at';

  static Future<bool>? _inFlight;
  static bool _checkedThisSession = false;

  static Future<bool> startup({
    required bool Function() canApply,
    void Function(String stage, int received, int total)? onProgress,
  }) async {
    if (_checkedThisSession) return false;
    _checkedThisSession = true;
    final prefs = await SharedPreferences.getInstance();

    // Keep Pi's ExHentai cookie in sync with the cookie captured by the app.
    // Do not block the content DB check/download if the Pi is unreachable.
    unawaited(_syncEhCookieToPi(prefs));

    if (!(prefs.getBool('auto_content_db_update') ?? true)) return false;
    return _inFlight ??= _exchange(canApply, onProgress).whenComplete(() {
      _inFlight = null;
    });
  }

  static Future<void> _syncEhCookieToPi(SharedPreferences prefs) async {
    final cookie = prefs.getString('eh_cookies')?.trim();
    if (cookie == null || cookie.isEmpty) return;

    final syncToken = prefs.getString('bookmark_sync_token')?.trim() ?? '';
    final syncBase = prefs.getString('bookmark_sync_server')?.trim() ?? '';
    if (syncToken.isEmpty || syncBase.isEmpty) return;

    final client = http.Client();
    try {
      final base = ServerConfig.apiBase(ServerConfig.webBase);
      final baseUri = Uri.parse(base);
      if (!_isLocalOrPrivateHost(baseUri.host)) return;

      final syncUri = Uri.parse(ServerConfig.normalize(syncBase));
      if (syncUri.host != baseUri.host) return;

      final uri = Uri.parse(
        ServerConfig.endpoint(base, 'api/settings/exhentai-cookie'),
      );

      final response = await client
          .put(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'X-Violet-Sync-Token': syncToken,
            },
            body: jsonEncode({'cookie': cookie}),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        Logger.error(
          '[ContentDbSync] ExHentai cookie sync failed: '
          'HTTP ${response.statusCode}',
        );
      }
    } catch (_) {
      // Cookie sync is best-effort. A Pi/network failure must not delay or
      // prevent the normal startup DB synchronization.
      Logger.error('[ContentDbSync] ExHentai cookie sync failed');
    } finally {
      client.close();
    }
  }

  static bool _isLocalOrPrivateHost(String host) {
    if (host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.endsWith('.local') ||
        host.startsWith('192.168.') ||
        host.startsWith('10.')) {
      return true;
    }

    final parts = host.split('.');
    if (parts.length != 4 || parts[0] != '172') return false;
    final second = int.tryParse(parts[1]);
    return second != null && second >= 16 && second <= 31;
  }

  /// Checks the snapshot advertised by the configured content server.
  /// Unlike [startup], this can be called repeatedly while a Pi export is
  /// being regenerated.
  static Future<int?> remoteVersion() async {
    final client = http.Client();
    try {
      final response = await client
          .get(Uri.parse(SyncManager.syncInfoURL('main')))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw HttpException(
          'Snapshot manifest returned HTTP ${response.statusCode}',
        );
      }
      for (final line in response.body.split('\n').reversed) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 3 || fields.first != 'db') continue;
        final version = int.tryParse(fields[1]);
        if (version != null && version > 0) return version;
      }
      throw const FormatException('Snapshot manifest has no database entry');
    } finally {
      client.close();
    }
  }

  /// Runs the normal validated download-and-replace flow on demand.
  /// Manual callers receive failures instead of silently deferring them until
  /// the next launch.
  static Future<bool> manual({
    required bool Function() canApply,
    void Function(String stage, int received, int total)? onProgress,
  }) {
    return _inFlight ??= _exchange(canApply, onProgress, rethrowErrors: true)
        .whenComplete(() {
          _inFlight = null;
        });
  }

  static Future<bool> _exchange(
    bool Function() canApply,
    void Function(String stage, int received, int total)? onProgress, {
    bool rethrowErrors = false,
  }) async {
    File? temporary;
    final client = http.Client();
    try {
      if (!Platform.isIOS && !Platform.isAndroid && !Platform.isMacOS) {
        return false;
      }
      final prefs = await SharedPreferences.getInstance();
      final databaseType =
          prefs.getString('databasetype') ?? Settings.databaseType.value;
      if (prefs.getInt('db_exists') != 1 || databaseType == 'dummy') {
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
        download = Uri.tryParse(
          ServerConfig.downloadUrl(
            '${fields[2]}${SyncManager.createRawdbPostfixiOS(databaseType)}',
            ServerConfig.webBase,
          ),
        );
        break;
      }
      if (version == null ||
          version <= 0 ||
          download == null ||
          !['http', 'https'].contains(download.scheme))
        return false;
      if ((prefs.getString('content-snapshot-server') ??
                  ServerConfig.defaultUrl) ==
              ServerConfig.webBase &&
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
      await prefs.setInt(
        lastSuccessfulSyncKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      return true;
    } catch (error) {
      Logger.error('[ContentDbSync] Update failed; retry on next launch');
      if (rethrowErrors) rethrow;
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
