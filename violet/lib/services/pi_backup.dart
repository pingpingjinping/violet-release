import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:violet/database/user/user.dart';
import 'package:violet/database/user/record.dart';
import 'package:violet/services/activity_sync.dart';
import 'package:violet/services/backup_codec.dart';
import 'package:violet/services/bookmark_sync.dart';
import 'package:violet/services/server_config.dart';
import 'package:violet/settings/settings.dart';

class PiBackup {
  static Future<(String, Map<String, String>)> _connection() async {
    final prefs = await SharedPreferences.getInstance();
    final base = prefs.getString('bookmark_sync_server') ?? '';
    final token = prefs.getString('bookmark_sync_token') ?? '';
    if (base.isEmpty || token.isEmpty)
      throw const FormatException('앱·웹 기록 동기화 설정에 개인 서버 주소와 토큰을 먼저 저장해 주세요.');
    return (ServerConfig.normalize(base), {'X-Violet-Sync-Token': token});
  }

  static Future<Map<String, dynamic>> snapshot() async {
    await ActivitySync.load();
    final prefs = await SharedPreferences.getInstance();
    var userId = prefs.getString('fa_userid') ?? '';
    if (userId.isEmpty) {
      userId = const Uuid().v4();
      await prefs.setString('fa_userid', userId);
      Settings.userAppId = userId;
    }
    final manager = await CommonUserDatabase.getInstance();
    await manager.checkOpen();
    final tables = await manager.db!.transaction((txn) async {
      final names = (await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((r) => r['name']).toSet();
      final result = <String, List<Map<String, dynamic>>>{};
      for (final name in backupColumns.keys) {
        if (names.contains(name))
          result[name] = (await txn.query(
            name,
          )).map((r) => Map<String, dynamic>.from(r)).toList();
      }
      final device =
          prefs.getString('activity_sync_device') ?? 'backup-$userId';
      if (names.contains('DownloadItem')) {
        final rows = await txn.query(
          'DownloadItem',
          columns: ['URL', 'DateTime'],
          where: 'State=?',
          whereArgs: [0],
        );
        final shared = result['SharedActivity'] ??= [];
        for (final row in rows) {
          final article = row['URL']?.toString() ?? '';
          final timestamp = ActivitySync.timeOf(row['DateTime']);
          if (!RegExp(r'^\d{1,20}$').hasMatch(article) || timestamp <= 0)
            continue;
          shared.add({
            'Kind': 'download',
            'Device': device,
            'Article': article,
            'Origin': 'app',
            'Timestamp': timestamp,
            'Page': 0,
            'Type': 0,
          });
        }
      }
      return result;
    });
    return {
      'schema': 1,
      'userAppId': userId,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'tables': tables,
    };
  }

  static void _check(http.Response response) {
    if (response.statusCode == 200) return;
    if (response.statusCode == 401)
      throw const FormatException('개인 서버 토큰이 맞지 않습니다.');
    if ([404, 405].contains(response.statusCode))
      throw const FormatException('서버에 전체 백업 기능이 없습니다. Pi 서버 업데이트가 필요합니다.');
    if ([400, 413].contains(response.statusCode))
      throw const FormatException('서버가 백업 파일을 거부했습니다. 형식과 용량을 확인해 주세요.');
    throw FormatException('서버 오류: HTTP ${response.statusCode}');
  }

  static Future<Map<String, dynamic>> create() async {
    final (base, headers) = await _connection();
    final payload = await snapshot();
    final data = await compute(encodeBackup, payload);
    final client = http.Client();
    try {
      final response = await client
          .post(
            Uri.parse(ServerConfig.endpoint(base, 'api/backups')),
            headers: {
              ...headers,
              'Content-Type': 'application/gzip',
              'X-Violet-User-App-Id': payload['userAppId'] as String,
            },
            body: data,
          )
          .timeout(const Duration(minutes: 2));
      _check(response);
      return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } finally {
      client.close();
    }
  }

  static Future<List<Map<String, dynamic>>> listing() async {
    final (base, headers) = await _connection();
    final client = http.Client();
    try {
      final response = await client
          .get(
            Uri.parse(ServerConfig.endpoint(base, 'api/backups')),
            headers: headers,
          )
          .timeout(const Duration(seconds: 15));
      _check(response);
      final rows = (jsonDecode(response.body)['backups'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      for (final row in rows) {
        if (row['id'] is! String ||
            !RegExp(r'^[0-9a-f-]{36}$').hasMatch(row['id'] as String) ||
            row['createdAt'] is! int ||
            row['size'] is! int ||
            row['userAppId'] is! String ||
            row['sha256'] is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(row['sha256'] as String)) {
          throw const FormatException('서버의 백업 목록 형식이 올바르지 않습니다.');
        }
      }
      return rows;
    } finally {
      client.close();
    }
  }

  static Future<Map<String, dynamic>> _download(
    Map<String, dynamic> meta,
  ) async {
    final (base, headers) = await _connection();
    final id = meta['id'] as String;
    if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id))
      throw const FormatException('잘못된 백업 ID입니다.');
    final client = http.Client();
    try {
      final request = http.Request(
        'GET',
        Uri.parse(ServerConfig.endpoint(base, 'api/backups/$id')),
      )..headers.addAll(headers);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        _check(http.Response('', response.statusCode));
      }
      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        length += chunk.length;
        if (length > maxBackupCompressed)
          throw const FormatException('압축 백업이 너무 큽니다.');
        bytes.add(chunk);
      }
      final data = bytes.takeBytes();
      if (sha256.convert(data).toString() != meta['sha256'])
        throw const FormatException('백업 파일 검사에 실패했습니다.');
      final payload = await compute(decodeBackup, data);
      if (payload['userAppId'] != meta['userAppId'])
        throw const FormatException('백업 ID 정보가 파일과 일치하지 않습니다.');
      return payload;
    } finally {
      client.close();
    }
  }

  static Future<String> restore(
    Map<String, dynamic> meta,
  ) => BookmarkSync.operationLock.synchronized(() async {
    final payload = await _download(meta);
    // Keep a local rollback copy even if the network subsequently fails.
    final current = await snapshot();
    final packed = await compute(encodeBackup, current);
    final directory = await getApplicationDocumentsDirectory();
    final rollback = File(
      '${directory.path}/before-restore-${DateTime.now().microsecondsSinceEpoch}.json.gz',
    );
    await rollback.writeAsBytes(packed, flush: true);
    // A remote rollback copy is mandatory before replacing any local records.
    await create();
    final manager = await CommonUserDatabase.getInstance();
    final prefs = await SharedPreferences.getInstance();
    final oldId = prefs.getString('fa_userid');
    final oldAuto = prefs.getBool('auto_record_sync') ?? true;
    if (!await prefs.setBool('auto_record_sync', false))
      throw const FormatException('동기화 설정 저장에 실패했습니다.');
    try {
      if (!await prefs.setString('fa_userid', payload['userAppId'] as String))
        throw const FormatException('User App ID 저장에 실패했습니다.');
      await restoreBackupTables(manager.db!, payload);
    } catch (_) {
      if (oldId == null) {
        await prefs.remove('fa_userid');
      } else {
        await prefs.setString('fa_userid', oldId);
      }
      await prefs.setBool('auto_record_sync', oldAuto);
      rethrow;
    }
    Settings.userAppId = payload['userAppId'] as String;
    (await User.getInstance()).clearCache();
    try {
      await ActivitySync.reload();
    } catch (_) {
      ActivitySync.records.value =
          ((payload['tables'] as Map)['SharedActivity'] as List? ?? [])
              .map((row) => Map<String, dynamic>.from(row as Map))
              .toList();
    }
    BookmarkSync.changes.value++;
    return rollback.path;
  });
}

Future<void> restoreBackupTables(
  Database db,
  Map<String, dynamic> payload,
) async {
  validateBackup(payload);
  final tables = payload['tables'] as Map;
  await db.transaction((txn) async {
    final existing = (await txn.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    )).map((r) => r['name']).toSet();
    for (final name in tables.keys) {
      if (!existing.contains(name))
        throw FormatException('기기에 필요한 백업 테이블이 없습니다: $name');
    }
    for (final name in backupColumns.keys.toList().reversed) {
      if (tables.containsKey(name)) await txn.delete(name);
    }
    final batch = txn.batch();
    for (final name in backupColumns.keys) {
      for (final row in tables[name] as List? ?? []) {
        batch.insert(
          name,
          Map<String, Object?>.from(row as Map),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
    if (existing.contains('BookmarkSyncMeta')) batch.delete('BookmarkSyncMeta');
    await batch.commit(noResult: true);
  });
}
