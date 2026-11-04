// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:violet/pages/viewer/image/file_image.dart' as file_image;
import 'package:violet/pages/viewer/image/online_image_placeholder.dart';
import 'package:violet/pages/viewer/image/online_page_load_error.dart';
import 'package:violet/pages/viewer/image/provider_image.dart';
import 'package:violet/pages/viewer/image/visible_online_page_recovery.dart';
import 'package:violet/pages/viewer/others/scrollable_positioned_list/src/item_positions_listener.dart';
import 'package:violet/pages/viewer/others/scrollable_positioned_list/src/scrollable_positioned_list.dart';
import 'package:violet/pages/viewer/vertical_scroll_anchor.dart';
import 'package:violet/pages/viewer/viewer_controller.dart';
import 'package:violet/pages/viewer/widget/custom_doubletap_gesture_detector.dart';
import 'package:violet/pages/viewer/widget/double_point_listener.dart';
import 'package:violet/settings/settings.dart';

typedef DoubleCallback = Future Function(double);
typedef BoolCallback = Function(bool);
typedef StringCallback = Future Function(String);

class VerticalViewerPage extends StatefulWidget {
  final String getxId;
  const VerticalViewerPage({super.key, required this.getxId});

  @override
  State<VerticalViewerPage> createState() => _VerticalViewerPageState();
}

class _VerticalViewerPageState extends State<VerticalViewerPage>
    with SingleTickerProviderStateMixin {
  late final ViewerController c;

  /// this is used for interactive viewer widget
  /// double-tap a specific location to zoom in on that location.
  final TransformationController _transformationController =
      TransformationController();
  late AnimationController _animationController;
  Animation<Matrix4>? _animation;

  /// lock scroll after zoom gesture
  /// this prevents paging on zoom gesture are performed
  bool _scrollListEnable = true;

  /// these are used on [_patchHeightForDynamicLoadedImage]
  int _latestIndex = 0;
  double _latestAlign = 0;
  bool _onScroll = false;
  int _scrollEpoch = 0;
  bool _anchorCorrectionQueued = false;
  final Set<int> _pagesChangedThisFrame = {};
  final Set<int> _pagesChangedDuringScroll = {};
  final Set<int> _measuredOnlineImages = {};
  Timer? _visibleRecoveryTimer;
  bool _checkingVisibleRecovery = false;
  // Delays are tied to a page, not to each rebuild of a scrolled list item.
  final Map<int, Future<int>> _providerDisplayDelays = {};
  // Freeze each unseen page's approximation on first encounter. Recomputing
  // it as neighboring images load would itself cause scroll relayout jitter.
  final Map<int, double> _onlinePlaceholderEstimates = {};

  double _provisionalHeight(int index) =>
      _onlinePlaceholderEstimates.putIfAbsent(
        index,
        () =>
            nearestKnownImageHeight(heights: c.imgHeight, index: index) ?? 300,
      );
  final Map<int, ValueNotifier<double?>> _heldOnlineImageHeights = {};
  final Map<int, (double, double)> _pendingOnlineEstimates = {};
  bool _releaseOnlineHeightsQueued = false;

  bool get _stabilizeOnlineLayout => _anchorMode || _deferDuringScroll;

  ValueNotifier<double?> _imageHold(int index) => _heldOnlineImageHeights
      .putIfAbsent(index, () => ValueNotifier<double?>(null));

  bool get _deferDuringScroll =>
      c.provider.useProvider &&
      Settings.deferOnlineVerticalScrollCorrection.value;

  bool get _anchorMode =>
      c.provider.useProvider && Settings.anchorOnlineVerticalScroll.value;

  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();

  @override
  void initState() {
    super.initState();

    c = Get.find(tag: widget.getxId);
    _animationController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 200),
        )..addListener(() {
          if (_animation != null) {
            _transformationController.value = _animation!.value;
          }
        });

    // The list also builds prefetched pages. Check actual viewport geometry,
    // never all missing URLs or every page in the cache extent.
    if (c.provider.useProvider) {
      _visibleRecoveryTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => _recoverVisibleOnlinePage(),
      );
    }

    _itemPositionsListener.itemPositions.addListener(() {
      if (!c.onSession.value) return;
      if (c.sliderOnChange) return;

      var v = _itemPositionsListener.itemPositions.value.toList();
      int? selected;

      v.sort((x, y) => x.itemLeadingEdge.compareTo(y.itemLeadingEdge));

      for (var e in v) {
        if (e.itemLeadingEdge <= 0.125) {
          selected = e.index;
        } else {
          break;
        }
      }

      _getLatestHeight();

      if (selected != null && c.page.value != selected) {
        c.page.value = selected;
      }
    });
  }

  @override
  void dispose() {
    _visibleRecoveryTimer?.cancel();
    for (final notifier in _heldOnlineImageHeights.values) {
      notifier.dispose();
    }
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height;
    final scrollablePositionedList = ScrollablePositionedList.builder(
      physics: _scrollListEnable
          ? const AlwaysScrollableScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: c.maxPage,
      itemScrollController: c.verticalItemScrollController,
      itemPositionsListener: _itemPositionsListener,
      minCacheExtent: c.provider.useFileSystem ? height : height * 1.5,
      itemBuilder: _itemBuild,
    );

    final notificationListener = NotificationListener(
      child: scrollablePositionedList,
      onNotification: (t) {
        if (t is ScrollStartNotification) {
          _onScroll = true;
          _scrollEpoch++;
          _pagesChangedDuringScroll.clear();
        } else if (t is ScrollEndNotification) {
          _onScroll = false;
          _scrollEpoch++;
          if (_stabilizeOnlineLayout ||
              _pendingOnlineEstimates.isNotEmpty ||
              _heldOnlineImageHeights.values.any((n) => n.value != null)) {
            _releaseOnlineHeightChanges();
          } else {
            _settleCurrentPageAfterScroll();
          }
        }
        return false;
      },
    );

    // Listen for page taps *around* the viewer. A full-screen overlay in
    // front of it prevents the failed image's refresh IconButton from being
    // hit-tested, so a visible purple retry button cannot be pressed.
    return CustomDoubleTapGestureDectector(
      onTap: _touchEvent,
      onDoubleTap: _doubleTapEvent,
      child: InteractiveViewer(
        transformationController: _transformationController,
        minScale: 1.0,
        child: AbsorbPointer(
          absorbing: !_scrollListEnable,
          child: ColoredBox(
            color: Settings.themeWhat.value && Settings.themeBlack.value
                ? Colors.black
                : const Color(0xff444444),
            child: notificationListener,
          ),
        ),
      ),
    );
  }

  /// Only pages that intersect the *actual* viewport may be recovered.
  ///
  /// Normal prefetch and actively progressing image transfers are excluded;
  /// the pure policy limits every page to two attempts in this viewer session.
  Future<void> _recoverVisibleOnlinePage() async {
    if (_checkingVisibleRecovery ||
        !mounted ||
        !c.onSession.value ||
        _onScroll ||
        c.sliderOnChange ||
        ModalRoute.of(context)?.isCurrent != true ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.inactive ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.detached) {
      return;
    }

    final visible = _itemPositionsListener.itemPositions.value
        .where(
          (position) =>
              position.index >= 0 &&
              position.index < c.maxPage &&
              position.itemTrailingEdge > 0 &&
              position.itemLeadingEdge < 1,
        )
        .map((position) => position.index)
        .toSet();
    final retry = c.visiblePageRecovery.candidate(visible, DateTime.now());
    if (retry == null) return;

    _checkingVisibleRecovery = true;
    try {
      if (retry.type == VisiblePageRetryType.metadata) {
        c.visiblePageRecovery.beginAutomaticRetry(retry, DateTime.now());
        c.retryPageLoad(retry.index);
        if (mounted) setState(() {});
      } else if (!c.isRefreshingImages && c.urlCache[retry.index] != null) {
        c.visiblePageRecovery.beginAutomaticRetry(retry, DateTime.now());
        await c.retryVisibleImage(retry.index);
      }
    } catch (error) {
      // A failed automatic attempt never starts an unbounded retry loop.
      // The existing purple button remains available for manual recovery.
      debugPrint('[viewer-visible-recovery] Retry failed: $error');
    } finally {
      _checkingVisibleRecovery = false;
    }
  }

  Widget _itemBuild(BuildContext context, int index) {
    Widget? image;

    if (c.provider.useFileSystem) {
      image = _storageImageItem(index);
    } else if (c.provider.useProvider) {
      image = _providerImageItem(index);
    }

    if (image == null) throw Exception('Dead Reaching');

    return DoublePointListener(
      child: Obx(
        () => Padding(
          padding: c.padding.value
              ? const EdgeInsets.fromLTRB(4, 0, 4, 4)
              : EdgeInsets.zero,
          child: Stack(
            children: [
              image!,
              if (_isExistsMessageSearchLayer(index))
                ..._messageSearchLayer(index),
            ],
          ),
        ),
      ),
      onStateChanged: (value) {
        setState(() {
          _scrollListEnable = value;
        });
      },
    );
  }

  void _touchEvent(TapDownDetails details) {
    final width = MediaQuery.of(context).size.width;
    if (details.localPosition.dx < width / 3) {
      if (!Settings.disableOverlayButton.value) c.leftButton();
    } else if (width / 3 * 2 < details.localPosition.dx) {
      if (!Settings.disableOverlayButton.value) c.rightButton();
    } else {
      c.middleButton();
    }
  }

  void _doubleTapEvent(TapDownDetails details) {
    Matrix4 endMatrix;
    Offset position = details.localPosition;

    if (_transformationController.value != Matrix4.identity()) {
      endMatrix = Matrix4.identity();
    } else {
      endMatrix = Matrix4.identity()
        ..translate(-position.dx * 1, -position.dy * 1)
        ..scale(2.0);
    }

    _animation = Matrix4Tween(
      begin: _transformationController.value,
      end: endMatrix,
    ).animate(CurveTween(curve: Curves.easeOut).animate(_animationController));
    _animationController.forward(from: 0);
  }

  /// This function is used for [_patchHeightForDynamicLoadedImage].
  /// The height of the widget with the initial image is set to 300,
  /// and when the image is loaded, the height is reset based on the
  /// aspect ratio of the image, which automatically adjusts the page
  /// currently being viewed by the user. This is a problem caused
  /// by the minCacheExtent of the listview, and we could not reduce
  /// the minCacheExtent to solve this problem.
  _getLatestHeight() {
    var v = _itemPositionsListener.itemPositions.value.toList();
    int? selected;
    ItemPosition? selectede;

    v.sort((x, y) => y.itemLeadingEdge.compareTo(x.itemLeadingEdge));

    for (var e in v) {
      if (e.itemLeadingEdge >= 0.0) {
        selected = e.index;
        selectede = e;
      } else {
        break;
      }
    }

    _latestIndex = selected ?? 0;
    _latestAlign = selectede?.itemLeadingEdge ?? 0;
  }

  _patchHeightForDynamicLoadedImage() {
    if (c.sliderOnChange ||
        !c.verticalItemScrollController.isAttached ||
        _onScroll) {
      return;
    }

    final current = _deferDuringScroll
        ? selectScrollEndPage(_itemPositionsListener.itemPositions.value)
        : null;
    if (_deferDuringScroll && current == null) return;
    c.verticalItemScrollController.scrollTo(
      index: current?.index ?? _latestIndex,
      duration: const Duration(microseconds: 1),
      alignment: current?.itemLeadingEdge ?? _latestAlign,
    );
  }

  /// The viewport stays at each image's loading height during a drag and
  /// ballistic motion. Apply all real image dimensions after ScrollEnd,
  /// anchoring only the page that the user was looking at when it stopped.
  void _releaseOnlineHeightChanges() {
    if (_releaseOnlineHeightsQueued) return;
    final hasHeld = _heldOnlineImageHeights.values.any((n) => n.value != null);
    if (!hasHeld && _pendingOnlineEstimates.isEmpty) {
      _pagesChangedDuringScroll.clear();
      return;
    }
    final changed = Set<int>.from(_pagesChangedDuringScroll);
    _pagesChangedDuringScroll.clear();

    final anchor = selectScrollEndPage(
      _itemPositionsListener.itemPositions.value,
    );
    final anchorIndex = anchor?.index;
    final anchorStart = anchor?.itemLeadingEdge;
    final epoch = _scrollEpoch;
    _releaseOnlineHeightsQueued = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _releaseOnlineHeightsQueued = false;
      if (!mounted || _onScroll || c.sliderOnChange || epoch != _scrollEpoch) {
        return;
      }
      final pending = Map<int, (double, double)>.from(_pendingOnlineEstimates);
      _pendingOnlineEstimates.clear();
      for (final entry in pending.entries) {
        c.realImgHeight[entry.key] = entry.value.$2;
        c.estimatedImgHeight[entry.key] = entry.value.$1;
      }
      for (final holder in _heldOnlineImageHeights.values) {
        if (holder.value != null) holder.value = null;
      }
      // The parent must rebuild to replace placeholder minHeight constraints
      // with the now-known image dimensions.
      setState(() {});

      if (c.sliderOnChange ||
          anchorIndex == null ||
          anchorStart == null ||
          changed.contains(anchorIndex) ||
          !changed.any((i) => i < anchorIndex)) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _onScroll || _scrollEpoch != epoch) return;
        final current = _itemPositionsListener.itemPositions.value;
        ItemPosition? same;
        for (final candidate in current) {
          if (candidate.index == anchorIndex) {
            same = candidate;
            break;
          }
        }
        if (same == null) return;
        final delta =
            (same.itemLeadingEdge - anchorStart) *
            MediaQuery.of(context).size.height;
        if (!delta.isFinite ||
            delta.abs() < 1 ||
            delta.abs() > MediaQuery.of(context).size.height * 2) {
          return;
        }
        c.verticalItemScrollController.compensatePixels(delta);
      });
    });
  }

  /// Receive intrinsic image dimensions before the completed network image
  /// first participates in layout; never derive them from a clipped box.
  void _onOnlineImageReady(int index, ImageInfo info, double width) {
    if (!_stabilizeOnlineLayout) return;
    final actual = realHeightFromImage(
      width: width,
      imageWidth: info.image.width,
      imageHeight: info.image.height,
    );
    if (actual == null) return;
    final old = c.imgHeight[index];
    if (old > 0 && (old - actual).abs() < 1) return;
    if (_onScroll) {
      final placeholder = old > 0
          ? old
          : c.estimatedImgHeight[index] > 0
          ? c.estimatedImgHeight[index]
          : _provisionalHeight(index);
      final holder = _imageHold(index);
      // The callback runs before the completed widget is built, so the
      // ValueListenableBuilder first mounts with this fixed placeholder.
      holder.value = placeholder;
      _pagesChangedDuringScroll.add(index);
    } else if (_anchorMode) {
      _queueOnlineAnchorCorrection(index);
    }
    c.imgHeight[index] = actual;
  }

  /// Scroll-time size changes are deliberately not corrected mid-gesture.
  /// At ScrollEnd, snapshot the page the user is viewing *at that moment*
  /// and compensate only a subsequent displacement of that same page.
  void _settleCurrentPageAfterScroll() {
    if (!_deferDuringScroll || _pagesChangedDuringScroll.isEmpty) {
      _pagesChangedDuringScroll.clear();
      return;
    }
    final changed = Set<int>.from(_pagesChangedDuringScroll);
    _pagesChangedDuringScroll.clear();
    if (c.sliderOnChange || !c.verticalItemScrollController.isAttached) {
      return;
    }

    final anchor = selectScrollEndPage(
      _itemPositionsListener.itemPositions.value,
    );
    if (anchor == null) return;
    final index = anchor.index;
    final start = anchor.itemLeadingEdge;
    final epoch = _scrollEpoch;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_deferDuringScroll ||
          _onScroll ||
          c.sliderOnChange ||
          _scrollEpoch != epoch ||
          changed.contains(index) ||
          !changed.any(
            (changedIndex) => heightChangeCanMoveAnchor(changedIndex, index),
          )) {
        // Current page changing height is allowed to resize naturally.
        return;
      }

      final latest = _itemPositionsListener.itemPositions.value;
      ItemPosition? samePage;
      for (final position in latest) {
        if (position.index == index) {
          samePage = position;
          break;
        }
      }
      if (samePage == null) return;
      final viewport = MediaQuery.of(context).size.height;
      final difference = (samePage.itemLeadingEdge - start) * viewport;
      if (!difference.isFinite ||
          difference.abs() < 0.5 ||
          difference.abs() > viewport) {
        return;
      }
      c.verticalItemScrollController.compensatePixels(difference);
    });
  }

  _storageImageItem(index) {
    Future<dynamic> future;

    if (c.imgHeight[index] == 0) {
      future = Future.delayed(const Duration(milliseconds: 300));
    } else {
      future = Future.value(0);
    }

    return FutureBuilder(
      // to avoid loading all images when fast scrolling
      future: future.then((value) async {
        return 0;
      }),
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return file_image.FileImage(
            getxId: widget.getxId,
            index: index,
            path: c.provider.uris[index],
            cachedHeight: c.imgHeight[index] != 0 ? c.imgHeight[index] : null,
            heightCallback: c.imgHeight[index] != 0
                ? null
                : (height) async {
                    c.imgHeight[index] = height;
                  },
          );
        }

        return SizedBox(
          height: c.imgHeight[index] != 0 ? c.imgHeight[index] : 300,
          child: const Center(
            child: SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(),
            ),
          ),
        );
      },
    );
  }

  _providerImageItem(int index) {
    final width = MediaQuery.of(context).size.width;

    if (c.loadingEstimaed[index] == false) {
      c.loadingEstimaed[index] = true;
      Future.delayed(const Duration(milliseconds: 1)).then((value) async {
        if (!c.onSession.value) return;
        final h = await c.provider.provider!.getEstimatedImageHeight(
          index,
          width,
        );
        final oh = await c.provider.provider!.getOriginalImageHeight(index);
        if (!mounted || !c.onSession.value) return;
        if (h > 0) {
          if (_stabilizeOnlineLayout && _onScroll) {
            _pendingOnlineEstimates[index] = (h, oh);
            _pagesChangedDuringScroll.add(index);
          } else {
            setState(() {
              c.realImgHeight[index] = oh;
              c.estimatedImgHeight[index] = h;
            });
          }
        }
      });
    }

    // Keep the delay stable across parent rebuilds. A new Future in every
    // build resets FutureBuilder to its spinner even for the same page.
    final Future<int> future = _providerDisplayDelays.putIfAbsent(
      index,
      () => Future<int>.delayed(const Duration(milliseconds: 300), () => 1),
    );

    return FutureBuilder(
      // to avoid loading all images when fast scrolling
      future: future,
      builder: (context, snapshot) {
        // To prevent the scroll from being chewed,
        // it is necessary to put an empty box for the invisible part.
        if (!snapshot.hasData && c.imgHeight[index] == 0) {
          return _loadingWidget(index);
        }

        return FutureBuilder(
          future: c.load(index),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.done &&
                snapshot.hasError &&
                (c.urlCache[index] == null || c.headerCache[index] == null)) {
              return OnlinePageLoadError(
                height: _visiblePlaceholderHeight(index),
                onRetry: () {
                  c.retryPageLoad(index);
                  if (mounted) setState(() {});
                },
              );
            }
            if (c.urlCache[index] == null || c.headerCache[index] == null) {
              return _loadingWidget(index);
            }

            final image = Obx(
              () => ProviderImage(
                getxId: widget.getxId,
                index: index,
                imgKey: c.imgKeys[index],
                imgUrl: c.urlCache[index]!.value,
                imgHeader: c.headerCache[index],
                imageWidgetBuilder: (context, child) {
                  return _imageWidgetBuilder(index, width, child);
                },
                onImageReady: _stabilizeOnlineLayout
                    ? (info) => _onOnlineImageReady(index, info, width)
                    : null,
                heldHeight: _stabilizeOnlineLayout ? _imageHold(index) : null,
                neighborHeight: _provisionalHeight(index),
              ),
            );

            return Container(
              constraints: _heldOnlineImageHeights[index]?.value != null
                  ? BoxConstraints(
                      minHeight: _heldOnlineImageHeights[index]!.value!,
                    )
                  : c.imgHeight[index] != 0
                  ? BoxConstraints(minHeight: c.imgHeight[index])
                  : c.estimatedImgHeight[index] != 0
                  ? BoxConstraints(minHeight: c.estimatedImgHeight[index])
                  : null,
              child: image,
            );
          },
        );
      },
    );
  }

  double _visiblePlaceholderHeight(int index) => onlineImagePlaceholderHeight(
    heldHeight: _heldOnlineImageHeights[index]?.value,
    cachedHeight: c.imgHeight[index],
    estimatedHeight: c.estimatedImgHeight[index],
    neighborHeight: _provisionalHeight(index),
  );

  _loadingWidget(int index) {
    return SizedBox(
      height: _visiblePlaceholderHeight(index),
      child: const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(),
        ),
      ),
    );
  }

  double? _loadedImageTop(int index) {
    if (index < 0 ||
        index >= c.maxPage ||
        !c.isImageLoaded[index] ||
        c.imgHeight[index] <= 0) {
      return null;
    }
    final render = c.imgKeys[index].currentContext?.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return null;
    }
    // The image must already have its real dimensions before it can anchor
    // another page. A still-resizing neighbor causes correction oscillation.
    if ((render.size.height - c.imgHeight[index]).abs() > 8) return null;
    return render.localToGlobal(Offset.zero).dy;
  }

  /// Save one stable, already loaded image before neighboring images finish
  /// layout. Restore only its measured screen displacement after the frame.
  /// The newly loaded image itself may shrink/grow naturally.
  void _queueOnlineAnchorCorrection(int changedIndex) {
    if (!_anchorMode ||
        _onScroll ||
        c.sliderOnChange ||
        !c.verticalItemScrollController.isAttached) {
      return;
    }
    if (_anchorCorrectionQueued) {
      _pagesChangedThisFrame.add(changedIndex);
      return;
    }

    final positions = _itemPositionsListener.itemPositions.value;
    final visibleAnchor = selectVisibleLoadedAnchor(
      positions,
      excludedIndex: changedIndex,
      isLoaded: (index) => _loadedImageTop(index) != null,
    );
    if (visibleAnchor == null) return;
    final anchorIndex = visibleAnchor.index;
    if (!heightChangeCanMoveAnchor(changedIndex, anchorIndex)) return;
    final previousTop = _loadedImageTop(anchorIndex);
    if (previousTop == null) return;

    final epoch = _scrollEpoch;
    _anchorCorrectionQueued = true;
    _pagesChangedThisFrame
      ..clear()
      ..add(changedIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorCorrectionQueued = false;
      final changed = Set<int>.from(_pagesChangedThisFrame);
      _pagesChangedThisFrame.clear();
      if (!mounted ||
          !_anchorMode ||
          _onScroll ||
          c.sliderOnChange ||
          _scrollEpoch != epoch ||
          changed.contains(anchorIndex)) {
        return;
      }

      final currentTop = _loadedImageTop(anchorIndex);
      if (currentTop == null) return;
      final difference = currentTop - previousTop;
      final viewportHeight = MediaQuery.of(context).size.height;
      // Ignore tiny layout settling and implausibly large shifts instead of
      // making a page jump that can restart several image widgets.
      if (!difference.isFinite ||
          difference.abs() < 12 ||
          difference.abs() > viewportHeight) {
        return;
      }
      c.verticalItemScrollController.compensatePixels(difference);
    });
  }

  _imageWidgetBuilder(int index, double width, Widget child) {
    // In stabilized mode the image's intrinsic dimensions are available in
    // onImageReady. Measuring a temporarily clipped RenderBox is incorrect.
    if (_stabilizeOnlineLayout) return child;
    final needsMeasurement = c.imgHeight[index] == 0;
    // A completed network image can rebuild or remount without another size
    // change. Never schedule a second anchor correction for that event.
    if (needsMeasurement && _measuredOnlineImages.add(index)) {
      if (_deferDuringScroll && _onScroll) {
        _pagesChangedDuringScroll.add(index);
      }
      if (_anchorMode) _queueOnlineAnchorCorrection(index);
      final epoch = _scrollEpoch;
      Future.delayed(const Duration(milliseconds: 50)).then((value) {
        if (!mounted) return;
        try {
          final render = c.imgKeys[index].currentContext?.findRenderObject();
          if (render is! RenderBox || !render.attached || !render.hasSize) {
            _measuredOnlineImages.remove(index);
            return;
          }

          final size = render.size;
          if (size.height <= 0 || size.width <= 0) {
            _measuredOnlineImages.remove(index);
            return;
          }
          final actualHeight = (width / size.aspectRatio - 1.5)
              .floor()
              .toDouble();
          if (actualHeight <= 0 || !actualHeight.isFinite) {
            _measuredOnlineImages.remove(index);
            return;
          }

          final oldHeight = c.imgHeight[index];
          if (oldHeight == 0) c.imgHeight[index] = actualHeight;
          final placeholder = c.estimatedImgHeight[index] > 0
              ? c.estimatedImgHeight[index]
              : 300.0;
          final didChange =
              oldHeight == 0 && (actualHeight - placeholder).abs() >= 1;
          if (!didChange || _anchorMode) return;

          if (_deferDuringScroll && (_onScroll || _scrollEpoch != epoch)) {
            // A drag or an inertial scroll happened after loading began.
            // Its page is no longer a valid target for a delayed scrollTo.
            return;
          }
          if (!_onScroll && _latestIndex >= index) {
            _patchHeightForDynamicLoadedImage();
          }
        } catch (_) {
          _measuredOnlineImages.remove(index);
        }
      });
    }
    return child;
  }

  _isExistsMessageSearchLayer(int index) {
    return c.search.value &&
        c.imgHeight[index] != 0 &&
        c.messages.where((element) => element.page == index).isNotEmpty;
  }

  _messageSearchLayer(int index) {
    final ratio = c.imgHeight[index] / c.realImgHeight[index];
    final messages = c.messages
        .where((element) => element.page == index)
        .toList();

    final boxes = messages.map((e) {
      var brtx = e.rect[0];
      var brty = e.rect[1];
      var brbx = e.rect[2];
      var brby = e.rect[3];

      return Positioned(
        top: brty * ratio - 4,
        left: brtx * ratio - 4,
        child: SizedBox(
          width: (brbx - brtx) * ratio + 8,
          height: (brby - brty) * ratio + 8,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(width: 3, color: Colors.red),
            ),
          ),
        ),
      );
    }).toList();

    return boxes;
  }
}
