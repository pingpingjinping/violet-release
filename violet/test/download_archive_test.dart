import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:violet/services/download_archive.dart';
import 'package:violet/services/download_image_provider.dart';
import 'package:flutter/painting.dart';
import 'dart:async';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('violet-zip-');
  });
  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    await root.delete(recursive: true);
  });

  Future<String> page(String name, List<int> bytes) async {
    final file = File('${root.path}/$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  test(
    'ZIP is readable after original files are removed; pages stay ordered',
    () async {
      final a = await page('page 10.png', png);
      final b = await page('page 2.jpg', [1, 2, 3, 4, 5, 6]);
      final zip = '${root.path}/한글 # 100%.zip';
      final refs = await DownloadArchive.create(zip, [a, b]);
      expect(File(a).existsSync(), true); // Caller commits DB before cleanup.
      expect(refs.map(DownloadArchive.entryName), ['000000.png', '000001.jpg']);
      expect(DownloadArchive.backingFile(refs.first), zip);
      await DownloadArchive.deleteSources([a, b]);
      expect(await DownloadArchive.read(refs[1]), [1, 2, 3, 4, 5, 6]);
      expect(await DownloadArchive.read(refs[0]), png);
      expect(root.listSync().map((file) => file.path), [zip]);
      await DownloadArchive.deleteSources(refs);
      expect(root.listSync(), isEmpty);
    },
  );

  test('archive filename uses id and a Windows-safe title', () {
    expect(
      DownloadArchive.fileName(
        '4192094',
        r'A:B/C\D*E?F"G<H>I|J',
      ),
      '4192094 (A_B_C_D_E_F_G_H_I_J).zip',
    );
    expect(DownloadArchive.fileName('4192094', '   '), '4192094.zip');
    expect(DownloadArchive.fileName('4192094', null), '4192094.zip');

    final longName = DownloadArchive.fileName(
      '4192094',
      List.filled(200, '가').join(),
    );
    expect(utf8.encode(longName).length, lessThanOrEqualTo(200));
    expect(longName, startsWith('4192094 ('));
    expect(longName, endsWith(').zip'));
  });

  test('packing failure keeps originals and removes unfinished ZIP', () async {
    final source = await page('a.png', png);
    final zip = '${root.path}/failed.zip';
    await expectLater(
      DownloadArchive.create(zip, [source, '${root.path}/missing']),
      throwsStateError,
    );
    expect(await File(source).readAsBytes(), png);
    expect(File(zip).existsSync(), false);
    expect(File('$zip.part').existsSync(), false);
    await expectLater(DownloadArchive.create(zip, []), throwsStateError);
  });

  test('missing entries fail without blocking the next queued read', () async {
    final source = await page('a.png', png);
    final zip = '${root.path}/test.zip';
    final refs = await DownloadArchive.create(zip, [source]);
    final bad = DownloadArchive.read(DownloadArchive.entry(zip, 'missing.png'));
    final good = DownloadArchive.read(refs.first);
    await expectLater(bad, throwsStateError);
    expect(await good, png);
  });

  test('stored page corruption is detected by CRC', () async {
    final source = await page('a.png', png);
    final zip = '${root.path}/test.zip';
    final refs = await DownloadArchive.create(zip, [source]);
    final bytes = await File(zip).readAsBytes();
    // Local header: filename length at 26, extra length at 28.
    final offset =
        30 + bytes[26] + (bytes[27] << 8) + bytes[28] + (bytes[29] << 8);
    bytes[offset] ^= 1;
    await File(zip).writeAsBytes(bytes);
    await expectLater(DownloadArchive.read(refs.first), throwsStateError);
  });

  test(
    'iOS container relocation preserves ZIP entry names and loose paths',
    () {
      const old = '/var/mobile/Containers/Data/Application/old/Documents';
      const next = '/var/mobile/Containers/Data/Application/new/Documents';
      final ref = DownloadArchive.entry('$old/한글 #%.zip', 'thumbnail #%.png');
      final moved = DownloadArchive.relocate(ref, next);
      expect(DownloadArchive.backingFile(moved), '$next/한글 #%.zip');
      expect(DownloadArchive.entryName(moved), 'thumbnail #%.png');
      expect(DownloadArchive.relocate('$old/a.png', next), '$next/a.png');
      expect(
        DownloadArchive.relocate('/external/a.png', next),
        '/external/a.png',
      );
    },
  );

  test('thumbnail entries remain identifiable', () async {
    final source = await page('thumbnail.png', png);
    final refs = await DownloadArchive.create('${root.path}/test.zip', [
      source,
    ]);
    expect(DownloadArchive.entryName(refs.first), startsWith('thumbnail'));
  });

  test(
    'Flutter image provider and image dimensions read ZIP without extraction',
    () async {
      final source = await page('a.png', png);
      final refs = await DownloadArchive.create('${root.path}/test.zip', [
        source,
      ]);
      await File(source).delete();
      expect(await downloadImageSizes(refs), [(1, 1)]);
      final result = Completer<ImageInfo>();
      final stream = DownloadImageProvider(
        refs.first,
      ).resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener(
        (info, _) => result.complete(info),
        onError: result.completeError,
      );
      stream.addListener(listener);
      try {
        final info = await result.future.timeout(const Duration(seconds: 10));
        expect(info.image.width, 1);
        expect(info.image.height, 1);
        info.dispose();
      } finally {
        stream.removeListener(listener);
      }
      expect(root.listSync().length, 1);
    },
  );
}
