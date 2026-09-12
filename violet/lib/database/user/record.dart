// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:synchronized/synchronized.dart';
import 'package:violet/services/activity_sync.dart';
import 'package:violet/database/user/user.dart';
import 'package:violet/log/log.dart';

////////////////////////////////////////////////////////////////////////
///
///         User Record
///
////////////////////////////////////////////////////////////////////////

// // Trivial Log
// class UserLog {
//   Map<String, dynamic> result;
//   UserLog({this.result});

//   int id() => result['Id'];
//   String message() => result['Message'];
//   String datetime() => result['DateTime'];
//   String type() => result['Type'];
// }

// // Specific Log
// class UserActivity {
//   Map<String, dynamic> result;
//   UserActivity({this.result});

//   int id() => result['Id'];
//   String message() => result['Message'];
//   String datetime() => result['DateTime'];

//   // 1: Startup Application
//   // 2: Close Application
//   // 3: Suspend Application
//   // 100: Search
//   // 101: Info View
//   // 120: Viewer Open
//   // 121: Viewer Close
//   int type() => result['Type'];
// }

class ArticleReadLog {
  Map<String, dynamic> result;
  ArticleReadLog({required this.result});

  int id() => result['Id'];
  String articleId() => result['Article'];
  String datetimeStart() => result['DateTimeStart'];
  String? datetimeEnd() => result['DateTimeEnd'];
  int? lastPage() => result['LastPage'];
  // 0: Read on search, 1: Read on bookmark
  int type() => result['Type'];
}

class User {
  static late final User _instance;
  static Future<void> load() async {
    var db = await CommonUserDatabase.getInstance();
    var ee = await db.query(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='ArticleReadLog';",
    );
    if (ee.isEmpty || ee[0].isEmpty) {
      try {
        await db.execute('''CREATE TABLE ArticleReadLog (
              Id integer primary key autoincrement, 
              Article text, 
              DateTimeStart text,
              DateTimeEnd text,
              LastPage integer,
              Type integer);
              ''');
      } catch (e, st) {
        Logger.error(
          '[Record-Instance] E: $e\n'
          '$st',
        );
      }
    }
    _instance = User();
  }

  static Future<User> getInstance() async {
    return _instance;
  }

  List<ArticleReadLog>? cachedReadLog;
  List<ArticleReadLog>? _mergedReadLog;
  List<Map<String, dynamic>>? _sharedSource;
  final _recentByArticle = <String, ArticleReadLog>{};
  Lock userLogLock = Lock();

  Future<ArticleReadLog?> recentRead(String article) async {
    await getUserLog();
    final log = _recentByArticle[article];
    if (log == null) return null;
    final start = DateTime.tryParse(log.datetimeStart());
    if (start == null || DateTime.now().difference(start).inDays >= 31) return null;
    return log;
  }

  Future<List<ArticleReadLog>> getUserLog() async {
    await userLogLock.synchronized(() async {
      cachedReadLog ??=
          (await (await CommonUserDatabase.getInstance()).query(
                'SELECT * FROM ArticleReadLog ORDER BY Id DESC',
              ))
              // TODO: 왜 Article에 null이 들어가는지 확인 필요
              .where((e) => e['Article'] != null)
              .map((x) => ArticleReadLog(result: x))
              .toList();
    });
    await ActivitySync.load();
    final shared = ActivitySync.records.value;
    if (_mergedReadLog != null && identical(_sharedSource, shared)) return _mergedReadLog!;
    final combined = mergeReadLogs(cachedReadLog!, shared);
    _recentByArticle.clear();
    for (final log in combined) {
      if ((log.lastPage() ?? 0) > 1) _recentByArticle.putIfAbsent(log.articleId(), () => log);
    }
    _sharedSource = shared;
    return _mergedReadLog = combined;
  }

  Future<void> insertUserLog(
    int article,
    int type, [
    DateTime? datetime,
  ]) async {
    datetime ??= DateTime.now();
    final db = await CommonUserDatabase.getInstance();
    final log = ArticleReadLog(
      result: {
        'Article': article.toString(),
        'Type': type,
        'DateTimeStart': datetime.toString(),
      },
    );
    final id = await db.insert('ArticleReadLog', log.result);
    log.result['Id'] = id;
    cachedReadLog!.insert(0, log);
    _mergedReadLog = null;
  }

  Future<void> updateUserLog(int article, int lastpage, [DateTime? end]) async {
    end ??= DateTime.now();
    final db = await CommonUserDatabase.getInstance();
    var latestLog = cachedReadLog!.first.result;
    latestLog['DateTimeEnd'] = end.toString();
    latestLog['LastPage'] = lastpage;
    _mergedReadLog = null;
    await db.update('ArticleReadLog', latestLog, 'Id=?', [latestLog['Id']]);
  }
}

List<ArticleReadLog> mergeReadLogs(List<ArticleReadLog> local, List<Map<String, dynamic>> shared) {
    final localLatest = <String, int>{};
    for (final log in local) {
      final time = ActivitySync.timeOf(
        log.datetimeEnd() ?? log.datetimeStart(),
      );
      if ((localLatest[log.articleId()] ?? 0) < time)
        localLatest[log.articleId()] = time;
    }
    final sharedLatest = <String, Map<String, dynamic>>{};
    for (final r in shared.where(
      (r) => r['Kind'] == 'read',
    )) {
      final article = r['Article'] as String;
      if ((r['Timestamp'] as int) <= (localLatest[article] ?? 0)) continue;
      if ((sharedLatest[article]?['Timestamp'] as int? ?? 0) < (r['Timestamp'] as int)) sharedLatest[article] = r;
    }
    var remoteId = -1;
    final combined = <ArticleReadLog>[
      ...local,
      for (final r in sharedLatest.values)
        ArticleReadLog(
          result: {
            'Id': remoteId--,
            'Article': r['Article'],
            'Type': r['Type'],
            'DateTimeStart': DateTime.fromMillisecondsSinceEpoch(
              r['Timestamp'] as int,
              isUtc: true,
            ).toIso8601String(),
            'DateTimeEnd': DateTime.fromMillisecondsSinceEpoch(
              r['Timestamp'] as int,
              isUtc: true,
            ).toIso8601String(),
            'LastPage': (r['Page'] as int) + 1,
          },
        ),
    ];
    final times = {for (final log in combined) log: ActivitySync.timeOf(log.datetimeEnd() ?? log.datetimeStart())};
    combined.sort(
      (a, b) => times[b]!.compareTo(times[a]!),
    );
    return combined;
}
