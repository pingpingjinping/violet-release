import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/eh/eh_provider.dart';
import 'package:violet/component/hitomi/hitomi.dart';
import 'package:violet/component/hitomi/hitomi_provider.dart';
import 'package:violet/pages/viewer/image/online_image_retry_policy.dart';

void main() {
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
}
