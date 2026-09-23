// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';
// import 'package:html/parser.dart';
import 'package:violet/component/hitomi/hitomi.dart';
import 'package:violet/context/viewer_context.dart';
import 'package:violet/log/log.dart';
import 'package:violet/network/wrapper.dart' as http;
import 'package:violet/script/script_webview.dart';
import 'package:violet/util/helper.dart';
import 'package:violet/widgets/article_item/image_provider_manager.dart';

class ScriptManager {
  static const String scriptNoCDNUrl =
      'https://github.com/project-violet/scripts/blob/main/hitomi_get_image_list_v3.js';
  static const String scriptUrl =
      'https://raw.githubusercontent.com/project-violet/scripts/main/hitomi_get_image_list_v3.js';
  static const String scriptV4Url =
      'https://github.com/project-violet/scripts/raw/main/hitomi_get_image_list_v4_model.js';
  static const String enableRefreshV4NoWebViewCheckUrl =
      'https://raw.githubusercontent.com/project-violet/scripts/refs/heads/main/enableRefreshV4NoWebView';
  static bool enableV4 = false;
  static bool enableRefreshV4NoWebView = true;
  static String? v4Cache;
  static String? scriptCache;
  static late JavascriptRuntime runtime;
  static late DateTime latestUpdate;
  static DateTime? _latestRefreshAttempt;

  // static Future<void> init() async {
  //   Future fallbackFail(Future Function() fn) async {
  //     await catchUnwind(fn, (e, st) async {
  //       await Logger.warning(
  //         '[ScriptManager-init] W: $e\n'
  //         '$st',
  //       );
  //       debugPrint(e.toString());
  //     });
  //   }

  //   await fallbackFail(() async {
  //     final scriptHtml = (await http.get(scriptNoCDNUrl)).body;
  //     scriptCache = json.decode(
  //       parse(
  //         scriptHtml,
  //       ).querySelector("script[data-target='react-app.embeddedData']")!.text,
  //     )['payload']['blob']['rawBlob'];
  //   });

  //   if (scriptCache == null) {
  //     await fallbackFail(() async {
  //       scriptCache = (await http.get(scriptUrl)).body;
  //     });
  //   }

  //   await fallbackFail(() async {
  //     v4Cache = (await http.get(scriptV4Url)).body;
  //   });

  //   await fallbackFail(() async {
  //     final check = (await http.get(enableRefreshV4NoWebViewCheckUrl)).body;
  //     enableRefreshV4NoWebView = int.parse(check) == 1;
  //     if (enableRefreshV4NoWebView) {
  //       await refreshV4NoWebView();
  //     }
  //   });

  //   await fallbackFail(() async {
  //     initRuntime();
  //   });
  // }

  static Future<void> refresh() async {
    // Avoid hitting gg.js on every search/article open. The previous throttle
    // ran only after the V4 request, so successful V4 refreshes bypassed it.
    final now = DateTime.now();
    if (_latestRefreshAttempt != null &&
        now.difference(_latestRefreshAttempt!).inMinutes < 5) {
      return;
    }
    _latestRefreshAttempt = now;

    // 1. (V4) NoWebView가 활성화되어 있다면 해당 방법으로 refresh 시도, 아니라면 webview로 시도
    if (enableRefreshV4NoWebView) {
      if (await refreshV4NoWebView()) {
        return;
      }
    } else if (enableV4 && ScriptWebViewProxy.reload != null) {
      /// proxy may be calling `refreshV4` function
      ScriptWebViewProxy.reload!();
      return;
    }

    // 2. (V3) V4 disable 상태이거나 no web-view가 실패한다면 V3로 fallback한다
    await refreshV3();
  }

  static Future<void> refreshV3() async {
    final scriptTemp = (await http.get(scriptUrl)).body;
    replaceScriptCacheIfRequired(scriptTemp);
  }

  static Future<bool> refreshV4NoWebView() async {
    var success = false;
    await catchUnwind(
      () async {
        final ggBody = (await http.get(
          'https://ltn.gold-usergeneratedcontent.net/gg.js',
        )).body;
        final ggRuntime = getJavascriptRuntime();
        // TODO: 이유는 잘 모르겠으나 use strict를 삭제하지 않으면 gg instance를 찾을 수 없어서 실패함
        ggRuntime.evaluate(ggBody.split("'use strict';")[1]);
        final gg = ggRuntime.evaluate('''
              var r = "";
              for (var i = 0; i < 4096; i++) {
                r += gg.m(i).toString();
                r += ",";
              }
              r + '|' + gg.b
              ''').stringResult;
        await refreshV4(gg.split('|')[0], gg.split('|')[1]);
        success = true;
      },
      (e, st) async {
        await Logger.warning(
          '[ScriptManager-refreshV4NoWebView] W: $e\n'
          '$st',
        );
        debugPrint(e.toString());
      },
    );
    return success;
  }

  /// this function may be called by `ScriptWebView`
  static Future<void> refreshV4(String ggM, String ggB) async {
    enableV4 = true;
    v4Cache ??= (await http.get(scriptV4Url)).body;
    final scriptTemp = v4Cache!
        .replaceAll('%%gg.m%', ggM)
        .replaceAll('%%gg.b%', ggB);
    replaceScriptCacheIfRequired(scriptTemp);
  }

  static void replaceScriptCacheIfRequired(String scriptTemp) {
    if (scriptCache == scriptTemp) {
      return;
    }

    scriptCache = scriptTemp;
    initRuntime();
    ProviderManager.checkMustRefresh();
    ViewerContext.signal((c) => c.refreshImgUrlWhenRequired());
    Logger.info('[Script Manager] Update Sync!');
  }

  static void initRuntime() {
    latestUpdate = DateTime.now();
    runtime = getJavascriptRuntime();
    runtime.evaluate(scriptCache!);
  }

  static Future<String?> getGalleryInfoRaw(String id) async {
    final downloadUrl =
        'https://ltn.gold-usergeneratedcontent.net/galleries/$id.js';
    final headers = await runHitomiGetHeaderContent(id.toString());
    final galleryInfo = await http.get(downloadUrl, headers: headers);
    if (galleryInfo.statusCode != 200) {
      Logger.warning(
        '[Script Manager] Failed to get gallery info: '
        '${galleryInfo.statusCode}, Id: $id',
      );
      return null;
    }
    return galleryInfo.body;
  }

  static Future<ImageList?> runHitomiGetImageList(int id) async {
    try {
      return await HitomiImageResolver.getImageList(id);
    } catch (e, st) {
      Logger.error(
        '[script-HitomiGetImageList] E: $e\n'
        'Id: $id\n'
        '$st',
      );
      return null;
    }
  }

  static Future<Map<String, String>> runHitomiGetHeaderContent(
    String id,
  ) async {
    try {
      final jResult = '''
      {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:150.0) Gecko/20100101 Firefox/150.0",
        "Accept": "image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5",
        "Accept-Language": "en-US",
        "Referer": "https://hitomi.la/",
        "Sec-Fetch-Dest": "image",
        "Sec-Fetch-Mode": "no-cors",
        "Sec-Fetch-Site": "cross-site",
        "Priority": "u=4, i"
    }
      ''';
      final jResultObject = jsonDecode(jResult);

      if (jResultObject is Map<dynamic, dynamic>) {
        return Map<String, String>.from(jResultObject);
      } else {
        throw Exception(
          '[script-HitomiGetHeaderContent] E: JSError\n'
          'Id: $id\n'
          'Message: $jResult',
        );
      }
    } catch (e, st) {
      Logger.error(
        '[script-HitomiGetHeaderContent] E: $e\n'
        'Id: $id\n'
        '$st',
      );
      rethrow;
    }
  }
}

/// 히토미 최신 라우팅(a1, a2 서버 및 AVIF/Webp)을 완벽 지원하는 리졸버
class HitomiImageResolver {
  // Credits to https://discord.com/users/1407344738750824459
  static const String baseDomain = 'gold-usergeneratedcontent.net';

  static Future<ImageList> getImageList(
    int galleryId, {
    bool useAvif = false,
  }) async {
    try {
      // gg.js and gallery metadata are shared by the original image,
      // big-thumbnail, and small-thumbnail URL builders. Fetch each once per
      // gallery instead of repeating the same network work three times.
      final ggResponse = await http.get('https://ltn.$baseDomain/gg.js');
      if (ggResponse.statusCode != 200) {
        return const ImageList(
          urls: [],
          bigThumbnails: [],
          smallThumbnails: [],
        );
      }
      final ggText = ggResponse.body;

      final bMatch = RegExp(r"b:\s*'([^']+)'").firstMatch(ggText);
      final bValue = bMatch?.group(1) ?? '';

      final mList = RegExp(
        r'case (\d+):',
      ).allMatches(ggText).map((m) => m.group(1)!).toSet();

      int o1 = 0;
      int o2 = 1;
      final oMatches = RegExp(r'o = (\d+)').allMatches(ggText);
      if (oMatches.isNotEmpty) {
        o1 = int.parse(oMatches.first.group(1) ?? '0');
        o2 = int.parse(oMatches.last.group(1) ?? '1');
      }

      final galResponse = await http.get(
        'https://ltn.$baseDomain/galleries/$galleryId.js',
      );
      if (galResponse.statusCode != 200) {
        return const ImageList(
          urls: [],
          bigThumbnails: [],
          smallThumbnails: [],
        );
      }

      final content = galResponse.body.replaceFirst('var galleryinfo = ', '');
      final Map<String, dynamic> data = json.decode(content);
      final List<dynamic> files = data['files'] ?? [];

      final imageUrls = <String>[];
      final bigThumbnailUrls = <String>[];
      final smallThumbnailUrls = <String>[];

      final imageDomain = useAvif ? 'a' : 'w';
      final imageExt = useAvif ? 'avif' : 'webp';
      final bigThumbnailPath = useAvif ? 'avifbigtn' : 'webpbigtn';
      final smallThumbnailPath = useAvif
          ? 'avifsmallsmalltn'
          : 'webpsmalltn';

      for (final file in files) {
        final hash = file['hash'] as String;
        if (hash.isEmpty) continue;

        final part =
            hash[hash.length - 1] +
            hash[hash.length - 3] +
            hash[hash.length - 2];
        final s = int.parse(part, radix: 16).toString();

        final isModern = mList.contains(s);
        final node = isModern ? o2 : o1;
        final serverNum = node + 1;

        imageUrls.add(
          'https://$imageDomain$serverNum.$baseDomain/'
          '$bValue$s/$hash.$imageExt',
        );

        final thumbnailDomain = serverNum == 1 ? 'atn' : 'btn';
        final secondPath = hash.substring(hash.length - 1);
        final thirdPath = hash.substring(hash.length - 3, hash.length - 1);

        bigThumbnailUrls.add(
          'https://$thumbnailDomain.$baseDomain/'
          '$bigThumbnailPath/$secondPath/$thirdPath/$hash.$imageExt',
        );
        smallThumbnailUrls.add(
          'https://$thumbnailDomain.$baseDomain/'
          '$smallThumbnailPath/$secondPath/$thirdPath/$hash.$imageExt',
        );
      }

      return ImageList(
        urls: imageUrls,
        bigThumbnails: bigThumbnailUrls,
        smallThumbnails: smallThumbnailUrls,
      );
    } catch (e) {
      print('[Hitomi Resolver] 에러: $e');
      return const ImageList(
        urls: [],
        bigThumbnails: [],
        smallThumbnails: [],
      );
    }
  }

  static Future<List<String>> getImages(
    int galleryId, {
    bool useAvif = false,
  }) async {
    return (await getImageList(galleryId, useAvif: useAvif)).urls;
  }

  static Future<List<String>> getBigThumbnailUrls(
    int galleryId, {
    bool useAvif = false,
  }) async {
    return (await getImageList(galleryId, useAvif: useAvif)).bigThumbnails;
  }

  static Future<List<String>> getSmallThumbnailUrls(
    int galleryId, {
    bool useAvif = false,
  }) async {
    return (await getImageList(galleryId, useAvif: useAvif)).smallThumbnails ??
        [];
  }
}
