import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:synchronized/synchronized.dart';
import 'package:violet/database/database.dart';
import 'package:violet/database/query.dart';
import 'package:violet/database/user/user.dart';
import 'package:violet/services/server_config.dart';
import 'package:violet/settings/settings.dart';

/// Opportunistic repair only from metadata already obtained during extraction.
class MetadataRepair {
  static final lock = Lock();
  static const _table = 'MetadataRepairQueue';

  static bool missing(Object? value) =>
      value == null ||
      [
        '',
        'n/a',
        'na',
      ].contains(value.toString().trim().replaceAll('|', '').toLowerCase());

  static List<String> cleanTags(Iterable<dynamic> values) => values
      .whereType<String>()
      .map((v) => v.trim())
      .where(
        (v) =>
            !missing(v) &&
            v.length <= 200 &&
            !v.contains('|') &&
            !v.codeUnits.any((c) => c < 32),
      )
      .toSet()
      .take(100)
      .toList();

  static List<String> hitomiTags(dynamic values, String key) => values is List
      ? cleanTags(values.map((v) => v is Map ? v[key] : null))
      : [];

  static Future<Database> _queue() async {
    final manager = await CommonUserDatabase.getInstance();
    await manager.checkOpen();
    final db = manager.db!;
    await db.execute(
      'CREATE TABLE IF NOT EXISTS $_table ('
      'Key TEXT PRIMARY KEY, Server TEXT NOT NULL, Payload TEXT NOT NULL, '
      'Acknowledged INTEGER NOT NULL DEFAULT 0)',
    );
    return db;
  }

  static Future<Map<String, Object?>?> _row(
    DatabaseExecutor db,
    Map<String, dynamic> p,
  ) async {
    final rows = await db.rawQuery(
      'SELECT Artists, "Groups", EHash, ExistOnHitomi FROM HitomiColumnModel '
      "WHERE Id=? AND Files=? AND LOWER(TRIM(Language))='korean' LIMIT 1",
      [p['id'], p['pages']],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    if (p['source'] == 'hitomi' && row['ExistOnHitomi'] != 1) return null;
    if (p['source'] == 'eh' && row['EHash'] != p['token']) return null;
    return row;
  }

  static Map<String, Object?> _changes(
    Map<String, Object?> row,
    Map<String, dynamic> p,
  ) {
    final result = <String, Object?>{};
    for (final pair in [('Artists', 'artists'), ('Groups', 'groups')]) {
      final tags = cleanTags(p[pair.$2] as List);
      if (missing(row[pair.$1]) && tags.isNotEmpty) {
        result[pair.$1] = '|' + tags.join('|') + '|';
      }
    }
    return result;
  }

  static Future<void> _write(
    DatabaseExecutor db,
    int id,
    Map<String, Object?> changes,
  ) async {
    final fields = ['Artists', 'Groups'].where(changes.containsKey).toList();
    if (fields.isEmpty) return;
    final set = fields.map((field) => '"' + field + '"=?').join(',');
    await db.rawUpdate('UPDATE HitomiColumnModel SET ' + set + ' WHERE Id=?', [
      ...fields.map((field) => changes[field]),
      id,
    ]);
  }

  static Future<void> capture(
    QueryResult qr, {
    required String source,
    required int id,
    required int pages,
    required Iterable<dynamic> artists,
    required Iterable<dynamic> groups,
    required bool korean,
    String? token,
  }) async {
    // Never let best-effort maintenance break reading/downloads.
    try {
      if (!korean || id != qr.id() || pages <= 0 || pages >= 100000) return;
      if (source == 'eh' &&
          (token == null || !RegExp(r'^[0-9a-fA-F]{10}$').hasMatch(token)))
        return;
      final a = cleanTags(artists);
      final g = cleanTags(groups);
      if (a.isEmpty && g.isEmpty) return;
      await lock.synchronized(() async {
        final server = ServerConfig.webBase;
        if (server.isEmpty ||
            (Settings.prefs.getString('content-snapshot-server') ?? server) !=
                server)
          return;
        final p = <String, dynamic>{
          'id': id,
          'pages': pages,
          'source': source,
          'token': token,
          'artists': a,
          'groups': g,
        };
        final manager = await DataBaseManager.getInstance();
        await manager.checkOpen();
        final db = manager.db!;
        await db.transaction((txn) async {
          final row = await _row(txn, p);
          if (row == null) return;
          final changes = _changes(row, p);
          if (changes.isEmpty) return;
          // Queue only fields that are actually missing in the local DB.
          p['artists'] = changes.containsKey('Artists') ? a : <String>[];
          p['groups'] = changes.containsKey('Groups') ? g : <String>[];
          final queue = await _queue();
          final key = jsonEncode([server, id, pages, source, token]);
          await queue.transaction((txn) async {
            final old = await txn.query(
              _table,
              where: 'Key=?',
              whereArgs: [key],
            );
            if (old.isNotEmpty) {
              final previous =
                  jsonDecode(old.first['Payload'] as String) as Map;
              for (final field in ['artists', 'groups']) {
                if ((p[field] as List).isEmpty) p[field] = previous[field];
              }
            }
            await txn.insert(_table, {
              'Key': key,
              'Server': server,
              'Payload': jsonEncode(p),
              'Acknowledged': 0,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          });
          // Persist the queue before touching replaceable content DB.
          await _write(txn, id, changes);
          qr.result = {...qr.result, ...changes};
        });
      });
    } catch (_) {
      // Retry opportunistically on a later open.
    }
  }

  /// Called only on cold startup. Use the existing trusted record-sync origin
  /// and token, never send it to a different content server.
  static Future<void> flush() async {
    try {
      await lock.synchronized(() async {
        final server = ServerConfig.webBase;
        if (server.isEmpty) return;
        final prefs = Settings.prefs;
        final sync = prefs.getString('bookmark_sync_server')?.trim() ?? '';
        final token = prefs.getString('bookmark_sync_token')?.trim() ?? '';
        if (sync.isEmpty || token.isEmpty) return;
        final base = ServerConfig.databaseBase(server);
        if (ServerConfig.normalize(sync) != base) return;
        final queue = await _queue();
        // Recover a queued write if the app stopped between persisting the
        // queue and updating its replaceable content database.
        final installedServer =
            prefs.getString('content-snapshot-server') ?? server;
        if (installedServer == server && prefs.getInt('db_exists') == 1) {
          final manager = await DataBaseManager.getInstance();
          await manager.checkOpen();
          await replaySnapshot(manager.db!, server, fresh: false);
        }
        final pending = await queue.query(
          _table,
          where: 'Server=? AND Acknowledged=0',
          whereArgs: [server],
          limit: 100,
        );
        if (pending.isEmpty) return;
        final rows = <Map<String, Object?>>[];
        final items = <dynamic>[];
        for (final row in pending) {
          final item = jsonDecode(row['Payload'] as String);
          if (utf8
                  .encode(
                    jsonEncode({
                      'schema': 1,
                      'items': [...items, item],
                    }),
                  )
                  .length >
              240 * 1024)
            break;
          rows.add(row);
          items.add(item);
        }
        if (rows.isEmpty) return;
        final client = http.Client();
        try {
          final request =
              http.Request(
                  'POST',
                  Uri.parse(ServerConfig.endpoint(base, 'api/metadata-repair')),
                )
                ..followRedirects = false
                ..headers.addAll({
                  'Content-Type': 'application/json',
                  'X-Violet-Sync-Token': token,
                })
                ..body = jsonEncode({'schema': 1, 'items': items});
          final response = await client
              .send(request)
              .then(http.Response.fromStream)
              .timeout(const Duration(seconds: 15));
          if (response.statusCode != 200) return;
          final body = jsonDecode(response.body);
          if (body is! Map || body['schema'] != 1 || body['results'] is! List)
            return;
          final results = body['results'] as List;
          if (results.length != rows.length ||
              results.any(
                (r) =>
                    !['applied', 'unchanged', 'identity_changed'].contains(r),
              ))
            return;
          await queue.transaction((txn) async {
            for (var i = 0; i < rows.length; i++) {
              if (results[i] == 'identity_changed') {
                await txn.delete(
                  _table,
                  where: 'Key=?',
                  whereArgs: [rows[i]['Key']],
                );
              } else {
                await txn.update(
                  _table,
                  {'Acknowledged': 1},
                  where: 'Key=?',
                  whereArgs: [rows[i]['Key']],
                );
              }
            }
          });
        } finally {
          client.close();
        }
      });
    } catch (_) {
      // Leave queue untouched on transport/validation failures.
    }
  }

  /// Called under [lock] after the new snapshot is installed. Acknowledged
  /// repairs remain queued until the unmodified snapshot actually contains
  /// their fields. This protects against an older hourly Pi export.
  static Future<void> replaySnapshot(
    Database db,
    String server, {
    bool fresh = true,
    Database? queueDb,
  }) async {
    final queue = queueDb ?? await _queue();
    final rows = await queue.query(
      _table,
      where: 'Server=?',
      whereArgs: [server],
    );
    if (rows.isEmpty) return;
    final confirmed = <Object?>[];
    final retry = <Object?>[];
    await db.transaction((txn) async {
      // Compare with the unmodified snapshot before applying any overlay.
      for (final record in rows) {
        final p = Map<String, dynamic>.from(
          jsonDecode(record['Payload'] as String) as Map,
        );
        final row = await _row(txn, p);
        if (row == null) continue;
        final changes = _changes(row, p);
        if (fresh && record['Acknowledged'] == 1) {
          if (changes.isEmpty) {
            confirmed.add(record['Key']);
          } else {
            // The export may predate the server commit, or a concurrent
            // collector may have replaced the row. Re-send next cold start.
            retry.add(record['Key']);
          }
        }
      }
      for (final record in rows) {
        final p = Map<String, dynamic>.from(
          jsonDecode(record['Payload'] as String) as Map,
        );
        final row = await _row(txn, p);
        if (row == null) continue;
        final changes = _changes(row, p);
        if (changes.isNotEmpty) {
          await _write(txn, p['id'] as int, changes);
        }
      }
    });
    await queue.transaction((txn) async {
      for (final key in confirmed) {
        await txn.delete(_table, where: 'Key=?', whereArgs: [key]);
      }
      for (final key in retry) {
        await txn.update(
          _table,
          {'Acknowledged': 0},
          where: 'Key=?',
          whereArgs: [key],
        );
      }
    });
  }
}
