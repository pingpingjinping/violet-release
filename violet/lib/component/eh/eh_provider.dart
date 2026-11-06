// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:html_unescape/html_unescape.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:violet/component/eh/eh_headers.dart';
import 'package:violet/component/eh/eh_parser.dart';
import 'package:violet/component/image_provider.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/thread/semaphore.dart';

class EHentaiImageProvider extends VioletImageProvider {
  // List<String> urls;
  int count;
  bool initialized = false;
  bool isEHentai;
  String thumbnail;
  List<String> pagesUrl;
  late List<String?> urls;
  late List<String> imgUrls;
  late Semaphore pageThrottler;
  final Map<int, Future<String>> _pendingImageUrls = {};
  final Future<String> Function(String url, {required bool bypassCache})
  _requestImagePage;
  int imagesPerPage;

  EHentaiImageProvider({
    required this.count,
    required this.thumbnail,
    required this.pagesUrl,
    required this.isEHentai,
    required this.imagesPerPage,
    Future<String> Function(String url, {required bool bypassCache})?
    requestImagePage,
  }) : _requestImagePage = requestImagePage ?? EHSession.requestString;

  @override
  Future<void> init() async {
    if (initialized) return;
    pageThrottler = Semaphore(maxCount: 1);
    urls = List<String?>.filled(count, null);
    // for (int i = 0; i < pagesUrl.length; i++) {
    //   var phtml = await EHSession.requestString(pagesUrl[i]);
    //   urls.addAll(EHParser.getImagesUrl(phtml));
    // }
    imgUrls = List<String>.filled(count, '');
    initialized = true;
  }

  @override
  Future<List<String>> getSmallImagesUrl() async {
    var phtml = await EHSession.requestString('${pagesUrl[0]}&inline_set=ts_l');
    return EHParser.getThumbnailImages(phtml);
  }

  @override
  Future<String> getThumbnailUrl() async {
    return thumbnail;
  }

  @override
  Future<Map<String, String>> getHeader(int page) async {
    final prefs = await SharedPreferences.getInstance();
    var cookie = prefs.getString('eh_cookies');
    return {'Cookie': cookie ?? ''};
  }

  @override
  Future<String> getImageUrl(int page) => _getImageUrl(page, refresh: false);

  @override
  Future<String> getImageUrlForRetry(int page) =>
      _getImageUrl(page, refresh: true);

  Future<String> _getImageUrl(int page, {required bool refresh}) {
    final existing = _pendingImageUrls[page];
    if (existing != null) return existing;
    if (!refresh && imgUrls[page].isNotEmpty) {
      return Future<String>.value(imgUrls[page]);
    }

    // Share ongoing lookups while preserving the last URL if a refresh fails.
    return _pendingImageUrls[page] = _resolveImageUrl(page, refresh: refresh)
        .whenComplete(() {
          _pendingImageUrls.remove(page);
        });
  }

  Future<String> _resolveImageUrl(int page, {required bool refresh}) async {
    final release = await pageThrottler.acquire();
    try {
      if (urls[page] == null) {
        final galleryPage = page ~/ imagesPerPage;
        final html = await EHSession.requestString(
          '${pagesUrl[galleryPage]}&inline_set=ts_m',
        );
        final pages = EHParser.getImagesUrl(html);
        final firstIndex = galleryPage * imagesPerPage;
        for (var i = 0; i < pages.length && firstIndex + i < count; i++) {
          urls[firstIndex + i] = pages[i];
        }
      }
    } finally {
      // A failed gallery HTML request must not strand every later page.
      release.call();
    }

    final imagePageUrl = urls[page];
    if (imagePageUrl == null) {
      throw StateError('Could not find ExHentai image page $page');
    }
    final html = await _requestImagePage(imagePageUrl, bypassCache: refresh);
    final imageUrl = Settings.downloadEhRawImage.value
        ? HtmlUnescape().convert(EHParser.getOriginalImageAddress(html))
        : EHParser.getImageAddress(html);
    if (imageUrl.trim().isEmpty) {
      throw StateError('Image URL is empty for page $page');
    }
    return imgUrls[page] = imageUrl;
  }

  @override
  bool canGetImageUrlSync() => false;

  @override
  String? getImageUrlSync(int page) => null;

  @override
  int length() {
    return count;
  }

  @override
  Future<double> getEstimatedImageHeight(int page, double baseWidth) async {
    return -1;
  }

  @override
  bool isRefreshable() {
    return false;
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> refreshPartial(List<bool> target) async {}

  @override
  Future<double> getOriginalImageHeight(int page) async {
    return -1;
  }
}
