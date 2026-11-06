import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:violet/component/eh/eh_provider.dart';
import 'package:violet/component/ordered_extraction.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/thread/semaphore.dart';

void main() {
  test('bounded extraction delivers in order', () async {
    final requests = List.generate(4, (_) => Completer<int>());
    final started = <int>[];
    final delivered = <int>[];

    final finished = processOrderedBatches<int>(
      total: 4,
      concurrency: () => 2,
      fetch: (index) {
        started.add(index);
        return requests[index].future;
      },
      deliver: (value) async => delivered.add(value),
    );
    expect(started, [0, 1]);

    requests[1].complete(1);
    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);

    requests[0].complete(0);
    await Future<void>.delayed(Duration.zero);
    expect(delivered, [0, 1]);
    expect(started, [0, 1, 2, 3]);

    requests[3].complete(3);
    requests[2].complete(2);
    await finished;
    expect(delivered, [0, 1, 2, 3]);
  });

  test('semaphore resizing preserves limits', () async {
    final semaphore = Semaphore(maxCount: 1);
    final first = await semaphore.acquire();
    final secondFuture = semaphore.acquire();

    semaphore.setMaxCount(2);
    final second = await secondFuture;

    semaphore.setMaxCount(1);
    var thirdStarted = false;
    final thirdFuture = semaphore.acquire().then((permit) {
      thirdStarted = true;
      return permit;
    });

    first();
    await Future<void>.delayed(Duration.zero);
    expect(thirdStarted, isFalse);

    second();
    final third = await thirdFuture;
    expect(thirdStarted, isTrue);
    third();
  });

  test('EH/EX retries refresh only the target image page', () async {
    await Settings.downloadEhRawImage.setValue(false);
    for (final host in ['e-hentai.org', 'exhentai.org']) {
      final calls = <(String, bool)>[];
      final firstPage = 'https://$host/s/abc/123-1';
      final secondPage = 'https://$host/s/def/123-2';
      var failRefresh = false;
      final provider = EHentaiImageProvider(
        count: 2,
        thumbnail: '',
        pagesUrl: ['https://$host/g/123/token/?p=0'],
        isEHentai: host == 'e-hentai.org',
        imagesPerPage: 2,
        requestImagePage: (url, {required bypassCache}) async {
          calls.add((url, bypassCache));
          if (failRefresh && bypassCache) throw StateError('lookup failed');
          final imageUrl = bypassCache ? 'fresh' : 'cached';
          return '<div id="i1"><div id="i3"><a><img src="$imageUrl"></a>'
              '</div></div>';
        },
      );
      await provider.init();
      provider.urls
        ..[0] = firstPage
        ..[1] = secondPage;

      expect(await provider.getImageUrl(0), 'cached');
      expect(await provider.getImageUrl(0), 'cached');
      expect(await provider.getImageUrl(1), 'cached');

      final fresh = provider.getImageUrlForRetry(0);
      expect(identical(fresh, provider.getImageUrlForRetry(0)), isTrue);
      expect(await fresh, 'fresh');
      expect(await provider.getImageUrl(0), 'fresh');
      expect(await provider.getImageUrl(1), 'cached');

      failRefresh = true;
      await expectLater(provider.getImageUrlForRetry(0), throwsStateError);
      expect(await provider.getImageUrl(0), 'fresh');
      expect(calls, [
        (firstPage, false),
        (secondPage, false),
        (firstPage, true),
        (firstPage, true),
      ]);
    }
  });
}
