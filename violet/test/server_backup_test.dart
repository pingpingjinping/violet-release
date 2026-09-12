import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:violet/services/backup_codec.dart';
import 'package:violet/services/pi_backup.dart';
import 'package:violet/services/server_config.dart';

Map<String, dynamic> payload([int count = 1]) => {
  'schema': 1, 'userAppId': 'test-user-app-id', 'tables': {
    'BookmarkGroup': [{'Id': 1, 'Name': 'folder'}],
    'BookmarkArticle': [{'Id': 1, 'Article': '42', 'GroupId': 1}],
    'BookmarkArtist': [],
    'ArticleReadLog': List.generate(count, (i) => {'Id': i + 1, 'Article': '${i % 100}', 'DateTimeStart': '2026-09-12T00:00:00Z', 'LastPage': 5, 'Type': 0}),
  },
};

void main() {
  test('LAN server URLs change together while public CDN URLs are preserved', () {
    expect(ServerConfig.normalize('192.168.1.20:3001/'), 'http://192.168.1.20:3001');
    expect(ServerConfig.databaseBase('http://192.168.1.20:3001'), 'http://192.168.1.20:3002');
    expect(ServerConfig.downloadUrl('http://192.168.0.39:3002/rawdata-korean.db', 'http://192.168.1.20:3001'), 'http://192.168.1.20:3002/rawdata-korean.db');
    expect(ServerConfig.downloadUrl('http://localhost:3002/rawdata-korean.db', 'https://example.com/violet'), 'https://example.com/violet/rawdata-korean.db');
    expect(ServerConfig.downloadUrl('http://example.com/rawdata-korean.db', 'https://example.com'), 'https://example.com/rawdata-korean.db');
    expect(ServerConfig.downloadUrl('https://cdn.example.com/db', 'http://192.168.1.20:3001'), 'https://cdn.example.com/db');
    expect(() => ServerConfig.normalize('https://user:pass@example.com'), throwsFormatException);
    expect(() => ServerConfig.normalize('http://example.com?token=x'), throwsFormatException);
  });

  test('Backup compression preserves ID and all 15001 read sessions', () {
    final source = payload(15001);
    final restored = decodeBackup(encodeBackup(source));
    expect(restored['userAppId'], 'test-user-app-id');
    expect((restored['tables']['ArticleReadLog'] as List).length, 15001);
    expect(restored, source);
  });

  test('Corrupt files and invalid table/folder references are rejected', () {
    expect(() => decodeBackup(Uint8List.fromList(gzip.encode([1, 2, 3]))), throwsA(anything));
    final bad = payload();
    bad['tables']['DownloadItem'] = [];
    expect(() => encodeBackup(bad), throwsFormatException);
    final orphan = payload();
    orphan['tables']['BookmarkArticle'][0]['GroupId'] = 99;
    expect(() => encodeBackup(orphan), throwsFormatException);
  });

  test('SQLite import restores full history and rolls back all tables on failure', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    try {
      await db.execute('CREATE TABLE BookmarkGroup (Id INTEGER PRIMARY KEY, Name TEXT NOT NULL)');
      await db.execute('CREATE TABLE BookmarkArticle (Id INTEGER PRIMARY KEY, Article TEXT, GroupId INTEGER)');
      await db.execute('CREATE TABLE BookmarkArtist (Id INTEGER PRIMARY KEY)');
      await db.execute('CREATE TABLE ArticleReadLog (Id INTEGER PRIMARY KEY, Article TEXT, DateTimeStart TEXT, LastPage INTEGER, Type INTEGER)');
      await restoreBackupTables(db, payload(15001));
      expect((await db.rawQuery('SELECT COUNT(*) AS n FROM ArticleReadLog')).first['n'], 15001);
      final bad = payload();
      bad['tables']['BookmarkGroup'][0]['Name'] = null;
      await expectLater(restoreBackupTables(db, bad), throwsA(anything));
      expect((await db.query('BookmarkGroup')).first['Name'], 'folder');
      expect((await db.rawQuery('SELECT COUNT(*) AS n FROM ArticleReadLog')).first['n'], 15001);
    } finally { await db.close(); }
  });
}
