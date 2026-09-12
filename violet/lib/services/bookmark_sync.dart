import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';
import 'package:violet/database/user/user.dart';
import 'package:violet/log/log.dart';

class BookmarkSync {
  static final Lock _lock = Lock();
  static final ValueNotifier<int> changes = ValueNotifier(0);
  static final _numeric = RegExp(r'^\d{1,20}$');

  static Set<String> _ids(List<Map<String, Object?>> rows) => rows
      .map((row) => row['Article'].toString())
      .where((id) => _numeric.hasMatch(id))
      .toSet();

  static Future<void> automatic() async {
    try {
      await sync();
    } catch (_) {
      Logger.error('[BookmarkSync] Automatic sync failed; local data retained');
    }
  }

  static Future<int?> sync({bool force = false}) =>
      _lock.synchronized(() async {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('bookmark_sync_token') ?? '';
        final baseUrl = prefs.getString('bookmark_sync_server') ?? '';
        if (token.isEmpty || baseUrl.isEmpty) return null;
        final endpoint =
            '${baseUrl.replaceFirst(RegExp(r"/+$"), "")}/api/bookmark-sync';
        final days = prefs.getInt('bookmark_sync_days') == 7 ? 7 : 1;
        final manager = await CommonUserDatabase.getInstance();
        await manager.checkOpen();
        final db = manager.db!;
        await db.execute(
          'CREATE TABLE IF NOT EXISTS BookmarkSyncMeta '
          '(Id INTEGER PRIMARY KEY, State TEXT NOT NULL)',
        );

        final state = await db.transaction<Map<String, dynamic>?>((txn) async {
          final rows = await txn.query(
            'BookmarkSyncMeta',
            where: 'Id=?',
            whereArgs: [1],
          );
          final saved = rows.isEmpty
              ? <String, dynamic>{
                  'revision': 0,
                  'shadow': <String>[],
                  'lastSuccess': 0,
                }
              : Map<String, dynamic>.from(
                  jsonDecode(rows.first['State'] as String) as Map,
                );
          final now = DateTime.now().millisecondsSinceEpoch;
          if (!force && now - (saved['lastSuccess'] as int) < days * 86400000)
            return null;
          if (saved['pending'] == null) {
            final captured = _ids(await txn.query('BookmarkArticle'));
            final shadow = Set<String>.from(saved['shadow'] as List);
            saved['pending'] = {
              'captured': captured.toList(),
              'payload': {
                'requestId': const Uuid().v4(),
                'baseRevision': saved['revision'],
                'add': captured.difference(shadow).toList(),
                'remove': shadow.difference(captured).toList(),
              },
            };
          }
          await txn.rawInsert(
            'INSERT OR REPLACE INTO BookmarkSyncMeta VALUES (?, ?)',
            [1, jsonEncode(saved)],
          );
          return saved;
        });
        if (state == null) return null;
        final pending = Map<String, dynamic>.from(state['pending'] as Map);
        final response = await http
            .post(
              Uri.parse(endpoint),
              headers: {
                'Content-Type': 'application/json',
                'X-Violet-Sync-Token': token,
              },
              body: jsonEncode(pending['payload']),
            )
            .timeout(const Duration(seconds: 60));
        if (response.statusCode != 200)
          throw Exception('Sync HTTP ${response.statusCode}');
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final revision = data['revision'];
        final articles = data['articles'];
        if (revision is! int ||
            revision < (state['revision'] as int) ||
            articles is! List ||
            articles.length > 100000 ||
            articles.any((id) => id is! String || !_numeric.hasMatch(id))) {
          throw Exception('Invalid sync response');
        }
        final remote = Set<String>.from(articles);
        await db.transaction((txn) async {
          final rows = await txn.query('BookmarkArticle');
          final current = _ids(rows);
          final captured = Set<String>.from(pending['captured'] as List);
          final wanted = {...remote, ...current.difference(captured)}
            ..removeAll(captured.difference(current));
          final groups = await txn.query('BookmarkGroup', orderBy: 'Id');
          if (groups.isEmpty) throw Exception('No bookmark folder exists');
          final group = groups.firstWhere(
            (g) => g['Name'] == 'violet_default',
            orElse: () => groups.first,
          );
          final groupId = group['Id'];
          final batch = txn.batch();
          for (final row in rows) {
            final id = row['Article'].toString();
            if (_numeric.hasMatch(id) && !wanted.contains(id)) {
              batch.delete(
                'BookmarkArticle',
                where: 'Id=?',
                whereArgs: [row['Id']],
              );
            }
          }
          for (final id in wanted.difference(current)) {
            batch.insert('BookmarkArticle', {
              'Article': id,
              'DateTime': DateTime.now().toString(),
              'GroupId': groupId,
            });
          }
          await batch.commit(noResult: true);
          await txn.rawInsert(
            'INSERT OR REPLACE INTO BookmarkSyncMeta VALUES (?, ?)',
            [
              1,
              jsonEncode({
                'revision': revision,
                'shadow': remote.toList(),
                'lastSuccess': DateTime.now().millisecondsSinceEpoch,
              }),
            ],
          );
        });
        changes.value++;
        return remote.length;
      });
}
