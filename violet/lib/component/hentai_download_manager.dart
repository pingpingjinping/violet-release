// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:violet/component/downloadable.dart';
import 'package:violet/component/hentai.dart';
import 'package:violet/database/query.dart';
import 'package:violet/settings/settings.dart';

class HentaiDonwloadManager {
  factory HentaiDonwloadManager.instance() => HentaiDonwloadManager();

  late RegExp urlMatcher;

  HentaiDonwloadManager() {
    urlMatcher = RegExp(r'^\d+$');
  }

  bool acceptURL(String url) {
    return urlMatcher.stringMatch(url) == url;
  }

  String defaultFormat() {
    //return "%(extractor)s/[%(id)s] %(title)s/%(file)s.%(ext)s";
    return Settings.downloadRule.value;
  }

  String fav() {
    return 'https://ltn.gold-usergeneratedcontent.net/favicon-192x192.png';
  }

  bool loginRequire() {
    return false;
  }

  bool logined() {
    return false;
  }

  String name() {
    return 'hentai';
  }

  Future<void> setSession(String id, String pwd) async {}

  Future<bool> tryLogin() async {
    return true;
  }

  Future<List<DownloadTask>?> createTask(
    String url,
    GeneralDownloadProgress gdp, {
    List<String>? existingPaths,
    Future<void> Function(DownloadTask)? onTask,
  }) async {
    final query = (await HentaiManager.idSearch(url)).results;
    if (query.isEmpty) return null;
    return createTaskFromQueryResult(
      query.first,
      gdp,
      existingPaths: existingPaths,
      onTask: onTask,
    );
  }

  Future<List<DownloadTask>?> createTaskFromQueryResult(
    QueryResult target,
    GeneralDownloadProgress gdp, {
    List<String>? existingPaths,
    Future<void> Function(DownloadTask)? onTask,
  }) async {
    gdp.simpleInfoCallback('[${target.id()}] ${target.title()}');

    final provider = await HentaiManager.getImageProvider(target);
    await provider.init();
    final thumbnailUrl = await provider.getThumbnailUrl();
    final thumbnailHeader = await provider.getHeader(0);
    gdp.thumbnailCallback(thumbnailUrl, jsonEncode(thumbnailHeader));

    // Only Recovery reuses the previously persisted page manifest. Retry
    // deliberately retains the original full-URL extraction behavior.
    final savedPaths =
        existingPaths != null &&
            existingPaths.length == provider.length() &&
            existingPaths.every((path) => !path.startsWith('violet-zip:'))
        ? existingPaths
        : null;
    final result = <DownloadTask>[];
    await gdp.progressCallback(0, provider.length());

    for (var i = 0; i < provider.length(); i++) {
      String? page;
      Map<String, String>? header;
      String extension;

      final oldPath = savedPaths == null ? null : savedPaths[i];
      final previous = oldPath == null ? null : File(oldPath);
      final alreadyDownloaded =
          previous != null &&
          await previous.exists() &&
          await previous.length() >= 5;

      if (alreadyDownloaded) {
        // Existing pages do not need an ExHentai image-page request.
        extension = path.extension(oldPath!).replaceFirst('.', '');
      } else {
        page = await provider.getImageUrl(i);
        header = await provider.getHeader(i);
        extension = _extensionFromImageUrl(page);
      }

      final task = DownloadTask(
        url: page,
        headers: header,
        downloadPath: oldPath,
        format: FileNameFormat(
          title: target.title(),
          id: target.id().toString(),
          laugage: target.language(),
          uploadDate: target.getDateTime().toString(),
          filenameWithoutExtension: intToString(i, pad: 3),
          artist: _firstPipeValue(target.artists()),
          group: _firstPipeValue(target.groups()),
          extension: extension,
          extractor: 'hentai',
          downloadDate: DateTime.now().toString(),
          className: target.classname(),
          length: provider.length().toString(),
        ),
      );
      result.add(task);
      if (onTask != null) await onTask(task);
      await gdp.progressCallback(i + 1, provider.length());
    }
    return result;
  }

  static String? _firstPipeValue(dynamic raw) {
    if (raw is! String) return null;

    for (final value in raw.split('|')) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) continue;

      final normalized = trimmed.toLowerCase();
      if (normalized == 'n/a' || normalized == 'unknown') continue;
      return trimmed;
    }

    return null;
  }

  // https://stackoverflow.com/questions/15193983/is-there-a-built-in-method-to-pad-a-string
  static String intToString(int i, {int pad = 0}) {
    var str = i.toString();
    var paddingToAdd = pad - str.length;
    return (paddingToAdd > 0)
        ? "${List.filled(paddingToAdd, '0').join('')}$i"
        : str;
  }

  static String _extensionFromImageUrl(String url) {
    if (url.contains('fullimg.php')) return 'jpg';

    final uri = Uri.tryParse(url);
    final filename = uri == null
        ? url.split('/').last
        : path.basename(uri.path);
    return path.extension(filename).replaceFirst('.', '');
  }
}
