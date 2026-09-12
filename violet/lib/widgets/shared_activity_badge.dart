import 'dart:async';
import 'package:flutter/material.dart';
import 'package:violet/services/activity_sync.dart';

class SharedActivityBadge extends StatefulWidget {
  final String article;
  const SharedActivityBadge({super.key, required this.article});
  @override
  State<SharedActivityBadge> createState() => _SharedActivityBadgeState();
}

class _SharedActivityBadgeState extends State<SharedActivityBadge> {
  @override
  void initState() {
    super.initState();
    unawaited(ActivitySync.load().catchError((Object _) {}));
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<List<Map<String, dynamic>>>(
    valueListenable: ActivitySync.records,
    builder: (context, rows, _) {
      final origins = ActivitySync.downloadedOrigins(widget.article);
      final read = rows
          .where((r) => r['Kind'] == 'read' && r['Article'] == widget.article)
          .firstOrNull;
      final labels = <String>[
        if (origins.contains('app')) '앱에서 다운로드함',
        if (origins.contains('web')) '웹에서 다운로드함',
        if (read != null) '읽음 · ${(read['Page'] as int) + 1}페이지',
      ];
      if (labels.isEmpty) return const SizedBox.shrink();
      return IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
          child: Text(
            labels.join(' / '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      );
    },
  );
}
