// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/http.dart';
import 'package:rhttp/rhttp.dart';
import 'package:violet/log/log.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/thread/semaphore.dart';

class HttpWrapper {
  static String accept =
      'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7';
  static String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static String mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 6.0.1; Moto G (4)) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Mobile Safari/537.36';
  static Semaphore throttlerExHentai = Semaphore(maxCount: 1);
  static Semaphore throttlerEHentai = Semaphore(maxCount: 4);
  static Map<String, http.Response> cacheResponse = <String, http.Response>{};

  static void applyConcurrencySettings() {
    throttlerExHentai.setMaxCount(
      Settings.exHentaiHttpConcurrency.value.clamp(1, 8).toInt(),
    );
    throttlerEHentai.setMaxCount(
      Settings.eHentaiHttpConcurrency.value.clamp(1, 8).toInt(),
    );
  }

  // Bound session-long EH HTML caching (large galleries contain many pages).
  static void cache(String url, http.Response response) {
    cacheResponse.remove(url);
    cacheResponse[url] = response;
    while (cacheResponse.length > 192) {
      cacheResponse.remove(cacheResponse.keys.first);
    }
  }
}

bool _isScriptUrl(String url) {
  const hosts = [
    'ltn.gold-usergeneratedcontent.net',
    'raw.githubusercontent.com/project-violet/violet-message-search',
  ];

  const blacklist = ['ltn.gold-usergeneratedcontent.net/gg.js'];

  return hosts.any((element) => url.contains(element)) &&
      !blacklist.any((element) => url.contains(element));
}

Future<http.Response> get(
  String url, {
  Map<String, String>? headers,
  Duration? timeout,
}) async {
  if (url.contains('exhentai.org') || url.contains('e-hentai.org')) {
    return await _ehentaiGet(url, headers: headers, timeout: timeout);
  } else if (_isScriptUrl(url)) {
    return await _scriptGet(url, headers: headers, timeout: timeout);
  }

  Logger.info('[Http Request] GET: $url');
  final res = await http.get(Uri.parse(url), headers: headers);
  if (res.statusCode != 200) {
    Logger.warning('[Http Response] CODE: ${res.statusCode}, GET: $url');
  }

  return res;
}

Future<http.Response> post(
  String url, {
  Map<String, String>? headers,
  dynamic body,
  Encoding? encoding,
}) async {
  Logger.info('[Http Request] POST: $url');
  var res = await http.post(
    Uri.parse(url),
    headers: headers,
    body: body,
    encoding: encoding,
  );
  if (res.statusCode != 200) {
    Logger.warning('[Http Response] CODE: ${res.statusCode}, POST: $url');
  }
  return res;
}

Future<http.Response> _ehentaiGet(
  String url, {
  Map<String, String>? headers,
  Duration? timeout,
}) async {
  final cached = HttpWrapper.cacheResponse[url];
  if (cached != null) return cached;

  // Apply saved values even on the first request after app startup.
  HttpWrapper.applyConcurrencySettings();
  final throttler = url.contains('exhentai.org')
      ? HttpWrapper.throttlerExHentai
      : HttpWrapper.throttlerEHentai;
  final release = await throttler.acquire();
  try {
    // Another request may have filled the cache while we waited.
    final previous = HttpWrapper.cacheResponse[url];
    if (previous != null) return previous;

    Logger.info('[Http Request] GET: $url');
    // A stalled request must not hold the global ExHentai slot indefinitely.
    // Keep retries bounded; never release the same semaphore permit twice.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final client = await RhttpCompatibleClient.create(
          settings: const ClientSettings(
            httpVersionPref: HttpVersionPref.http3,
          ),
        );
        final request = client.get(Uri.parse(url), headers: headers);
        final response = Settings.ignoreTimeout.value
            ? await request
            : await request.timeout(timeout ?? const Duration(seconds: 15));
        if (response.statusCode != 200) {
          Logger.warning(
            '[Http Response] CODE: ${response.statusCode}, GET: $url',
          );
        } else if (response.body.trim().isNotEmpty) {
          HttpWrapper.cache(url, response);
        }
        return response;
      } catch (error, stackTrace) {
        Logger.error('[Http Request] GET: $url\nE:$error\n$stackTrace');
        final retryable =
            error is TimeoutException ||
            error.toString().contains('Connection reset by peer');
        if (!retryable || attempt == 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    throw StateError('ExHentai request retries exhausted');
  } finally {
    release.call();
  }
}

Future<http.Response> _scriptGet(
  String url, {
  Map<String, String>? headers,
  Duration? timeout,
}) async {
  Logger.info('[Http Cache] GET: $url');

  if (HttpWrapper.cacheResponse.containsKey(url)) {
    return HttpWrapper.cacheResponse[url]!;
  }

  Response res;
  final client = await RhttpCompatibleClient.create(
    settings: const ClientSettings(httpVersionPref: HttpVersionPref.http2),
  );
  if (timeout == null || Settings.ignoreTimeout.value) {
    res = await client.get(Uri.parse(url), headers: headers);
  } else {
    res = await client.get(Uri.parse(url), headers: headers).timeout(timeout);
  }

  if (res.statusCode != 200) {
    Logger.warning('[Http Response] CODE: ${res.statusCode}, GET: $url');
  }

  if (!HttpWrapper.cacheResponse.containsKey(url) &&
      res.statusCode == 200 &&
      res.body.trim().isNotEmpty) {
    HttpWrapper.cache(url, res);
  }

  return res;
}
