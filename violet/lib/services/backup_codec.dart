import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const backupColumns = <String, Set<String>>{
  'BookmarkGroup': {'Id', 'Name', 'DateTime', 'Description', 'Color', 'Gorder'},
  'BookmarkArticle': {'Id', 'Article', 'DateTime', 'GroupId'},
  'BookmarkArtist': {'Id', 'Artist', 'IsGroup', 'DateTime', 'GroupId'},
  'ArticleReadLog': {'Id', 'Article', 'DateTimeStart', 'DateTimeEnd', 'LastPage', 'Type'},
  'SharedActivity': {'Kind', 'Device', 'Article', 'Origin', 'Timestamp', 'Page', 'Type'},
  'BookmarkUser': {'Id', 'User', 'Title', 'Subtitle', 'DateTime', 'GroupId'},
  'HistoryUser': {'Id', 'User', 'DateTime'},
  'BookmarkCropImage': {'Id', 'Article', 'Page', 'Area', 'AspectRatio', 'DateTime'},
};
const maxBackupRaw = 128 * 1024 * 1024;
const maxBackupCompressed = 16 * 1024 * 1024;

Uint8List encodeBackup(Map<String, dynamic> payload) {
  validateBackup(payload);
  final raw = utf8.encode(jsonEncode(payload));
  if (raw.length > maxBackupRaw) throw const FormatException('백업 원본이 128MiB를 초과합니다.');
  final bytes = Uint8List.fromList(gzip.encode(raw));
  if (bytes.length > maxBackupCompressed) throw const FormatException('압축 백업이 16MiB를 초과합니다.');
  return bytes;
}

class _BoundedBytes implements Sink<List<int>> {
  final builder = BytesBuilder(copy: false);
  int length = 0;
  @override
  void add(List<int> chunk) {
    length += chunk.length;
    if (length > maxBackupRaw) throw const FormatException('백업 원본이 너무 큽니다.');
    builder.add(chunk);
  }
  @override
  void close() {}
}

Map<String, dynamic> decodeBackup(Uint8List bytes) {
  if (bytes.length > maxBackupCompressed) throw const FormatException('압축 백업이 너무 큽니다.');
  final output = _BoundedBytes();
  final converter = gzip.decoder.startChunkedConversion(output);
  for (var offset = 0; offset < bytes.length; offset += 4096) {
    converter.add(bytes.sublist(offset, (offset + 4096).clamp(0, bytes.length).toInt()));
  }
  converter.close();
  final value = jsonDecode(utf8.decode(output.builder.takeBytes()));
  if (value is! Map<String, dynamic>) throw const FormatException('잘못된 백업 파일입니다.');
  validateBackup(value);
  return value;
}

void validateBackup(Map<String, dynamic> payload) {
  final user = payload['userAppId'];
  if (payload['schema'] != 1 || user is! String ||
      !RegExp(r'^[\x21-\x7e]{1,256}$').hasMatch(user) || payload['tables'] is! Map) {
    throw const FormatException('지원하지 않는 백업 형식입니다.');
  }
  final tables = payload['tables'] as Map;
  for (final required in ['BookmarkGroup', 'BookmarkArticle', 'BookmarkArtist', 'ArticleReadLog']) {
    if (!tables.containsKey(required)) throw const FormatException('필수 백업 항목이 없습니다.');
  }
  var total = 0;
  for (final entry in tables.entries) {
    final columns = backupColumns[entry.key];
    final rows = entry.value;
    if (columns == null || rows is! List) throw const FormatException('잘못된 백업 테이블입니다.');
    total += rows.length;
    if (total > 500000) throw const FormatException('백업 기록이 50만 개를 초과합니다.');
    final ids = <int>{};
    for (final row in rows) {
      if (row is! Map || row.keys.any((key) => !columns.contains(key)) ||
          row.values.any((v) => v != null && v is! String && v is! num)) {
        throw const FormatException('잘못된 백업 기록입니다.');
      }
      if (columns.contains('Id')) {
        final id = row['Id'];
        if (id is! int || id < 1 || !ids.add(id)) throw const FormatException('잘못된 기록 ID입니다.');
      }
      if (entry.key == 'SharedActivity') {
        if (!['read', 'download'].contains(row['Kind']) || row['Device'] is! String ||
            row['Article'] is! String || !RegExp(r'^\d{1,20}$').hasMatch(row['Article'] as String) ||
            !['app', 'web'].contains(row['Origin']) || row['Timestamp'] is! int ||
            row['Page'] is! int || row['Type'] is! int ||
            (row['Timestamp'] as int) <= 0 || (row['Page'] as int) < 0 ||
            (row['Page'] as int) > 1000000 || ![0, 1].contains(row['Type'])) {
          throw const FormatException('잘못된 공유 기록입니다.');
        }
      }
    }
  }
  final groups = (tables['BookmarkGroup'] as List).map((r) => (r as Map)['Id']).toSet();
  if (!groups.contains(1)) throw const FormatException('기본 북마크 폴더가 없습니다.');
  for (final name in ['BookmarkArticle', 'BookmarkArtist', 'BookmarkUser']) {
    for (final row in tables[name] as List? ?? []) {
      if (!groups.contains((row as Map)['GroupId'])) throw const FormatException('북마크 폴더 연결이 잘못되었습니다.');
    }
  }
}
