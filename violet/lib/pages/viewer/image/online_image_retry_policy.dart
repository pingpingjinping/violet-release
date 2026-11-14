import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:extended_image/extended_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:violet/component/eh/eh_provider.dart';
import 'package:violet/component/hitomi/hitomi_provider.dart';
import 'package:violet/component/image_provider.dart';

/// Network image retries are separate from page URL/header retries.
///
/// Hitomi previously used 100 bounded retries. The recursive failed-state
/// reload was removed to prevent an unbounded loop and stays disabled.
/// E-Hentai and ExHentai share a smaller, gentler retry budget.
({int retries, Duration interval}) onlineImageRetryPolicy(
  VioletImageProvider? provider,
) {
  if (provider is HitomiImageProvider) {
    return (retries: 100, interval: const Duration(milliseconds: 300));
  }
  if (provider is EHentaiImageProvider) {
    return (retries: 6, interval: const Duration(milliseconds: 500));
  }
  return (retries: 2, interval: const Duration(milliseconds: 300));
}

ImageProvider<Object> onlineViewerImageProvider(
  VioletImageProvider? provider,
  String url, {
  Map<String, String>? headers,
  bool cache = true,
  int? retries,
  Duration? interval,
}) {
  final policy = onlineImageRetryPolicy(provider);
  final retryCount = retries ?? policy.retries;
  final retryInterval = interval ?? policy.interval;
  if (provider is HitomiImageProvider) {
    return _HitomiViewerImageProvider(
      url,
      headers: headers,
      cache: cache,
      retries: retryCount,
      interval: retryInterval,
    );
  }
  return ExtendedNetworkImageProvider(
    url,
    headers: headers,
    cache: cache,
    retries: retryCount,
    timeRetry: retryInterval,
  );
}

// ExtendedNetworkImageProvider discards HTTP errors before the widget can
// distinguish a 404 from other failures. Handle the status during the GET.
class _HitomiViewerImageProvider
    extends ImageProvider<_HitomiViewerImageProvider>
    with ExtendedImageProvider<_HitomiViewerImageProvider> {
  static const _notFoundRetries = 20;

  const _HitomiViewerImageProvider(
    this.url, {
    required this.headers,
    required this.cache,
    required this.retries,
    required this.interval,
  });

  final String url;
  final Map<String, String>? headers;
  final bool cache;
  final int retries;
  final Duration interval;

  @override
  bool get cacheRawData => false;

  @override
  String? get imageCacheName => null;

  @override
  Future<_HitomiViewerImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _HitomiViewerImageProvider key,
    ImageDecoderCallback decode,
  ) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: key._load(decode, chunks),
      scale: 1,
      debugLabel: url,
      chunkEvents: chunks.stream,
    );
  }

  Future<ui.Codec> _load(
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunks,
  ) async {
    try {
      File? cached;
      if (cache) {
        try {
          final temp = await getTemporaryDirectory();
          cached = File(
            path.join(temp.path, cacheImageFolderName, keyToMd5(url)),
          );
          if (await cached.exists()) {
            return await instantiateImageCodec(
              await cached.readAsBytes(),
              decode,
            );
          }
        } catch (_) {
          // Try the network when the disk cache is unavailable or unreadable.
        }
      }
      final response = await _getResponse(Uri.base.resolve(url));
      final bytes = await consolidateHttpClientResponseBytes(
        response,
        onBytesReceived: (received, total) {
          chunks.add(
            ImageChunkEvent(
              cumulativeBytesLoaded: received,
              expectedTotalBytes: total,
            ),
          );
        },
      );
      final codec = await instantiateImageCodec(bytes, decode);
      if (cached != null) {
        try {
          await cached.parent.create(recursive: true);
          await cached.writeAsBytes(bytes);
        } catch (_) {
          // Keep rendering if the disk cache cannot be written.
        }
      }
      return codec;
    } finally {
      unawaited(chunks.close());
    }
  }

  Future<HttpClientResponse> _getResponse(Uri uri) async {
    final client = ExtendedNetworkImageProvider.httpClient as HttpClient;
    var notFoundRetries = 0;
    final response = await RetryHelper.tryRun(
      () async {
        while (true) {
          final request = await client.getUrl(uri);
          headers?.forEach(request.headers.set);
          final response = await request.close();
          if (response.statusCode != HttpStatus.notFound ||
              notFoundRetries == _notFoundRetries) {
            return response;
          }
          notFoundRetries++;
          await response.drain<void>();
        }
      },
      retries: retries,
      timeRetry: interval,
    );
    if (response == null) throw StateError('Failed to load $url.');
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    return response;
  }

  @override
  bool operator ==(Object other) =>
      other is _HitomiViewerImageProvider &&
      url == other.url &&
      mapEquals(headers, other.headers) &&
      cache == other.cache &&
      retries == other.retries &&
      interval == other.interval;

  @override
  int get hashCode => Object.hash(url, cache, retries, interval);
}
