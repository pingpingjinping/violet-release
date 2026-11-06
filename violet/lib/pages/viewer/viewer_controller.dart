// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:extended_image/extended_image.dart'
    show ExtendedImageState, ExtendedNetworkImageProvider, ExtendedResizeImage;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:get/get.dart';
import 'package:violet/component/hitomi/hitomi_provider.dart';
import 'package:violet/component/hitomi/message_search.dart';
import 'package:violet/log/log.dart';
import 'package:violet/pages/viewer/image/online_image_failure_tracker.dart';
import 'package:violet/pages/viewer/image/online_image_retry_policy.dart';
import 'package:violet/pages/viewer/image/online_page_load_coordinator.dart';
import 'package:violet/pages/viewer/image/visible_online_page_recovery.dart';
import 'package:violet/pages/viewer/others/preload_page_view.dart';
import 'package:violet/pages/viewer/others/scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:violet/pages/viewer/viewer_page_provider.dart';
import 'package:violet/server/violet.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/widgets/article_item/image_provider_manager.dart';

enum ViewType { vertical, horizontal }

class ViewerController extends GetxController {
  /// viewer target options
  final ViewerPageProvider provider;
  late final int articleId;
  late final int maxPage;
  var onTwoPage = false.obs;
  var secondPageToSecondPage = Settings.secondPageToSecondPage.value.obs;

  /// this variable used in [_appBarTwoPage] and [_HorizontalViewerPageState]
  /// if true, then lock the [_onPageChanged] method on [_HorizontalViewerPageState]
  var onTwoPageJump = false;

  /// viewer callbacks
  late AsyncCallback close;
  late Function replace;
  late Function stopTimer;
  late Function startTimer;

  /// common viewer options
  var page = 0.obs;
  var viewType = Settings.isHorizontal.value
      ? ViewType.horizontal.obs
      : ViewType.vertical.obs;
  var animation = Settings.animation.value.obs;
  var rightToLeft = Settings.rightToLeft.value.obs;
  var imgQuality = Settings.imageQuality.value.obs;
  var fullscreen = (!Settings.disableFullScreen.value).obs;

  /// horizontal viewer option
  var viewScrollType = Settings.scrollVertical.value
      ? ViewType.vertical.obs
      : ViewType.horizontal.obs;

  /// vertical viewer options
  var padding = Settings.padding.value.obs;

  /// overlay options
  var leftRightButton = (!Settings.disableOverlayButton.value).obs;
  var appBarToBottom = Settings.moveToAppBarToBottom.value.obs;
  var showSlider = Settings.showSlider.value.obs;
  var indicator = Settings.showPageNumberIndicator.value.obs;
  late RxBool thumb;
  var thumbSize = Settings.thumbSize.value.obs;
  var search = false.obs;
  var bookmark = false.obs;

  double get thumbSizeValue =>
      [180.0, 140.0, 120.0, 96.0][thumbSize.value] *
      ((Platform.isWindows || Platform.isLinux || Platform.isMacOS)
          ? 3.0
          : 1.0);

  /// timer options
  var timer = false.obs;
  var timerTick = Settings.timerTick.value.obs;

  /// internal options
  var onSession = true.obs;
  var isStaring = true;
  var sliderOnChange = false;
  final _imageRetries = OnlineImageRetryCoordinator();
  // Actual image download failures, not pages still loading or resolving URLs.
  final failedOnlineImages = OnlineImageFailureTracker();
  late final visiblePageRecovery = VisibleOnlinePageRecovery(
    stagedImageRetries: provider.provider is HitomiImageProvider,
  );
  bool get isRefreshingImages => _imageRetries.isBusy;

  /// these are used on overlay
  var overlay = false.obs;
  var overlayButton = (!Settings.disableOverlayButton.value).obs;
  var opacity = 0.0.obs;

  /// scroll controllers
  /// instances declared with var can be replaced by the
  /// corresponding library implementation restrictions.
  final verticalItemScrollController = ItemScrollController();
  var horizontalPageController = PreloadPageController();
  var thumbController = ScrollController();
  final searchText = TextEditingController(text: '');
  SuggestionsController<(String, String, int)>? suggestionsController;

  /// Is enabled search?
  var messages = <MessageSearchResult>[];
  String latestSearch = '';
  var messageIndex = 0.obs;

  /// image infos
  late RxList<bool> isImageLoaded;
  late List<RxString?> urlCache;
  // Retain completed/failed requests across rebuilds so failures do not
  // restart in an unbounded loop or leave a permanent loading indicator.
  final _pageLoads = OnlinePageLoadCoordinator();
  final Map<(int, int), Future<void>> _pairedPageLoads = {};
  late List<Map<String, String>?> headerCache;
  late List<double> imgHeight;
  late List<double> estimatedImgHeight;
  late List<double> realImgHeight;
  late List<double> realImgWidth;
  late List<GlobalKey> imgKeys;
  late List<bool> loadingEstimaed;

  /// this variable used in [vertical_viewer_page]
  /// this will be consumed on [_itemPositionsListener]
  bool onJump = false;

  ViewerController(
    BuildContext context,
    this.provider, {
    required this.close,
    required this.replace,
    required this.stopTimer,
    required this.startTimer,
  }) {
    articleId = provider.id;
    maxPage = provider.uris.length;
    thumb = provider.useFileSystem.obs;
    isImageLoaded = List.filled(
      provider.uris.length,
      provider.useFileSystem,
    ).obs;

    onTwoPage =
        (!Settings.disableTwoPageView.value &&
                MediaQuery.of(context).orientation == Orientation.landscape)
            .obs;

    headerCache = List<Map<String, String>?>.filled(maxPage, null);
    urlCache = List<RxString?>.filled(maxPage, null);
    imgHeight = List<double>.filled(maxPage, 0);
    estimatedImgHeight = List<double>.filled(maxPage, 0);
    realImgHeight = List<double>.filled(maxPage, 0);
    realImgHeight = List<double>.filled(maxPage, 0);
    imgKeys = List<GlobalKey>.generate(
      provider.uris.length,
      (index) => GlobalKey(),
    );
    loadingEstimaed = List<bool>.filled(maxPage, false);
  }

  jump(int page) {
    if (page < 0) return;
    if (page >= maxPage &&
        (!secondPageToSecondPage.value || page >= maxPage + 1)) {
      return;
    }

    this.page.value = page;

    if (viewType.value == ViewType.vertical) {
      verticalItemScrollController.scrollTo(
        index: page,
        duration: const Duration(microseconds: 1),
        alignment: 0.12,
      );
    } else {
      horizontalPageController.jumpToPage(onTwoPage.value ? page ~/ 2 : page);
    }
  }

  move(int page) {
    if (page < 0) return;
    if (page >= maxPage &&
        (!secondPageToSecondPage.value || page >= maxPage + 1)) {
      return;
    }

    if (!animation.value) {
      jump(page);
      return;
    }

    this.page.value = page;

    if (viewType.value == ViewType.vertical) {
      sliderOnChange = true;
      verticalItemScrollController
          .scrollTo(
            index: page,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            alignment: 0.12,
          )
          .then(
            (value) =>
                Future.delayed(const Duration(milliseconds: 300)).then((value) {
                  sliderOnChange = false;
                }),
          );
    } else {
      horizontalPageController.animateToPage(
        onTwoPage.value ? page ~/ 2 : page,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }

  prev() => move(page.value - (onTwoPage.value ? 2 : 1));
  next() => move(page.value + (onTwoPage.value ? 2 : 1));

  Future<void> load(int index) {
    if (!provider.useProvider || index < 0 || index >= maxPage) {
      return Future<void>.value();
    }
    return _pageLoads.load(index, () async {
      visiblePageRecovery.metadataLoading(index, DateTime.now());
      try {
        await _loadPage(index);
        visiblePageRecovery.metadataReady(index);
      } catch (_) {
        // The coordinator performs its bounded retries. Only terminal errors
        // remain in FutureBuilder; recovery never acts on off-screen pages.
        visiblePageRecovery.metadataFailed(index, DateTime.now());
        rethrow;
      }
    });
  }

  /// A stable future for horizontally displayed two-page spreads.
  Future<void> loadPair(int first, int second) =>
      _pairedPageLoads.putIfAbsent((first, second), () async {
        await Future.wait([load(first), load(second)]);
      });

  /// Retrying the failed page must not invalidate other visible page caches.
  void retryPageLoad(int index) {
    if (index < 0 || index >= maxPage) return;
    _pageLoads.reset(index);
    _pairedPageLoads.clear();
  }

  Future<void> _loadPage(int index) async {
    if (headerCache[index] == null) {
      headerCache[index] = await provider.provider!.getHeader(index);
    }
    if (urlCache[index] == null) {
      final url = await provider.provider!.getImageUrl(index);
      if (url.trim().isEmpty) {
        throw StateError('Image URL is empty for page $index');
      }
      urlCache[index] = RxString(url);
    }
  }

  Future<void> precache(BuildContext context, int index) async {
    if (index < 0 || maxPage <= index) return;
    try {
      await load(index);
      if (!context.mounted) return;
      await precacheImage(
        CachedNetworkImageProvider(
          urlCache[index]!.value,
          headers: headerCache[index],
          maxWidth: Settings.useLowPerf.value
              ? (MediaQuery.of(context).size.width * 1.5).toInt()
              : null,
        ),
        context,
        onError: (error, stackTrace) {
          Logger.error('[precache-error] E: $error\n$stackTrace');
        },
      );
    } catch (error, stackTrace) {
      Logger.error('[precache-error] E: $error\n$stackTrace');
    }
  }

  middleButton() {
    if (!overlay.value) {
      overlay.value = !overlay.value;
      opacity.value = 1.0;
      if (!Settings.disableFullScreen.value) {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom],
        );
      }
    } else {
      if (!Settings.disableFullScreen.value) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      }
      opacity.value = 0.0;
      Future.delayed(
        const Duration(milliseconds: 300),
      ).then((value) => overlay.value = !overlay.value);
    }
  }

  leftButton() {
    if (rightToLeft.value) {
      prev();
    } else {
      next();
    }
  }

  rightButton() {
    if (rightToLeft.value) {
      next();
    } else {
      prev();
    }
  }

  gotoSearchIndex() {
    final index = messages[messageIndex.value - 1].page;

    jump(index);
  }

  onModifiedText() async {
    suggestionsController!.close();
    if (latestSearch == searchText.text) return;
    latestSearch == searchText.text;
    messages = (await VioletServer.searchMessageWord(
      articleId,
      searchText.text,
    ))!;
    messages = messages.where((e) => e.matchScore >= 80.0).toList();
    messages.sort((a, b) => a.page.compareTo(b.page));

    messageIndex.value = 1;

    gotoSearchIndex();
  }

  /// Automatic recovery handles visible failures and confirmed failed Hitomi
  /// pages just ahead of the reader. Only one request runs at a time.
  Future<bool> retryVisibleImage(
    VisiblePageRetry retry, {
    BuildContext? precacheContext,
  }) async {
    final index = retry.index;
    if (!provider.useProvider ||
        provider.provider == null ||
        index < 0 ||
        index >= maxPage ||
        urlCache[index] == null) {
      return false;
    }

    return _imageRetries.tryAutomatic(() async {
      // Do not consume a limited automatic retry while the manual retry
      // coordinator is busy or after another request finished this image.
      if (!onSession.value || isImageLoaded[index]) return;
      if (precacheContext != null && !failedOnlineImages.isFailed(index)) {
        return;
      }
      visiblePageRecovery.beginAutomaticRetry(retry, DateTime.now());
      await _retryImage(index, automatic: retry);

      // Off-screen widgets are not mounted, so changing their URL alone does
      // not send an image request. Actually fetch only confirmed failures.
      if (precacheContext != null &&
          imgKeys[index].currentState == null &&
          !isImageLoaded[index]) {
        await _precacheRecoveredHitomiImage(precacheContext, index);
      }
    });
  }

  Future<void> _precacheRecoveredHitomiImage(
    BuildContext context,
    int index,
  ) async {
    if (!context.mounted || !onSession.value) return;
    final url = urlCache[index]?.value;
    final header = headerCache[index];
    if (url == null || header == null) return;

    var failed = false;
    try {
      final policy = onlineImageRetryPolicy(provider.provider);
      final imageProvider = ExtendedResizeImage.resizeIfNeeded(
        provider: ExtendedNetworkImageProvider(
          url,
          headers: header,
          cache: false,
          retries: policy.retries,
          timeRetry: policy.interval,
        ),
        cacheHeight: Settings.useLowPerf.value
            ? (MediaQuery.of(context).size.width * 2.0).toInt()
            : null,
      );
      await precacheImage(
        imageProvider,
        context,
        onError: (error, stackTrace) {
          failed = true;
          Logger.warning(
            '[viewer-hitomi-lookahead] Page $index: $error\n$stackTrace',
          );
        },
      );
    } catch (error, stackTrace) {
      failed = true;
      Logger.warning(
        '[viewer-hitomi-lookahead] Page $index: $error\n$stackTrace',
      );
    }

    // A newly mounted ProviderImage now owns its state, and a newer URL must
    // never be overwritten by an older background request's completion.
    if (!onSession.value ||
        urlCache[index]?.value != url ||
        imgKeys[index].currentState != null) {
      return;
    }
    if (failed) {
      failedOnlineImages.markFailed(index);
      visiblePageRecovery.imageFailed(index, DateTime.now());
    } else {
      isImageLoaded[index] = true;
      failedOnlineImages.markLoaded(index);
      visiblePageRecovery.imageLoaded(index);
    }
  }

  /// The purple refresh button retries all currently confirmed image failures.
  Future<void> refreshFailedImages() async {
    final source = provider.provider;
    if (!provider.useProvider || source == null) return;

    await _imageRetries.runManual(() async {
      if (!onSession.value) return;
      final failedPages = failedOnlineImages.retryablePages(
        pageCount: maxPage,
        hasUrl: (index) => urlCache[index] != null,
      );
      if (failedPages.isEmpty) return;

      if (source.isRefreshable()) {
        try {
          // Hitomi can refresh its gallery URLs once for the entire batch.
          await source.refresh();
        } catch (error, stackTrace) {
          Logger.warning(
            '[viewer-refresh-failed-images] Provider refresh failed: '
            '$error\n$stackTrace',
          );
        }
      }

      for (final index in failedPages) {
        await _retryImage(index, confirmedFailureOnly: true);
      }
    });
  }

  Future<void> _retryImage(
    int index, {
    bool confirmedFailureOnly = false,
    VisiblePageRetry? automatic,
  }) async {
    final source = provider.provider!;
    final cachedUrl = urlCache[index];

    bool canRetry() =>
        onSession.value &&
        !isImageLoaded[index] &&
        (!confirmedFailureOnly || failedOnlineImages.isFailed(index));

    if (cachedUrl == null || !canRetry()) return;
    final oldUrl = cachedUrl.value;
    var nextUrl = oldUrl;
    Map<String, String>? nextHeader;
    try {
      nextHeader = await source.getHeader(index);
      final String url;
      if (source is HitomiImageProvider && automatic != null) {
        url = automatic.type == VisiblePageRetryType.imageWithRefreshedUrl
            ? await source.refreshImageUrlForAutomaticRetry(index, oldUrl)
            : oldUrl;
      } else {
        url = await source.getImageUrlForRetry(index);
      }
      if (url.trim().isEmpty) throw StateError('Empty URL at page $index');
      nextUrl = url;
    } catch (error, stackTrace) {
      // Keep the previous URL available when fresh metadata cannot be fetched.
      Logger.warning('[viewer-image-retry] Page $index: $error\n$stackTrace');
    }

    if (!canRetry()) return;
    try {
      await CachedNetworkImage.evictFromCache(oldUrl);
    } catch (error) {
      Logger.warning('[viewer-image-retry] Prefetch cache eviction: $error');
    }
    if (!canRetry()) return;
    if (imgKeys[index].currentState case final ExtendedImageState imageState) {
      // A same-URL reload must not rejoin a stalled ExtendedImage stream.
      await imageState.imageProvider.evict();
    }
    if (!canRetry()) return;

    if (nextHeader != null) headerCache[index] = nextHeader;
    imgKeys[index] = GlobalKey();
    failedOnlineImages.markLoading(index);
    visiblePageRecovery.imageLoading(index, DateTime.now());
    if (cachedUrl.value == nextUrl) {
      cachedUrl.refresh();
    } else {
      cachedUrl.value = nextUrl;
    }
  }

  refreshImgUrlWhenRequired() async {
    if (ProviderManager.dirty(articleId)) {
      await ProviderManager.refresh(
        articleId,
        isImageLoaded.map((element) => !element).toList(),
      );
      for (var i = 0; i < isImageLoaded.length; i++) {
        if (!isImageLoaded[i]) {
          if (urlCache[i] == null) {
            urlCache[i] = RxString(await provider.provider!.getImageUrl(i));
          } else {
            urlCache[i]!.value = await provider.provider!.getImageUrl(i);
          }
        }
      }
    }
  }
}
