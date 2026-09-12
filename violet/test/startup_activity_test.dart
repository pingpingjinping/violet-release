import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violet/database/user/record.dart';
import 'package:violet/services/activity_sync.dart';
import 'package:violet/services/content_db_sync.dart';

void main() {
  test('Newest shared session wins without removing local read sessions', () {
    final local = ArticleReadLog(result: {
      'Id': 1, 'Article': '42', 'Type': 0, 'LastPage': 8,
      'DateTimeStart': '2026-09-12T00:00:00Z',
    });
    final timestamp = DateTime.utc(2026, 9, 12, 1).millisecondsSinceEpoch;
    Map<String, dynamic> read(int time, int page) => {
      'Kind': 'read', 'Article': '42', 'Timestamp': time,
      'Page': page, 'Type': 1,
    };
    final merged = mergeReadLogs([local], [read(timestamp, 10), read(timestamp + 1000, 15)]);
    expect(merged.length, 2);
    expect(merged.first.lastPage(), 16);
    expect(merged.last, same(local));
    expect(mergeReadLogs([local], [read(timestamp - 7200000, 99)]), [local]);
  });

  test('Replacing synchronized records invalidates article lookups', () {
    ActivitySync.records.value = [
      {'Kind': 'download', 'Article': '42', 'Origin': 'app'},
      {'Kind': 'read', 'Article': '42', 'Timestamp': 2000, 'Page': 2},
      {'Kind': 'read', 'Article': '42', 'Timestamp': 1000, 'Page': 1},
    ];
    expect(ActivitySync.downloadedOrigins('42'), ['app']);
    expect(ActivitySync.latestRead('42')!['Page'], 2);
    ActivitySync.records.value = [
      {'Kind': 'download', 'Article': '42', 'Origin': 'web'},
    ];
    expect(ActivitySync.downloadedOrigins('42'), ['web']);
    expect(ActivitySync.latestRead('42'), isNull);
    expect(ActivitySync.downloadedOrigins('99'), isEmpty);
  });

  test('Disabled startup update never applies or retries in this session', () async {
    SharedPreferences.setMockInitialValues({'auto_content_db_update': false});
    var calls = 0;
    expect(await ContentDbSync.startup(canApply: () { calls++; return true; }), false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_content_db_update', true);
    expect(await ContentDbSync.startup(canApply: () { calls++; return true; }), false);
    expect(calls, 0);
  });
}
