import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:violet/services/server_config.dart';
import 'package:violet/settings/settings.dart';

class ServerSettingsPage extends StatefulWidget {
  const ServerSettingsPage({super.key});
  @override
  State<ServerSettingsPage> createState() => _ServerSettingsPageState();
}

class _ServerSettingsPageState extends State<ServerSettingsPage> {
  final _address = TextEditingController(text: ServerConfig.webBase);
  bool _busy = false;
  String _message = '';
  @override
  void dispose() { _address.dispose(); super.dispose(); }

  Future<void> _test() async {
    setState(() { _busy = true; _message = '연결 확인 중…'; });
    final client = http.Client();
    try {
      final base = ServerConfig.normalize(_address.text);
      final results = await Future.wait([
        client.get(Uri.parse(ServerConfig.endpoint(ServerConfig.apiBase(base), 'api/health'))).timeout(const Duration(seconds: 8)),
        client.get(Uri.parse(ServerConfig.endpoint(ServerConfig.databaseBase(base), 'syncversion.txt'))).timeout(const Duration(seconds: 8)),
        client.get(Uri.parse(ServerConfig.endpoint(ServerConfig.databaseBase(base), 'api/server-info'))).timeout(const Duration(seconds: 8)),
      ].map((future) => future.catchError((Object _) => http.Response('', 503))));
      final dbOk = results[1].statusCode == 200 && RegExp(r'^db\s+\d+\s+https?://', multiLine: true).hasMatch(results[1].body);
      var features = <String, dynamic>{};
      if (results[2].statusCode == 200) {
        final info = jsonDecode(results[2].body);
        if (info is Map && info['features'] is Map) features = Map<String, dynamic>.from(info['features']);
      }
      if (mounted) setState(() => _message = '웹/API: ${results[0].statusCode == 200 ? "연결됨" : "연결 실패"}\n'
        'DB: ${dbOk ? "연결됨" : "연결 실패"}\n'
        'graph: ${features["graph"] == true ? "서버에서 지원한다고 안내함" : "지원 안내 없음"}\n'
        'LLM: ${features["llm"] == true ? "서버에서 지원한다고 안내함" : "지원 안내 없음"}');
    } catch (e) {
      if (mounted) setState(() => _message = e is FormatException ? e.message.toString() : '연결 확인에 실패했습니다.');
    } finally { client.close(); if (mounted) setState(() => _busy = false); }
  }

  Future<void> _save() async {
    try {
      final base = ServerConfig.normalize(_address.text);
      await Settings.prefs.setString('content_server_url', ServerConfig.apiBase(base));
      if (mounted) setState(() => _message = '저장했습니다. DB 갱신은 다음 앱 시작 시 확인합니다. 개인 기록 동기화 서버는 변경하지 않았습니다.');
    } on FormatException catch (e) { setState(() => _message = e.message.toString()); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('작품 서버 주소')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      const Text('내 Pi 또는 호환되는 Violet 서버 주소를 입력하세요. Pi 기본 포트는 웹/API 3001, DB 3002입니다. 다른 포트나 HTTPS 주소는 같은 주소 아래에서 각 기능을 제공해야 합니다.'),
      const SizedBox(height: 16),
      TextField(controller: _address, enabled: !_busy, autocorrect: false,
        keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: '작품 서버 주소', hintText: 'http://192.168.0.39:3001')),
      const SizedBox(height: 16),
      OutlinedButton(onPressed: _busy ? null : _test, child: const Text('연결 테스트')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('주소 저장')),
      if (_busy) const LinearProgressIndicator(),
      const SizedBox(height: 12), Text(_message),
      const SizedBox(height: 20),
      const Text('개인 백업은 앱·웹 기록 동기화 설정의 서버와 토큰을 사용합니다. 작품 서버를 변경해도 개인 기록을 다른 서버로 보내지 않습니다.'),
    ]),
  );
}
