import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/eh/eh_provider.dart';
import 'package:violet/component/hitomi/hitomi.dart';
import 'package:violet/component/hitomi/hitomi_provider.dart';
import 'package:violet/pages/viewer/image/online_image_retry_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Hitomi retains the previous bounded image retry count', () {
    final provider = HitomiImageProvider(
      const ImageList(urls: [], bigThumbnails: []),
      '1',
    );
    final policy = onlineImageRetryPolicy(provider);
    expect(policy.retries, 100);
    expect(policy.interval, const Duration(milliseconds: 300));
  });

  for (final isEHentai in [true, false]) {
    test('${isEHentai ? 'E-Hentai' : 'ExHentai'} retries are modest', () {
      final provider = EHentaiImageProvider(
        count: 1,
        thumbnail: '',
        pagesUrl: [],
        isEHentai: isEHentai,
        imagesPerPage: 40,
      );
      final policy = onlineImageRetryPolicy(provider);
      expect(policy.retries, 6);
      expect(policy.interval, const Duration(milliseconds: 500));
    });
  }

  test('unrecognized providers retain the conservative fallback', () {
    final policy = onlineImageRetryPolicy(null);
    expect(policy.retries, 2);
    expect(policy.interval, const Duration(milliseconds: 300));
  });

  group('Hitomi viewer requests', () {
    final hitomi = HitomiImageProvider(
      const ImageList(urls: [], bigThumbnails: []),
      '1',
    );
    final uri = Uri.parse('https://example.test/image.png');

    Future<void> loadImage(List<int> statuses, List<Uri> requests) async {
      debugNetworkImageHttpClientProvider = () =>
          _ImageClient(statuses, requests);
      final provider = onlineViewerImageProvider(
        hitomi,
        uri.toString(),
        cache: false,
      );
      final completer = Completer<void>();
      final stream = provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((image, _) {
        image.dispose();
        if (!completer.isCompleted) completer.complete();
      }, onError: completer.completeError);
      stream.addListener(listener);
      try {
        await completer.future;
      } finally {
        stream.removeListener(listener);
        await provider.evict();
        debugNetworkImageHttpClientProvider = null;
      }
    }

    test('retries the same URL after a 404 until the image loads', () async {
      final requests = <Uri>[];
      await loadImage([404, 404, 200], requests);
      expect(requests, List.filled(3, uri));
    });

    test('gives up after 20 retries of a persistent 404', () async {
      final requests = <Uri>[];
      await expectLater(
        loadImage([404], requests),
        throwsA(
          isA<NetworkImageLoadException>().having(
            (error) => error.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
      expect(requests, List.filled(21, uri));
    });

    test('stops on an HTTP failure other than 404', () async {
      final requests = <Uri>[];
      await expectLater(
        loadImage([404, 403], requests),
        throwsA(
          isA<NetworkImageLoadException>().having(
            (error) => error.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      expect(requests, List.filled(2, uri));
    });
  });
}

class _ImageClient extends Fake implements HttpClient {
  _ImageClient(this.statuses, this.requests);

  final List<int> statuses;
  final List<Uri> requests;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final status = requests.length < statuses.length
        ? statuses[requests.length]
        : statuses.last;
    requests.add(url);
    return _ImageRequest(status);
  }
}

class _ImageRequest extends Fake implements HttpClientRequest {
  _ImageRequest(this.status);

  final int status;

  @override
  Future<HttpClientResponse> close() async => _ImageResponse(status);
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  _ImageResponse(this.statusCode);

  static final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
  );

  @override
  final int statusCode;

  @override
  int get contentLength => statusCode == 200 ? _png.length : 0;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable(statusCode == 200 ? [_png] : []).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
