import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:violet/settings/settings.dart';

class ImageCachePage extends StatefulWidget {
  const ImageCachePage({super.key});

  @override
  State<ImageCachePage> createState() => _ImageCachePageState();
}

class _ImageCachePageState extends State<ImageCachePage> {
  int _bytes = 0;
  int _fileCount = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<Directory> _cacheDirectory() async {
    final temporaryDirectory = await getTemporaryDirectory();
    return Directory(path.join(temporaryDirectory.path, 'cacheimage'));
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    var bytes = 0;
    var fileCount = 0;

    try {
      final directory = await _cacheDirectory();
      if (await directory.exists()) {
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            bytes += await entity.length();
            fileCount++;
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _fileCount = fileCount;
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

  Future<void> _clearCache() async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('본문 이미지 캐시 삭제'),
            content: const Text(
              '열어본 작품의 임시 이미지만 삭제합니다. '
              '북마크, 읽은 기록과 다운로드한 작품에는 영향을 주지 않습니다.',
            ),
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
    if (!confirmed) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final directory = await _cacheDirectory();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('본문 이미지 캐시를 삭제했습니다.')));
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('본문 이미지 캐시'),
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
            Card(
              child: ListTile(
                leading: Icon(
                  Icons.photo_library_outlined,
                  color: Settings.majorColor.value,
                ),
                title: const Text('열어본 작품 이미지'),
                subtitle: _error != null
                    ? Text('용량 확인 실패: $_error')
                    : Text(
                        _loading
                            ? '용량 확인 중…'
                            : '$_fileCount개 파일 · ${_formatBytes(_bytes)}',
                      ),
                trailing: _loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '작품을 열었을 때 인터넷에서 받은 본문 이미지 캐시입니다. '
              '삭제해도 실제 다운로드 파일과 사용자 데이터는 유지되며, '
              '다음에 작품을 열 때 이미지를 다시 받습니다.',
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _loading || _bytes == 0 ? null : _clearCache,
              icon: const Icon(Icons.delete_outline),
              label: const Text('본문 이미지 캐시 삭제'),
            ),
          ],
        ),
      ),
    );
  }
}
