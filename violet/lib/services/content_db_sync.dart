// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:violet/database/database.dart';
import 'package:violet/log/log.dart';
import 'package:violet/version/sync.dart';

/// Complete Korean snapshots have their own version, separate from bookmarks
/// and incremental chunk synchronization. User databases are never replaced.
class ContentDbSync {
  static Future<bool>? _inFlight;

  static Future<bool> automatic(bool Function() canApply) {
    return _inFlight ??= _exchange(canApply).whenComplete(() {
      _inFlight = null;
    });
  }

  static Future<bool> _exchange(bool Function() canApply) async {
    File? temporary;
    final client = http.Client();
    try {
      if (!Platform.isIOS && !Platform.isAndroid && !Platform.isMacOS) {
        return false;
      }
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt('db_exists') != 1 ||
          prefs.getString('databasetype') == 'dummy') {
        return false;
      }
      final manifest = await client
          .get(Uri.parse(SyncManager.syncInfoURL('main')))
          .timeout(const Duration(seconds: 10));
      if (manifest.statusCode != 200) return false;
      final lines = manifest.body.split('\n').reversed;
      int? version;
      Uri? download;
      for (final line in lines) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 3 || fields.first != 'db') continue;
        version = int.tryParse(fields[1]);
        download = Uri.tryParse('${fields[2]}-korean.db');
        break;
      }
      if (version == null || version <= 0 || download == null ||
          !['http', 'https'].contains(download.scheme)) return false;
      if ((prefs.getInt('content-snapshot-version') ?? prefs.getInt('synclatest')) == version) return false;
      final manager = await DataBaseManager.getInstance();
      final destination = File(manager.dbPath!);
      temporary = File('${destination.path}.updating');
      await Dio(BaseOptions(receiveTimeout: const Duration(minutes: 2)))
          .download(download.toString(), temporary.path);
      final candidate = await openDatabase(temporary.path,
          readOnly: true, singleInstance: false);
      try {
        final check = await candidate.rawQuery('PRAGMA quick_check');
        final count = await candidate.rawQuery(
            'SELECT COUNT(*) AS count FROM HitomiColumnModel');
        if (check.isEmpty || check.first.values.first != 'ok' ||
            (count.first['count'] as int) == 0) {
          throw StateError('Invalid content snapshot');
        }
      } finally {
        await candidate.close();
      }
      // Defer replacement while a viewer or another modal page is active.
      if (!canApply()) return false;
      await DataBaseManager.instanceLock.synchronized(() async {
        await DataBaseManager.openLock.synchronized(() async {
          await DataBaseManager.reloadInstance();
          final wal = File('${destination.path}-wal');
          if (await wal.exists() && await wal.length() > 0) {
            throw StateError('Content database is still in use');
          }
          for (final suffix in ['-wal', '-shm']) {
            final sidecar = File('${destination.path}$suffix');
            if (await sidecar.exists()) await sidecar.delete();
          }
          await temporary!.rename(destination.path);
        });
      });
      await prefs.setInt('content-snapshot-version', version);
      return true;
    } catch (error) {
      Logger.error('[ContentDbSync] Update failed; retry on next foreground');
      return false;
    } finally {
      client.close();
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}
