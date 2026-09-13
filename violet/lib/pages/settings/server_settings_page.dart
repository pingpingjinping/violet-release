import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:violet/services/content_db_sync.dart';
import 'package:violet/services/server_config.dart';
import 'package:violet/settings/settings.dart';

class ServerSettingsPage extends StatefulWidget {
  const ServerSettingsPage({super.key});
  @override
  State<ServerSettingsPage> createState() => _ServerSettingsPageState();
}

class _ServerSettingsPageState extends State<ServerSettingsPage> {
  final _address = TextEditingController(text: ServerConfig.webBase);
  final _dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
  bool _busy = false;
  int? _installedDbVersion;
  DateTime? _lastDbSync;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _loadDbStatus();
  }

  void _loadDbStatus() {
    final version =
        Settings.prefs.getInt('content-snapshot-version') ??
        Settings.prefs.getInt('synclatest');
    final lastSyncMillis = Settings.prefs.getInt(
      ContentDbSync.lastSuccessfulSyncKey,
    );
    if (!mounted) return;
    setState(() {
      _installedDbVersion = version;
      _lastDbSync = lastSyncMillis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastSyncMillis);
    });
  }

  String _formatDateTime(DateTime value) =>
      _dateTimeFormat.format(value.toLocal());

  String get _dbVersionLabel => _installedDbVersion?.toString() ?? '기록 없음';

  String get _dbReleaseTimeLabel => _installedDbVersion == null
      ? '기록 없음'
      : _formatDateTime(
          DateTime.fromMillisecondsSinceEpoch(_installedDbVersion! * 1000),
        );

  String get _lastDbSyncLabel => _lastDbSync == null
      ? '기록 없음 (다음 DB 적용부터 기록)'
      : _formatDateTime(_lastDbSync!);

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _syncStatus(
    http.Client client,
    String apiBase,
  ) async {
    final response = await client
        .get(Uri.parse(ServerConfig.endpoint(apiBase, 'api/sync/status')))
        .timeout(const Duration(seconds: 10));
    if ([404, 405].contains(response.statusCode)) {
      throw const FormatException(
        '이 서버는 Pi DB 최신화를 지원하지 않습니다. 서버의 host-sync 설치가 필요합니다.',
      );
    }
    if (response.statusCode != 200) {
      throw FormatException('동기화 상태 확인 실패: HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('서버의 동기화 상태 형식이 올바르지 않습니다.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _message = '연결 확인 중…';
    });
    final client = http.Client();
    try {
      final base = ServerConfig.normalize(_address.text);
      final results = await Future.wait(
        [
          client
              .get(
                Uri.parse(
                  ServerConfig.endpoint(
                    ServerConfig.apiBase(base),
                    'api/health',
                  ),
                ),
              )
              .timeout(const Duration(seconds: 8)),
          client
              .get(
                Uri.parse(
                  ServerConfig.endpoint(
                    ServerConfig.databaseBase(base),
                    'syncversion.txt',
                  ),
                ),
              )
              .timeout(const Duration(seconds: 8)),
          client
              .get(
                Uri.parse(
                  ServerConfig.endpoint(
                    ServerConfig.databaseBase(base),
                    'api/server-info',
                  ),
                ),
              )
              .timeout(const Duration(seconds: 8)),
        ].map(
          (future) => future.catchError((Object _) => http.Response('', 503)),
        ),
      );
      final dbOk =
          results[1].statusCode == 200 &&
          RegExp(
            r'^db\s+\d+\s+https?://',
            multiLine: true,
          ).hasMatch(results[1].body);
      var features = <String, dynamic>{};
      if (results[2].statusCode == 200) {
        final info = jsonDecode(results[2].body);
        if (info is Map && info['features'] is Map) {
          features = Map<String, dynamic>.from(info['features']);
        }
      }
      if (mounted) {
        setState(
          () => _message =
              '웹/API: ${results[0].statusCode == 200 ? "연결됨" : "연결 실패"}\n'
              'DB: ${dbOk ? "연결됨" : "연결 실패"}\n'
              'graph: ${features["graph"] == true ? "서버에서 지원한다고 안내함" : "지원 안내 없음"}\n'
              'LLM: ${features["llm"] == true ? "서버에서 지원한다고 안내함" : "지원 안내 없음"}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is FormatException
              ? e.message.toString()
              : '연결 확인에 실패했습니다.',
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    try {
      final base = ServerConfig.normalize(_address.text);
      if (!await Settings.prefs.setString(
        'content_server_url',
        ServerConfig.apiBase(base),
      )) {
        throw const FormatException('주소 저장에 실패했습니다.');
      }
      if (mounted) {
        setState(
          () => _message =
              '저장했습니다. DB 갱신은 다음 앱 시작 시 확인합니다. 개인 기록 동기화 서버는 변경하지 않았습니다.',
        );
      }
    } on FormatException catch (e) {
      if (mounted) setState(() => _message = e.message.toString());
    }
  }

  Future<void> _syncDatabase() async {
    setState(() {
      _busy = true;
      _message = 'Pi DB 동기화 준비 중…';
    });
    final client = http.Client();
    try {
      final normalized = ServerConfig.normalize(_address.text);
      final apiBase = ServerConfig.apiBase(normalized);
      if (!await Settings.prefs.setString('content_server_url', apiBase)) {
        throw const FormatException('서버 주소 저장에 실패했습니다.');
      }

      final beforeVersion = await ContentDbSync.remoteVersion();
      final before = await _syncStatus(client, apiBase);
      if (before['hostManaged'] != true) {
        throw const FormatException(
          '이 서버는 Pi DB 최신화를 지원하지 않습니다. 서버의 host-sync 설치가 필요합니다.',
        );
      }
      final beforeLastSync = before['lastSync']?.toString();

      if (mounted) setState(() => _message = 'Pi 원본 DB 최신화 요청 중…');
      final trigger = await client
          .post(Uri.parse(ServerConfig.endpoint(apiBase, 'api/sync/trigger')))
          .timeout(const Duration(seconds: 10));
      if ([404, 405].contains(trigger.statusCode)) {
        throw const FormatException(
          '이 서버는 Pi DB 최신화를 지원하지 않습니다. 서버의 host-sync 설치가 필요합니다.',
        );
      }
      if (![200, 202].contains(trigger.statusCode)) {
        throw FormatException('Pi DB 동기화 요청 실패: HTTP ${trigger.statusCode}');
      }

      var observedRunning = false;
      final syncDeadline = DateTime.now().add(const Duration(minutes: 15));
      while (DateTime.now().isBefore(syncDeadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        final status = await _syncStatus(client, apiBase);
        final state = status['status']?.toString() ?? '';
        if (state == 'error') {
          throw FormatException(
            'Pi DB 최신화 실패: ${status["error"] ?? "원인을 확인할 수 없습니다."}',
          );
        }
        if (state == 'checking' || state == 'applying_chunks') {
          observedRunning = true;
          if (mounted) setState(() => _message = 'Pi 원본 DB 최신화 중…');
          continue;
        }
        final lastSync = status['lastSync']?.toString();
        if (state == 'idle' &&
            (observedRunning ||
                (lastSync != null && lastSync != beforeLastSync))) {
          break;
        }
      }
      if (DateTime.now().isAfter(syncDeadline)) {
        throw const FormatException('Pi DB 최신화 시간이 15분을 넘었습니다.');
      }

      if (mounted) setState(() => _message = '한국어 DB 스냅샷 생성 대기 중…');
      final snapshotDeadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(snapshotDeadline)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final currentVersion = await ContentDbSync.remoteVersion();
        if (currentVersion != beforeVersion) break;
      }

      final updated = await ContentDbSync.manual(
        canApply: () => mounted,
        onProgress: (stage, received, total) {
          if (!mounted) return;
          final percent = total > 0
              ? ' ${(received * 100 / total).toStringAsFixed(0)}%'
              : '';
          setState(() => _message = '$stage$percent');
        },
      );
      if (mounted) {
        _loadDbStatus();
        setState(
          () => _message = updated
              ? 'Pi와 앱의 작품 DB를 최신 버전으로 적용했습니다.'
              : 'Pi DB 동기화 완료. 앱의 작품 DB도 이미 최신입니다.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is FormatException
              ? e.message.toString()
              : 'DB 최신화에 실패했습니다. 서버 연결과 로그를 확인해 주세요.',
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('작품 서버 주소')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '내 Pi 또는 호환되는 Violet 서버 주소를 입력하세요. Pi 기본 포트는 웹/API 3001, DB 3002입니다. 다른 포트나 HTTPS 주소는 같은 주소 아래에서 각 기능을 제공해야 합니다.',
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '앱 작품 DB 상태',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                Text('DB 버전: $_dbVersionLabel'),
                const SizedBox(height: 4),
                Text('DB 배포 시각: $_dbReleaseTimeLabel'),
                const SizedBox(height: 4),
                Text('마지막 앱 DB 동기화: $_lastDbSyncLabel'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _address,
          enabled: !_busy,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '작품 서버 주소',
            hintText: 'http://192.168.0.39:3001',
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: _busy ? null : _test,
          child: const Text('연결 테스트'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('주소 저장'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _syncDatabase,
          icon: const Icon(Icons.sync),
          label: const Text('Pi DB 최신화 + 앱 적용'),
        ),
        if (_busy) const LinearProgressIndicator(),
        const SizedBox(height: 12),
        Text(_message),
        const SizedBox(height: 20),
        const Text(
          '위 최신화 버튼은 Pi 원본 DB 동기화가 끝난 뒤 한국어 DB를 다시 생성하고, 새 버전이 있으면 검증 후 앱에 적용합니다.',
        ),
        const SizedBox(height: 12),
        const Text(
          '개인 백업은 앱·웹 기록 동기화 설정의 서버와 토큰을 사용합니다. 작품 서버를 변경해도 개인 기록을 다른 서버로 보내지 않습니다.',
        ),
      ],
    ),
  );
}
