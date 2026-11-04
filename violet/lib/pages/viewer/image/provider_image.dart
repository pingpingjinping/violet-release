// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:violet/log/log.dart';
import 'package:violet/pages/segment/platform_navigator.dart';
import 'package:violet/pages/viewer/image/online_image_placeholder.dart';
import 'package:violet/pages/viewer/viewer_controller.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/settings/settings_wrapper.dart';
import 'package:violet/pages/viewer/image/image_crop_bookmark.dart';

typedef VImageWidgetBuilder =
    Widget Function(BuildContext context, Widget child);

typedef VProgressIndicatorBuilder =
    Widget Function(
      BuildContext context,
      String url,
      DownloadProgress progress,
    );

typedef VLoadingErrorWidgetBuilder =
    Widget Function(BuildContext context, String url, dynamic error);

class ProviderImage extends StatefulWidget {
  final String getxId;
  final GlobalKey imgKey;
  final String imgUrl;
  final Map<String, String>? imgHeader;
  final VImageWidgetBuilder imageWidgetBuilder;
  final int index;
  final ValueChanged<ImageInfo>? onImageReady;
  final ValueListenable<double?>? heldHeight;
  final double? neighborHeight;

  const ProviderImage({
    super.key,
    required this.getxId,
    required this.imgKey,
    required this.imgUrl,
    required this.imgHeader,
    required this.imageWidgetBuilder,
    required this.index,
    this.onImageReady,
    this.heldHeight,
    this.neighborHeight,
  });

  @override
  State<ProviderImage> createState() => _ProviderImageState();
}

class _ProviderImageState extends State<ProviderImage> {
  late final ViewerController c;
  bool _loaded = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    c = Get.find(tag: widget.getxId);
  }

  @override
  Widget build(BuildContext context) {
    final image = ExtendedImage.network(
      widget.imgUrl,
      key: widget.imgKey,
      headers: widget.imgHeader,
      retries: 2,
      timeRetry: const Duration(milliseconds: 300),
      fit: BoxFit.cover,
      filterQuality: SettingsWrapper.imageQuality,
      // Let Flutter's bounded LRU image cache retain recently viewed pages.
      // Evicting on every sliver unmount forces full-image reloads on return.
      clearMemoryCacheWhenDispose: false,
      clearMemoryCacheIfFailed: true,
      handleLoadingProgress: true,
      loadStateChanged: _loadStateChanged,
      cacheHeight: Settings.useLowPerf.value
          ? (MediaQuery.of(context).size.width * 2.0).toInt()
          : null,
    );

    return GestureDetector(
      child: image,
      onLongPress: () {
        PlatformNavigator.navigateSlide(
          context,
          ImageCropBookmark(
            url: widget.imgUrl,
            headers: widget.imgHeader,
            articleId: c.articleId,
            page: widget.index,
            isNetworkImage: true,
          ),
        );
      },
    );
  }

  double get _placeholderHeight => onlineImagePlaceholderHeight(
    heldHeight: widget.heldHeight?.value,
    cachedHeight: c.imgHeight[widget.index],
    estimatedHeight: c.estimatedImgHeight[widget.index],
    neighborHeight: widget.neighborHeight,
  );

  Widget _loadStateChanged(ExtendedImageState state) {
    if (state.extendedImageLoadState == LoadState.failed) {
      Logger.error(
        '[viewer-provider_image] URL: ${widget.imgUrl}\nE: ${state.lastException}',
      );
      _loaded = false;
      c.isImageLoaded[widget.index] = false;

      final retryWidget = _refreshing
          ? const SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(),
            )
          : IconButton(
              icon: Icon(Icons.refresh, color: Settings.majorColor.value),
              onPressed: () async {
                if (_refreshing) return;

                setState(() {
                  _refreshing = true;
                });

                try {
                  await c.refreshFailedImages(onlyIndex: widget.index);
                } finally {
                  if (mounted) {
                    setState(() {
                      _refreshing = false;
                    });
                  }
                }
              },
            );

      return SizedBox(
        height: _placeholderHeight,
        child: Center(
          child: SizedBox(width: 50, height: 50, child: retryWidget),
        ),
      );
    }

    final ImageInfo? imageInfo = state.extendedImageInfo;
    if ((state.extendedImageLoadState == LoadState.completed ||
            imageInfo != null) &&
        !_loaded) {
      _loaded = true;
      c.isImageLoaded[widget.index] = true;
      if (imageInfo != null) widget.onImageReady?.call(imageInfo);
      return _wrapCompleted(
        widget.imageWidgetBuilder(context, state.completedWidget),
      );
    } else if (state.extendedImageLoadState == LoadState.loading) {
      return SizedBox(
        height: _placeholderHeight,
        child: Center(
          child: SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(
              value: state.loadingProgress == null
                  ? null
                  : state.loadingProgress!.cumulativeBytesLoaded /
                        state.loadingProgress!.expectedTotalBytes!,
            ),
          ),
        ),
      );
    }

    c.isImageLoaded[widget.index] = true;

    // ExtendedImage may rebuild after the first completion. Keep the fixed
    // height wrapper until scrolling fully ends, including on later frames.
    return _wrapCompleted(state.completedWidget);
  }

  Widget _wrapCompleted(Widget child) {
    final heldHeight = widget.heldHeight;
    if (heldHeight == null) return child;
    return ValueListenableBuilder<double?>(
      valueListenable: heldHeight,
      builder: (context, height, image) {
        if (height == null) return image!;
        return SizedBox(height: height, child: image);
      },
      child: child,
    );
  }
}
