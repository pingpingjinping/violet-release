import 'dart:isolate';
import 'package:image_size_getter/file_input.dart';
import 'package:image_size_getter/image_size_getter.dart' as dimensions;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:extended_image/extended_image.dart';
import 'package:flutter/painting.dart';
import 'package:violet/services/download_archive.dart';

/// Uses Flutter's image cache and decoding for both loose files and ZIP entries.
class DownloadImageProvider extends ExtendedFileImageProvider {
  DownloadImageProvider(String source, {String? imageCacheName})
    : super(File(source), imageCacheName: imageCacheName);

  @override
  ImageStreamCompleter loadImage(FileImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _decode(decode),
      scale: scale,
      debugLabel: file.path,
    );
  }

  Future<ui.Codec> _decode(ImageDecoderCallback decode) async {
    try {
      final bytes = await DownloadArchive.read(file.path);
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      await evict();
      rethrow;
    }
  }
}

// Top-level worker avoids capturing a Flutter State in an isolate closure.
Future<List<(int, int)?>> downloadImageSizes(List<String> sources) =>
    Isolate.run(
      () => sources.map((source) {
        try {
          final size = DownloadArchive.isEntry(source)
              ? dimensions.ImageSizeGetter.getSize(
                  dimensions.MemoryInput(DownloadArchive.readSync(source)),
                )
              : dimensions.ImageSizeGetter.getSize(FileInput(File(source)));
          return (size.width, size.height);
        } catch (_) {
          return null;
        }
      }).toList(),
    );
