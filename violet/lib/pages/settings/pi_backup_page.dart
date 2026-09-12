import 'dart:async';
import 'package:flutter/material.dart';
import 'package:violet/pages/settings/bookmark_sync_page.dart';
import 'package:violet/services/pi_backup.dart';
import 'package:violet/settings/settings.dart';

class PiBackupPage extends StatefulWidget {
  const PiBackupPage({super.key});
  @override
  State<PiBackupPage> createState() => _PiBackupPageState();
}

class _PiBackupPageState extends State<PiBackupPage> {
  bool _busy = false;
  bool _restoring = false;
  String _message = '';
  List<Map<String, dynamic>> _backups = [];

  String _error(Object error) {
    if (error is FormatException) return error.message.toString();
    if (error is TimeoutException)
      return '서버 응답 시간이 초과됐습니다. 주소와 네트워크 연결을 확인해 주세요.';
    return '백업 처리에 실패했습니다. 서버 연결과 저장 공간을 확인해 주세요. 복원 실패 시 기존 기록은 유지됩니다.';
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _message = '처리 중…';
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => _message = _error(e));
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          _restoring = false;
        });
    }
  }

  Future<void> _list() => _run(() async {
    final rows = await PiBackup.listing();
    if (mounted)
      setState(() {
        _backups = rows;
        _message = rows.isEmpty ? '저장된 백업이 없습니다.' : '최근 백업 ${rows.length}개';
      });
  });

  Future<void> _backup() => _run(() async {
    await PiBackup.create();
    final rows = await PiBackup.listing();
    if (mounted)
      setState(() {
        _backups = rows;
        _message = 'User App ID와 전체 기록을 Pi에 백업했습니다.';
      });
  });

  Future<void> _restore(Map<String, dynamic> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이 백업으로 복원할까요?'),
        content: const Text(
          'User App ID·북마크·폴더·전체 읽은 기록을 선택한 백업으로 교체합니다. 다운로드 파일은 유지됩니다. 먼저 현재 데이터를 기기와 Pi에 백업하며, 백업에 실패하면 복원하지 않습니다.\n\n복원 후 기록 자동 동기화는 꺼집니다. 복원 내용을 확인한 뒤 다시 켤 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('백업 후 복원'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      setState(() => _restoring = true);
      await PiBackup.restore(row);
      if (!mounted) return;
      await showDialog<void>(
        barrierDismissible: false,
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('복원 완료'),
          content: const Text('복원한 기록으로 앱 화면을 다시 엽니다. 개인 기록 자동 동기화는 꺼져 있습니다.'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('확인'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(
        context,
        rootNavigator: true,
      ).pushNamedAndRemoveUntil('/AfterLoading', (_) => false);
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Pi 전체 백업·복원')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SelectableText(
            'User App ID: ${Settings.prefs.getString("fa_userid") ?? "아직 생성되지 않음"}',
          ),
          const SizedBox(height: 12),
          const Text(
            'ID·작품/작가 북마크·폴더·전체 읽은 기록·다운로드 완료 표시를 함께 백업합니다. 작품 DB와 다운로드 파일은 포함하지 않습니다. 백업은 개인 기록 동기화 서버에 저장됩니다.',
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const BookmarkSyncPage()),
                  ),
            child: const Text('개인 서버 주소·토큰 설정'),
          ),
          FilledButton(
            onPressed: _busy ? null : _backup,
            child: const Text('지금 Pi에 전체 백업'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _list,
            child: const Text('백업 목록 불러오기'),
          ),
          if (_busy) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(_restoring ? '선택한 백업 검사 → 현재 데이터 백업 → 복원 중…' : '서버와 백업 처리 중…'),
          ],
          const SizedBox(height: 12),
          Text(_message),
          for (final row in _backups)
            ListTile(
              title: Text(
                DateTime.fromMillisecondsSinceEpoch(
                  (row['createdAt'] as int) * 1000,
                ).toLocal().toString().split('.').first,
              ),
              subtitle: Text(
                'ID: ${row["userAppId"]}\n압축 ${((row["size"] as num) / 1048576).toStringAsFixed(2)}MiB',
              ),
              trailing: const Icon(Icons.restore),
              onTap: _busy ? null : () => _restore(row),
            ),
        ],
      ),
    ),
  );
}
