import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:violet/settings/settings.dart';

class ImageCachePage extends StatefulWidget {
  const ImageCachePage({super.key});

  @override
  State<ImageCachePage> createState() => _ImageCachePageState();
}

class _CacheUsage {
  final int bytes;
  final int fileCount;

  const _CacheUsage({required this.bytes, required this.fileCount});
}

class _ImageCachePageState extends State<ImageCachePage> {
  static const _bodyCacheFolder = 'cacheimage';
  static const _thumbnailCacheFolder = 'libCachedImageData';

  _CacheUsage _bodyUsage = const _CacheUsage(bytes: 0, fileCount: 0);
  _CacheUsage _thumbnailUsage = const _CacheUsage(bytes: 0, fileCount: 0);
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<Directory> _cacheDirectory(String folder) async {
    final temporaryDirectory = await getTemporaryDirectory();
    return Directory(path.join(temporaryDirectory.path, folder));
  }

  Future<_CacheUsage> _directoryUsage(String folder) async {
    final directory = await _cacheDirectory(folder);
    if (!await directory.exists()) {
      return const _CacheUsage(bytes: 0, fileCount: 0);
    }

    var bytes = 0;
    var fileCount = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) {
        bytes += await entity.length();
        fileCount++;
      }
    }
    return _CacheUsage(bytes: bytes, fileCount: fileCount);
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final usages = await Future.wait([
        _directoryUsage(_bodyCacheFolder),
        _directoryUsage(_thumbnailCacheFolder),
      ]);

      if (!mounted) return;
      setState(() {
        _bodyUsage = usages[0];
        _thumbnailUsage = usages[1];
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<bool> _confirm(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _deleteBodyCache() async {
    final directory = await _cacheDirectory(_bodyCacheFolder);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _deleteThumbnailCache() async {
    await DefaultCacheManager().emptyCache();
    final directory = await _cacheDirectory(_thumbnailCacheFolder);
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> _clear({
    required String title,
    required String message,
    required String completedMessage,
    required Future<void> Function() action,
  }) async {
    if (!await _confirm(title, message)) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await action();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.black87,
          content: Text(
            completedMessage,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _clearBodyCache() => _clear(
    title: '본문 이미지 캐시 삭제',
    message:
        '열어본 작품의 임시 본문 이미지만 삭제합니다. '
        '북마크, 읽은 기록과 다운로드한 작품에는 영향을 주지 않습니다.',
    completedMessage: '본문 이미지 캐시를 삭제했습니다.',
    action: _deleteBodyCache,
  );

  Future<void> _clearThumbnailCache() => _clear(
    title: '썸네일 캐시 삭제',
    message:
        '목록에서 받은 임시 썸네일만 삭제합니다. '
        '다음에 목록을 열면 필요한 썸네일을 다시 받습니다.',
    completedMessage: '썸네일 캐시를 삭제했습니다.',
    action: _deleteThumbnailCache,
  );

  Future<void> _clearAllCaches() => _clear(
    title: '전체 이미지 캐시 삭제',
    message:
        '본문 이미지와 썸네일 캐시를 모두 삭제합니다. '
        '실제 다운로드 파일과 사용자 데이터는 유지됩니다.',
    completedMessage: '전체 이미지 캐시를 삭제했습니다.',
    action: () async {
      await _deleteBodyCache();
      await _deleteThumbnailCache();
    },
  );

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';

    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }

    final decimals = value >= 100
        ? 0
        : value >= 10
        ? 1
        : 2;
    return '${value.toStringAsFixed(decimals)} ${units[unit]}';
  }

  Widget _cacheCard({
    required IconData icon,
    required String title,
    required String description,
    required _CacheUsage usage,
    required VoidCallback clear,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            ListTile(
              leading: Icon(icon, color: Settings.majorColor.value),
              title: Text(title),
              subtitle: _error != null
                  ? Text('용량 확인 실패: $_error')
                  : Text(
                      _loading
                          ? '용량 확인 중…'
                          : '${usage.fileCount}개 파일 · ${_formatBytes(usage.bytes)}',
                    ),
              trailing: _loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(description),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _loading || usage.bytes == 0 ? null : clear,
                  icon: const Icon(Icons.delete_outline),
                  label: Text('$title 삭제'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalBytes = _bodyUsage.bytes + _thumbnailUsage.bytes;

    return Scaffold(
      appBar: AppBar(
        title: const Text('이미지 캐시'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _refresh,
            tooltip: '새로고침',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _cacheCard(
              icon: Icons.photo_library_outlined,
              title: '본문 이미지 캐시',
              description: '작품을 열었을 때 인터넷에서 받은 임시 본문 이미지입니다.',
              usage: _bodyUsage,
              clear: _clearBodyCache,
            ),
            const SizedBox(height: 8),
            _cacheCard(
              icon: Icons.image_outlined,
              title: '썸네일 캐시',
              description: '검색과 목록에서 미리 받은 작품 썸네일입니다.',
              usage: _thumbnailUsage,
              clear: _clearThumbnailCache,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loading || totalBytes == 0 ? null : _clearAllCaches,
              icon: const Icon(Icons.delete_sweep_outlined),
              label: Text('전체 이미지 캐시 삭제 · ${_formatBytes(totalBytes)}'),
            ),
            const SizedBox(height: 12),
            const Text(
              '캐시를 삭제해도 북마크, 읽은 기록, 다운로드 목록과 '
              '실제 다운로드한 작품은 지워지지 않습니다.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
