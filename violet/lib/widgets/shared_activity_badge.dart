import 'dart:async';
import 'package:flutter/material.dart';
import 'package:violet/services/activity_sync.dart';
import 'package:violet/settings/settings.dart';

class SharedActivityBadge extends StatefulWidget {
  static const _visibilityKey = 'show_shared_activity_badges';
  static final visible = ValueNotifier<bool>(
    Settings.prefs.getBool(_visibilityKey) ?? true,
  );

  static Future<void> setVisible(bool value) async {
    await Settings.prefs.setBool(_visibilityKey, value);
    visible.value = value;
  }

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
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: SharedActivityBadge.visible,
    builder: (context, visible, _) =>
        visible ? _buildBadge(context) : const SizedBox.shrink(),
  );

  Widget _buildBadge(BuildContext context) =>
      ValueListenableBuilder<List<Map<String, dynamic>>>(
        valueListenable: ActivitySync.records,
        builder: (context, rows, _) {
          final origins = ActivitySync.downloadedOrigins(widget.article);
          final read = ActivitySync.latestRead(widget.article);
          final labels = <String>[
            if (origins.contains('app')) '앱에서 다운로드함',
            if (origins.contains('web')) '웹에서 다운로드함',
            if (read != null) '읽음 · ${(read['Page'] as int) + 1}페이지',
          ];
          if (labels.isEmpty) return const SizedBox.shrink();
          return IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.9),
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
