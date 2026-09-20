import 'package:violet/services/download_archive.dart';
import 'package:violet/services/download_image_provider.dart';
// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flare_flutter/flare_actor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:violet/component/hitomi/hitomi.dart';
import 'package:violet/database/user/download.dart';
import 'package:violet/database/user/record.dart';
import 'package:violet/locale/locale.dart';
import 'package:violet/pages/common/toast.dart';
import 'package:violet/pages/common/utils.dart';
import 'package:violet/pages/download/download_item_menu.dart';
import 'package:violet/services/download_service.dart';
import 'package:violet/pages/viewer/viewer_page.dart';
import 'package:violet/pages/viewer/viewer_page_provider.dart';
import 'package:violet/script/script_manager.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/style/palette.dart';
import 'package:violet/widgets/article_item/thumbnail.dart';
import 'package:violet/widgets/active_tab_scope.dart';

class DownloadListItem {
  bool addBottomPadding;
  bool showDetail;
  double width;

  DownloadListItem({
    required this.addBottomPadding,
    required this.showDetail,
    required this.width,
  });
}

typedef DownloadListItemCallback = void Function(DownloadListItem);
typedef DownloadListItemCallbackCallback =
    void Function(DownloadListItemCallback);

class DownloadItemWidget extends StatefulWidget {
  // final double width;
  final DownloadItemModel item;
  final DownloadListItem initialStyle;
  final bool download;
  final VoidCallback refeshCallback;
  final bool isCheckMode;
  final bool isChecked;
  final ValueChanged<bool>? checkCallback;
  final VoidCallback? longPressCallback;

  const DownloadItemWidget({
    super.key,
    // this.width,
    required this.item,
    required this.initialStyle,
    required this.download,
    required this.refeshCallback,
    this.isCheckMode = false,
    this.isChecked = false,
    this.checkCallback,
    this.longPressCallback,
  });

  @override
  State<DownloadItemWidget> createState() => DownloadItemWidgetState();
}

class DownloadItemWidgetState extends State<DownloadItemWidget>
    with AutomaticKeepAliveClientMixin {
  static final DateFormat _downloadTimeFormat = DateFormat(
    'yyyy-MM-dd HH:mm:ss',
  );

  @override
  bool get wantKeepAlive => false;
  double scale = 1.0;
  String fav = '';
  int cur = 0;
  int max = 0;

  double download = 0;
  int downloadTotalFileCount = 0;
  int downloadedFileCount = 0;
  String downloadSpeed = ' KB/S';
  late double thisWidth, thisHeight;
  late DownloadListItem style;
  bool isLastestRead = false;
  int latestReadPage = 0;
  bool disposed = false;

  @override
  void initState() {
    super.initState();
    _styleCallback(widget.initialStyle);

    _checkLastRead();
    _downloadProcedure();
  }

  Future<void> _checkLastRead() async {
    final user = await User.getInstance();
    final log = await user.recentRead(widget.item.url());
    if (disposed || log == null || (log.lastPage() ?? 0) <= 1) return;
    _shouldReload = true;
    setState(() {
      isLastestRead = true;
      latestReadPage = log.lastPage()!;
    });
  }

  void _styleCallback(DownloadListItem item) {
    style = item;

    thisWidth = item.showDetail
        ? item.width - 16
        : item.width - (item.addBottomPadding ? 100 : 0);
    thisHeight = item.showDetail
        ? 130.0
        : item.addBottomPadding
        ? 500.0
        : item.width * 4 / 3;

    setState(() {});
  }

  GalleryDownloadProgress? _progress;
  String? _thumbnailSignature;

  void _downloadProcedure() {
    _progress?.removeListener(_updateProgress);
    _progress = DownloadService.instance.progress(widget.item.id());
    _progress?.addListener(_updateProgress);
    _updateProgress();
  }

  void _updateProgress() {
    if (!mounted || _progress == null) return;
    final progress = _progress!;
    setState(() {
      widget.item.result = progress.item.result;
      cur = progress.extracted;
      max = progress.total;
      download = progress.bytes;
      downloadTotalFileCount = progress.total;
      downloadedFileCount = progress.completed;
      final speed = progress.bytesPerSecond;
      downloadSpeed = speed < 512000
          ? '${(speed / 1024).toStringAsFixed(1)} KB/S'
          : '${(speed / 1024 / 1024).toStringAsFixed(1)} MB/S';
      final signature =
          '${widget.item.thumbnail()}:${widget.item.state() == 0}';
      if (signature != _thumbnailSignature) _shouldReload = true;
      _thumbnailSignature = signature;
    });
  }

  @override
  void didUpdateWidget(covariant DownloadItemWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_progress != DownloadService.instance.progress(widget.item.id())) {
      _downloadProcedure();
    }
  }

  @override
  void dispose() {
    disposed = true;
    _progress?.removeListener(_updateProgress);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final itemScale = widget.isCheckMode && widget.isChecked ? 0.95 : scale;

    return GestureDetector(
      child: SizedBox(
        width: thisWidth,
        height: thisHeight,
        child: AnimatedContainer(
          // alignment: FractionalOffset.center,
          curve: Curves.easeInOut,
          duration: const Duration(milliseconds: 300),
          // padding: EdgeInsets.all(pad),
          transform: Matrix4.identity()
            ..translate(thisWidth / 2, thisHeight / 2)
            ..scale(itemScale)
            ..translate(-thisWidth / 2, -thisHeight / 2),
          child: Stack(
            children: [
              buildBody(),
              if (widget.isCheckMode)
                Positioned(
                  top: 8,
                  left: 8,
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: widget.isChecked
                        ? Settings.majorColor.value
                        : Colors.black45,
                    child: Icon(
                      widget.isChecked ? Icons.check : Icons.circle_outlined,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      onLongPress: () async {
        setState(() {
          scale = 1.0;
        });

        if (widget.isCheckMode) {
          widget.checkCallback?.call(!widget.isChecked);
          return;
        }

        if (widget.longPressCallback != null) {
          widget.longPressCallback!();
          return;
        }

        var v = await showDialog(
          context: context,
          builder: (BuildContext context) => const DownloadImageMenu(),
        );

        if (v == -1) {
          await delete();
          widget.refeshCallback();
        } else if (v == 2) {
          // Copy Url
          Clipboard.setData(ClipboardData(text: widget.item.url()));
          showToast(level: ToastLevel.check, message: 'URL Copied!');
        } else if (v == 1) {
          _retry();
        } else if (v == 3) {
          _recovery();
        }
      },
      onTap: () async {
        if (widget.isCheckMode) {
          widget.checkCallback?.call(!widget.isChecked);
          return;
        }

        if (widget.item.state() == 0 && widget.item.files() != null) {
          final files = widget.item.filesWithoutThumbnail();
          if (files.isEmpty ||
              files.any((file) => !DownloadArchive.exists(file))) {
            showToast(
              level: ToastLevel.error,
              message: 'Downloaded files not found. Please recover it.',
            );
            return;
          }

          await (await User.getInstance()).insertUserLog(
            int.tryParse(widget.item.url()) ?? -1,
            0,
          );

          if (!context.mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              fullscreenDialog: true,
              builder: (context) {
                return Provider<ViewerPageProvider>.value(
                  value: ViewerPageProvider(
                    uris: files,
                    useFileSystem: true,
                    id: int.tryParse(widget.item.url()) ?? -1,
                    title: widget.item.info()!,
                  ),
                  child: const ViewerPage(),
                );
              },
            ),
          );
        }
      },
      onTapDown: (details) {
        setState(() {
          scale = 0.95;
        });
      },
      onTapUp: (details) {
        setState(() {
          scale = 1.0;
        });
      },
      onTapCancel: () {
        setState(() {
          scale = 1.0;
        });
      },
      onDoubleTap: () {
        setState(() {
          scale = 1.0;
        });
        if (int.tryParse(widget.item.url()) != null) {
          showArticleInfoById(context, int.parse(widget.item.url()));
        }
      },
    );
  }

  void _retry() {
    DownloadService.instance.retry(widget.item);
    _downloadProcedure();
  }

  Future<void> delete() => DownloadService.instance.delete(widget.item);

  void retry() => _retry();

  void _recovery() {
    DownloadService.instance.retry(widget.item, recover: true);
    _downloadProcedure();
  }

  void retryWhenRequired() {
    if (widget.item.state() >= 6) _retry();
  }

  void recovery() {
    if (widget.item.thumbnail() != null &&
        (widget.item.thumbnail()!.contains('e-hentai') ||
            widget.item.thumbnail()!.contains('exhentai'))) {
      return;
    }
    _recovery();
  }

  Widget buildBody() {
    return Container(
      // margin: const EdgeInsets.only(bottom: 6),
      margin: style.addBottomPadding
          ? style.showDetail
                ? const EdgeInsets.only(bottom: 6)
                : const EdgeInsets.only(bottom: 50)
          : EdgeInsets.zero,
      decoration: !Settings.themeFlat.value
          ? BoxDecoration(
              color: style.showDetail
                  ? Settings.themeWhat.value
                        ? Settings.themeBlack.value
                              ? Palette.blackThemeBackground
                              : Colors.grey.shade800
                        : Colors.white70
                  : Colors.grey.withOpacity(0.3),
              borderRadius: const BorderRadius.all(Radius.circular(5)),
              boxShadow: [
                BoxShadow(
                  color: Settings.themeWhat.value
                      ? Colors.grey.withOpacity(0.08)
                      : Colors.grey.withOpacity(0.4),
                  spreadRadius: 5,
                  blurRadius: 7,
                  offset: const Offset(0, 3), // changes position of shadow
                ),
              ],
            )
          : null,
      color: !Settings.themeFlat.value || !style.showDetail
          ? null
          : Settings.themeWhat.value
          ? Colors.black26
          : Colors.white,
      child: style.showDetail
          ? Row(
              children: <Widget>[
                buildThumbnail(),
                Expanded(child: buildDetail()),
              ],
            )
          : buildThumbnail(),
    );
  }

  Widget? _cachedThumbnail;
  bool _shouldReload = false;

  void thubmanilReload() {
    _shouldReload = true;
  }

  Widget buildThumbnail() {
    final height = MediaQuery.of(context).size.width / 3 * 4 / 3;
    final length = widget.item.filesWithoutThumbnail().length;

    if (_cachedThumbnail == null || _shouldReload) {
      _shouldReload = false;
      _cachedThumbnail =
          widget.item.state() == 0 &&
              widget.item.rawFiles().isNotEmpty &&
              DownloadArchive.exists(widget.item.rawFiles().first)
          ? _FileThumbnailWidget(
              showDetail: style.showDetail,
              thumbnailPath: widget.item.rawFiles().first,
              thumbnailTag:
                  (widget.item.thumbnail() ?? '') +
                  widget.item.dateTime().toString(),
              usingRawImage: true,
              height: height,
            )
          : _ThumbnailWidget(
              showDetail: style.showDetail,
              id: int.tryParse(widget.item.url()) ?? -1,
              thumbnail: widget.item.thumbnail(),
              thumbnailTag:
                  (widget.item.thumbnail() ?? '') +
                  widget.item.dateTime().toString(),
              thumbnailHeader: widget.item.thumbnailHeader(),
            );
    }

    return Visibility(
      visible: widget.item.thumbnail() != null,
      child: Container(
        foregroundDecoration:
            isLastestRead &&
                length > 0 &&
                length - latestReadPage <= 2 &&
                Settings.showArticleProgress.value
            ? BoxDecoration(
                color: Settings.themeWhat.value
                    ? Colors.grey.shade800
                    : Colors.grey.shade300,
                backgroundBlendMode: BlendMode.saturation,
              )
            : null,
        child: Stack(
          children: [
            _cachedThumbnail!,
            ReadProgressOverlayWidget(
              imageCount: widget.item.filesWithoutThumbnail().length,
              latestReadPage: latestReadPage,
              isLastestRead: isLastestRead,
              greyScale: false,
            ),
            PagesOverlayWidget(
              imageCount: widget.item.filesWithoutThumbnail().length,
              showDetail: style.showDetail,
            ),
          ],
        ),
      ),
    );
  }

  String _formattedDownloadTime() {
    final raw = widget.item.dateTime();
    if (raw == null || raw.isEmpty) return '';
    final parsed = DateTime.tryParse(raw);
    return parsed == null
        ? raw.split('.').first
        : _downloadTimeFormat.format(parsed);
  }

  Widget buildDetail() {
    var title = widget.item.url();

    if (widget.item.info() != null) {
      title = widget.item.info()!;
    }

    var state = 'None';
    var pp =
        '${Translations.instance!.trans('date')}: ${_formattedDownloadTime()}';

    var statecolor = !Settings.themeWhat.value ? Colors.black : Colors.white;
    var statebold = FontWeight.normal;

    switch (widget.item.state()) {
      case 0:
        state = Translations.instance!.trans('complete');
        break;
      case 1:
        state = Translations.instance!.trans('waitqueue');
        pp =
            '${Translations.instance!.trans('progress')}: ${Translations.instance!.trans('waitdownload')}';
        break;
      case 2:
        if (max == 0) {
          state = Translations.instance!.trans('extracting');
          pp =
              '${Translations.instance!.trans('progress')}: ${Translations.instance!.trans('count').replaceAll('%s', cur.toString())}';
        } else {
          state = '${Translations.instance!.trans('extracting')}[$cur/$max]';
          pp = '${Translations.instance!.trans('progress')}: ';
        }
        break;

      case 3:
        // state =
        //     '[$downloadedFileCount/$downloadTotalFileCount] ($downloadSpeed ${(download / 1024.0 / 1024.0).toStringAsFixed(1)} MB)';
        state =
            '[$downloadedFileCount/$downloadTotalFileCount] · $downloadSpeed';
        pp = '${Translations.instance!.trans('progress')}: ';
        break;

      case 5:
        state = Translations.instance!.trans('unknownerr');
        pp = widget.item.errorMsg() ?? '';
        statecolor = Colors.red;
        break;
      case 6:
        state = Translations.instance!.trans('stop');
        pp = '';
        statecolor = Colors.orange;
        // statebold = FontWeight.bold;
        break;
      case 7:
        state = Translations.instance!.trans('unknownerr');
        pp = '';
        statecolor = Colors.red;
        // statebold = FontWeight.bold;
        break;
      case 8:
        state = Translations.instance!.trans('urlnotsupport');
        pp = '';
        statecolor = Colors.redAccent;
        // statebold = FontWeight.bold;
        break;
      case 9:
        state = Translations.instance!.trans('tryagainlogin');
        pp = '';
        statecolor = Colors.redAccent;
        // statebold = FontWeight.bold;
        break;
      case 11:
        state = Translations.instance!.trans('nothingtodownload');
        pp = '';
        statecolor = Colors.orangeAccent;
        // statebold = FontWeight.bold;
        break;
    }

    return AnimatedContainer(
      margin: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      duration: const Duration(milliseconds: 300),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '${Translations.instance!.trans('dinfo')}: $title',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
          ),
          Container(height: 2),
          Text(
            '${Translations.instance!.trans('state')}: $state',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              color: statecolor,
              fontWeight: statebold,
            ),
          ),
          Container(height: 2),
          widget.item.state() != 3
              ? Text(
                  pp,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      pp,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: LinearProgressIndicator(
                          value: downloadedFileCount / downloadTotalFileCount,
                          minHeight: 18,
                        ),
                      ),
                    ),
                  ],
                ),
          Expanded(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
                        child: Container(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThumbnailWidget extends StatefulWidget {
  final String? thumbnail;
  final String? thumbnailHeader;
  final String? thumbnailTag;
  final bool showDetail;
  final int? id;

  const _ThumbnailWidget({
    required this.thumbnail,
    required this.thumbnailHeader,
    required this.thumbnailTag,
    required this.showDetail,
    required this.id,
  });

  @override
  State<_ThumbnailWidget> createState() => _ThumbnailWidgetState();
}

class _ThumbnailWidgetState extends State<_ThumbnailWidget> {
  Future<(String, Map<String, String>)>? _source;

  @override
  void didUpdateWidget(covariant _ThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id ||
        oldWidget.thumbnail != widget.thumbnail ||
        oldWidget.thumbnailHeader != widget.thumbnailHeader) {
      _source = null;
    }
  }

  Future<(String, Map<String, String>)> _loadSource() async {
    final value = await HitomiManager.getImageList(widget.id.toString());
    final header = await ScriptManager.runHitomiGetHeaderContent(
      widget.id.toString(),
    );
    return (value.urls[0], header);
  }

  @override
  Widget build(BuildContext context) {
    // Keep the 2.5-screen preload range on this tab without decoding
    // thumbnails while another root tab is active.
    if (!ActiveTabScope.isActive(context)) {
      return const ColoredBox(color: Colors.transparent);
    }

    return SizedBox(
      width: widget.showDetail ? 100 : double.infinity,
      child: widget.thumbnail != null
          ? ClipRRect(
              borderRadius: widget.showDetail
                  ? const BorderRadius.horizontal(left: Radius.circular(5.0))
                  : const BorderRadius.all(Radius.circular(5.0)),
              child: _thumbnailImage(),
            )
          : _getLoadingAnimation(),
    );
  }

  Widget _networkImage(String url, Map<String, String> headers) {
    return Hero(
      tag: widget.thumbnailTag!,
      child: CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        memCacheWidth: widget.showDetail
            ? 300
            : (Settings.useLowPerf.value ? 300 : 600),
        httpHeaders: headers,
        imageBuilder: (context, imageProvider) => Container(
          decoration: BoxDecoration(
            image: DecorationImage(image: imageProvider, fit: BoxFit.cover),
          ),
        ),
        placeholder: (_, __) => _getLoadingAnimation(),
      ),
    );
  }

  Widget _thumbnailImage() {
    if (widget.id == null) {
      final headers = <String, String>{};
      if (widget.thumbnailHeader != null) {
        final decoded =
            jsonDecode(widget.thumbnailHeader!) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          headers[entry.key] = entry.value as String;
        }
      }
      return _networkImage(widget.thumbnail!, headers);
    }

    return FutureBuilder<(String, Map<String, String>)>(
      future: _source ??= _loadSource(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return _getLoadingAnimation();
        return _networkImage(snapshot.data!.$1, snapshot.data!.$2);
      },
    );
  }

  Widget _getLoadingAnimation() {
    if (!Settings.simpleItemWidgetLoadingIcon.value) {
      return const FlareActor(
        'assets/flare/Loading2.flr',
        alignment: Alignment.center,
        fit: BoxFit.fitHeight,
        animation: 'Alarm',
      );
    }
    return Center(
      child: SizedBox(
        width: 30,
        height: 30,
        child: CircularProgressIndicator(
          color: Settings.majorColor.value.withAlpha(150),
        ),
      ),
    );
  }
}

class _FileThumbnailWidget extends StatelessWidget {
  final String thumbnailPath;
  final String thumbnailTag;
  final bool showDetail;
  final bool usingRawImage;
  final double height;

  const _FileThumbnailWidget({
    required this.thumbnailPath,
    required this.thumbnailTag,
    required this.showDetail,
    this.usingRawImage = false,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    if (!ActiveTabScope.isActive(context)) {
      return const ColoredBox(color: Colors.transparent);
    }

    return SizedBox(
      width: showDetail ? 100 : double.infinity,
      child: ClipRRect(
        borderRadius: showDetail
            ? const BorderRadius.horizontal(left: Radius.circular(5.0))
            : const BorderRadius.all(Radius.circular(5.0)),
        child: _thumbnailImage(),
      ),
    );
  }

  Widget _thumbnailImage() {
    return Hero(
      tag: thumbnailTag,
      child: ExtendedImage(
        image: ExtendedResizeImage.resizeIfNeeded(
          provider: DownloadImageProvider(thumbnailPath),
          cacheWidth: usingRawImage ? height.toInt() * 2 : null,
        ),
        fit: BoxFit.cover,
        loadStateChanged: (state) {
          if (state.extendedImageLoadState == LoadState.loading ||
              state.extendedImageLoadState == LoadState.failed) {
            return _getLoadingAnimation();
          }

          return Container(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: state.imageProvider,
                fit: BoxFit.cover,
              ),
            ),
            child: Container(),
          );
        },
      ),
    );
  }

  Widget _getLoadingAnimation() {
    if (!Settings.simpleItemWidgetLoadingIcon.value) {
      return const FlareActor(
        'assets/flare/Loading2.flr',
        alignment: Alignment.center,
        fit: BoxFit.fitHeight,
        animation: 'Alarm',
      );
    } else {
      return Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            color: Settings.majorColor.value.withAlpha(150),
          ),
        ),
      );
    }
  }
}
