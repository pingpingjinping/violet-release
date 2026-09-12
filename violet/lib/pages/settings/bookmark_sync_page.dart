import 'package:flutter/material.dart';
import 'package:violet/pages/settings/shared_activity_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violet/services/bookmark_sync.dart';
import 'package:violet/widgets/shared_activity_badge.dart';

class BookmarkSyncPage extends StatefulWidget {
  const BookmarkSyncPage({super.key});
  @override
  State<BookmarkSyncPage> createState() => _BookmarkSyncPageState();
}

class _BookmarkSyncPageState extends State<BookmarkSyncPage> {
  final _token = TextEditingController();
  final _server = TextEditingController();
  int _days = 1;
  bool _autoContent = true;
  bool _autoRecords = true;
  bool _busy = false;
  bool _loaded = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _server.text = prefs.getString('bookmark_sync_server') ?? '';
      _token.text = prefs.getString('bookmark_sync_token') ?? '';
      _days = prefs.getInt('bookmark_sync_days') == 7 ? 7 : 1;
      _autoContent = prefs.getBool('auto_content_db_update') ?? true;
      _autoRecords = prefs.getBool('auto_record_sync') ?? true;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _token.dispose();
    _server.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bookmark_sync_server', _server.text.trim());
    await prefs.setString('bookmark_sync_token', _token.text.trim());
    await prefs.setInt('bookmark_sync_days', _days);
    if (mounted) setState(() => _message = '저장했습니다. 토큰을 비우면 동기화가 꺼집니다.');
  }

  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      await _save();
      final count = await BookmarkSync.sync(force: true);
      if (mounted)
        setState(
          () => _message = count == null
              ? '토큰을 입력해 주세요.'
              : '동기화 완료: 중복을 제외한 작품 $count개',
        );
    } catch (_) {
      if (mounted)
        setState(
          () => _message =
              '동기화 실패. 토큰과 WalnutPi 네트워크 연결을 확인해 주세요. 기기의 기록은 보존됩니다.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('앱·웹 기록 동기화')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '선택한 주기가 지난 뒤 앱을 열면 작품 북마크·읽은 기록·완료한 다운로드 기록을 동기화합니다. 폴더·작가 북마크·다운로드 파일은 기기에 유지됩니다. 새 북마크는 미분류 폴더에 들어갑니다.',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('앱 시작 시 DB 자동 갱신'),
          subtitle: const Text(
            '앱을 완전히 종료했다 켤 때 확인합니다. 변경 시 적용을 마친 뒤 검색 화면으로 이동합니다.',
          ),
          value: _autoContent,
          onChanged: !_loaded || _busy
              ? null
              : (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('auto_content_db_update', value);
                  if (mounted) setState(() => _autoContent = value);
                },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('기록 자동 동기화'),
          subtitle: const Text('꺼도 기존 기록은 유지되며, 지금 동기화 버튼으로 직접 실행할 수 있습니다.'),
          value: _autoRecords,
          onChanged: !_loaded || _busy
              ? null
              : (value) async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('auto_record_sync', value);
                  if (mounted) setState(() => _autoRecords = value);
                },
        ),
        ValueListenableBuilder<bool>(
          valueListenable: SharedActivityBadge.visible,
          builder: (context, visible, _) => SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('작품 카드에 읽음·다운로드 기록 표시'),
            subtitle: const Text('표시만 숨기며 저장된 기록은 유지됩니다.'),
            value: visible,
            onChanged: _loaded && !_busy
                ? (value) async {
                    await SharedActivityBadge.setVisible(value);
                  }
                : null,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _server,
          enabled: _loaded && !_busy,
          decoration: const InputDecoration(
            labelText: '서버 주소 (http://서버IP:3002)',
          ),
        ),
        TextField(
          controller: _token,
          obscureText: true,
          enabled: _loaded && !_busy,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: '동기화 토큰'),
        ),
        DropdownButton<int>(
          value: _days,
          items: const [
            DropdownMenuItem(value: 1, child: Text('하루 한 번')),
            DropdownMenuItem(value: 7, child: Text('일주일 한 번')),
          ],
          onChanged: !_loaded || _busy
              ? null
              : (value) => setState(() => _days = value!),
        ),
        ElevatedButton(
          onPressed: !_loaded || _busy ? null : _save,
          child: const Text('저장'),
        ),
        ElevatedButton(
          onPressed: !_loaded || _busy ? null : _sync,
          child: Text(_busy ? '동기화 중…' : '지금 동기화'),
        ),
        TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SharedActivityPage()),
          ),
          child: const Text('공유 읽기·다운로드 기록 보기'),
        ),
        Text(_message),
      ],
    ),
  );
}
