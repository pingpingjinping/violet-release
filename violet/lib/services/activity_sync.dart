import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synchronized/synchronized.dart';
import 'package:uuid/uuid.dart';
import 'package:violet/database/user/user.dart';

class ActivitySync {
  static final Lock _lock = Lock();
  static Future<void>? _loading;
  static final records = ValueNotifier<List<Map<String, dynamic>>>([]);
  static final _numeric = RegExp(r'^\d{1,20}$');
  static const _schema =
      'CREATE TABLE IF NOT EXISTS SharedActivity ('
      'Kind TEXT, Device TEXT, Article TEXT, Origin TEXT, Timestamp INTEGER, '
      'Page INTEGER, Type INTEGER, PRIMARY KEY (Kind, Device, Article))';

  static Future<void> load() => _loading ??= _load().catchError((Object error) {
    _loading = null;
    throw error;
  });
  static Future<void> _load() async {
    final manager = await CommonUserDatabase.getInstance();
    await manager.checkOpen();
    await manager.db!.execute(_schema);
    records.value = (await manager.db!.query(
      'SharedActivity',
      orderBy: 'Timestamp DESC',
    )).map((r) => Map<String, dynamic>.from(r)).toList();
  }

  static List<String> downloadedOrigins(String article) => records.value
      .where((r) => r['Kind'] == 'download' && r['Article'] == article)
      .map((r) => r['Origin'] as String)
      .toSet()
      .toList();

  static int timeOf(Object? value) =>
      DateTime.tryParse(
        value?.toString() ?? '',
      )?.toUtc().millisecondsSinceEpoch ??
      0;

  static Future<void> sync({bool force = false}) =>
      _lock.synchronized(() async {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('bookmark_sync_token') ?? '';
        final base = prefs.getString('bookmark_sync_server') ?? '';
        if (token.isEmpty || base.isEmpty) return;
        final days = prefs.getInt('bookmark_sync_days') == 7 ? 7 : 1;
        final last = prefs.getInt('activity_sync_last_success') ?? 0;
        if (!force &&
            DateTime.now().millisecondsSinceEpoch - last < days * 86400000)
          return;
        await load();
        final manager = await CommonUserDatabase.getInstance();
        final db = manager.db!;
        var device = prefs.getString('activity_sync_device');
        if (device == null) {
          device = const Uuid().v4();
          await prefs.setString('activity_sync_device', device);
        }
        final names = (await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        )).map((r) => r['name']).toSet();
        final read = <String, Map<String, dynamic>>{};
        if (names.contains('ArticleReadLog')) {
          for (final row in await db.query(
            'ArticleReadLog',
            columns: [
              'Article',
              'DateTimeStart',
              'DateTimeEnd',
              'LastPage',
              'Type',
            ],
          )) {
            final article = row['Article']?.toString() ?? '';
            var timestamp = timeOf(row['DateTimeEnd']);
            if (timestamp <= 0) timestamp = timeOf(row['DateTimeStart']);
            if (!_numeric.hasMatch(article) || timestamp <= 0) continue;
            if (!read.containsKey(article) ||
                (read[article]!['timestamp'] as int) < timestamp) {
              final nativePage = (row['LastPage'] as int?) ?? 1;
              read[article] = {
                'article': article,
                'timestamp': timestamp,
                'page': nativePage > 0 ? nativePage - 1 : 0,
                'type': row['Type'] == 1 ? 1 : 0,
              };
            }
          }
        }
        final downloads = <String, Map<String, dynamic>>{};
        if (names.contains('DownloadItem')) {
          for (final row in await db.query(
            'DownloadItem',
            columns: ['URL', 'DateTime'],
            where: 'State=?',
            whereArgs: [0],
          )) {
            final article = row['URL']?.toString() ?? '';
            final timestamp = timeOf(row['DateTime']);
            if (!_numeric.hasMatch(article) || timestamp <= 0) continue;
            if (!downloads.containsKey(article) ||
                (downloads[article]!['timestamp'] as int) < timestamp) {
              downloads[article] = {'article': article, 'timestamp': timestamp};
            }
          }
        }
        final endpoint =
            '${base.replaceFirst(RegExp(r"/+$"), "")}/api/activity-sync';
        final response = await http
            .post(
              Uri.parse(endpoint),
              headers: {
                'Content-Type': 'application/json',
                'X-Violet-Sync-Token': token,
              },
              body: jsonEncode({
                'device': device,
                'origin': 'app',
                'read': read.values.toList(),
                'download': downloads.values.toList(),
              }),
            )
            .timeout(const Duration(seconds: 60));
        if (response.statusCode != 200) throw Exception('Activity sync failed');
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['version'] != 1 ||
            data['records'] is! List ||
            (data['records'] as List).length > 100000) {
          throw Exception('Invalid activity response');
        }
        final incoming = <Map<String, dynamic>>[];
        for (final value in data['records'] as List) {
          final r = Map<String, dynamic>.from(value as Map);
          if (!['read', 'download'].contains(r['kind']) ||
              !['app', 'web'].contains(r['origin']) ||
              r['device'] is! String ||
              !RegExp(r'^[0-9a-f-]{36}$').hasMatch(r['device'] as String) ||
              r['article'] is! String ||
              !_numeric.hasMatch(r['article'] as String) ||
              r['timestamp'] is! int ||
              (r['timestamp'] as int) <= 0 ||
              (r['timestamp'] as int) > 8640000000000000 ||
              r['page'] is! int ||
              (r['page'] as int) < 0 ||
              (r['page'] as int) > 1000000 ||
              ![0, 1].contains(r['type'])) {
            throw Exception('Invalid activity record');
          }
          incoming.add({
            'Kind': r['kind'],
            'Device': r['device'],
            'Article': r['article'],
            'Origin': r['origin'],
            'Timestamp': r['timestamp'],
            'Page': r['page'],
            'Type': r['type'],
          });
        }
        await db.transaction((txn) async {
          await txn.delete('SharedActivity');
          final batch = txn.batch();
          for (final row in incoming) {
            batch.insert('SharedActivity', row);
          }
          await batch.commit(noResult: true);
        });
        records.value = incoming;
        await prefs.setInt(
          'activity_sync_last_success',
          DateTime.now().millisecondsSinceEpoch,
        );
      });
}
