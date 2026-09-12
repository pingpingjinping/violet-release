import 'dart:async';
import 'package:flutter/material.dart';
import 'package:violet/database/query.dart';
import 'package:violet/pages/common/utils.dart';
import 'package:violet/services/activity_sync.dart';

class SharedActivityPage extends StatefulWidget {
  const SharedActivityPage({super.key});
  @override
  State<SharedActivityPage> createState() => _SharedActivityPageState();
}

class _SharedActivityPageState extends State<SharedActivityPage> {
  String _kind = 'download';
  int _page = 0;
  @override
  void initState() {
    super.initState();
    unawaited(ActivitySync.load().catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('공유 읽기·다운로드 기록')),
    body: ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: ActivitySync.records,
      builder: (context, records, _) {
        final latest = <String, Map<String, dynamic>>{};
        for (final r in records.where((r) => r['Kind'] == _kind)) {
          final article = r['Article'] as String;
          if (!latest.containsKey(article) ||
              (latest[article]!['Timestamp'] as int) < (r['Timestamp'] as int))
            latest[article] = r;
        }
        final rows = latest.values.toList()
          ..sort(
            (a, b) => (b['Timestamp'] as int).compareTo(a['Timestamp'] as int),
          );
        final page = _page
            .clamp(0, rows.isEmpty ? 0 : (rows.length - 1) ~/ 30)
            .toInt();
        final visible = rows.skip(page * 30).take(30).toList();
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _kind == 'download'
                    ? '완료한 다운로드 기록입니다. 파일은 해당 기기에 있으며, 파일 삭제와 별개로 기록은 유지됩니다.'
                    : '작품별 마지막 읽은 시각과 페이지를 공유합니다.',
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _kind = 'download';
                    _page = 0;
                  }),
                  child: Text(
                    '다운로드 (${records.where((r) => r['Kind'] == 'download').map((r) => r['Article']).toSet().length})',
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _kind = 'read';
                    _page = 0;
                  }),
                  child: const Text('읽은 기록'),
                ),
              ],
            ),
            Expanded(
              child: FutureBuilder<List<QueryResult>>(
                future: visible.isEmpty
                    ? Future.value(<QueryResult>[])
                    : QueryManager.queryIds(
                        visible.map((r) => r['Article'] as String).toList(),
                      ),
                builder: (context, snapshot) => ListView.builder(
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final r = visible[index];
                    final article = r['Article'] as String;
                    final query = (snapshot.data ?? <QueryResult>[])
                        .where((q) => q.id().toString() == article)
                        .firstOrNull;
                    final origins = ActivitySync.downloadedOrigins(
                      article,
                    ).map((o) => o == 'app' ? '앱' : '웹').join('·');
                    final when = DateTime.fromMillisecondsSinceEpoch(
                      r['Timestamp'] as int,
                    ).toString().split('.').first;
                    return ListTile(
                      title: Text(query?.title() ?? '#$article'),
                      subtitle: Text(
                        _kind == 'download'
                            ? '$origins에서 다운로드함 · $when'
                            : '${r['Origin'] == 'app' ? '앱' : '웹'}에서 읽음 · ${(r['Page'] as int) + 1}페이지 · $when',
                      ),
                      onTap: query == null
                          ? null
                          : () => showArticleInfoRaw(
                              context: context,
                              queryResult: query,
                            ),
                    );
                  },
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: page > 0
                      ? () => setState(() => _page = page - 1)
                      : null,
                  child: const Text('이전'),
                ),
                Text(
                  '${page + 1} / ${rows.isEmpty ? 1 : (rows.length + 29) ~/ 30}',
                ),
                TextButton(
                  onPressed: (page + 1) * 30 < rows.length
                      ? () => setState(() => _page = page + 1)
                      : null,
                  child: const Text('다음'),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}
