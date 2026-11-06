import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:image_size_getter/file_input.dart';
import 'package:image_size_getter/image_size_getter.dart' as dimensions;
import 'package:path/path.dart' as p;

/// A ZIP page reference is metadata only: no extracted file is created.
class DownloadArchive {
  static const int _maxArchiveFileNameBytes = 200;

  static bool isEntry(String source) => source.startsWith('violet-zip:');

  static String fileName(String id, String? title) {
    var sanitized = (title ?? '').trim();
    if (sanitized.isEmpty) return '$id.zip';

    sanitized = sanitized.replaceAll(RegExp(r'[:/\\*?"<>|]'), '_');
    sanitized = String.fromCharCodes(
      sanitized.codeUnits.map((unit) => unit < 32 ? 95 : unit),
    );
    sanitized = _stripEmoji(sanitized);
    sanitized = _trimWindowsTrailingCharacters(sanitized);
    if (sanitized.isEmpty) return '$id.zip';

    final prefix = '$id (';
    const suffix = ').zip';
    final titleBudget =
        _maxArchiveFileNameBytes - utf8.encode('$prefix$suffix').length;
    if (titleBudget <= 0) return '$id.zip';

    sanitized = _truncateUtf8(sanitized, titleBudget);
    sanitized = _trimWindowsTrailingCharacters(sanitized);
    if (sanitized.isEmpty) return '$id.zip';

    return '$prefix$sanitized$suffix';
  }

  static String _stripEmoji(String value) {
    final buffer = StringBuffer();

    for (final rune in value.runes) {
      final isEmoji =
          rune == 0x200D ||
          rune == 0x20E3 ||
          rune == 0xFE0E ||
          rune == 0xFE0F ||
          (rune >= 0x1F3FB && rune <= 0x1F3FF) ||
          (rune >= 0x1F000 && rune <= 0x1FAFF) ||
          (rune >= 0x2600 && rune <= 0x27BF);

      if (!isEmoji) {
        buffer.writeCharCode(rune);
      }
    }

    return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _trimWindowsTrailingCharacters(String value) {
    var end = value.length;
    while (end > 0 &&
        (value.codeUnitAt(end - 1) == 0x20 ||
            value.codeUnitAt(end - 1) == 0x2E)) {
      end--;
    }
    return end == value.length ? value : value.substring(0, end);
  }

  static String _truncateUtf8(String value, int maxBytes) {
    final buffer = StringBuffer();
    var used = 0;

    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      final bytes = utf8.encode(character).length;
      if (used + bytes > maxBytes) break;
      buffer.write(character);
      used += bytes;
    }

    return buffer.toString();
  }

  static String entry(String archive, String name) => Uri(
    scheme: 'violet-zip',
    path: File(archive).absolute.path,
    fragment: name,
  ).toString();

  static String backingFile(String source) =>
      isEntry(source) ? Uri.decodeComponent(Uri.parse(source).path) : source;

  static String entryName(String source) => isEntry(source)
      ? Uri.decodeComponent(Uri.parse(source).fragment)
      : p.basename(source);

  static bool exists(String source) => File(backingFile(source)).existsSync();

  /// Verify a completed download without extracting or rewriting its ZIP.
  ///
  /// A completed gallery normally stores `violet-zip:` references; its
  /// original loose pages have already been deleted. The archive is checked
  /// in an isolate so even a large gallery cannot block the UI thread.
  static Future<bool> isComplete(List<String> sources) => Isolate.run(() {
    if (sources.isEmpty) return false;

    final zipReferences = sources.every(isEntry);
    if (!zipReferences) {
      // Older installations may still have loose completed images.
      if (sources.any(isEntry)) return false;
      return sources.every((source) {
        final file = File(source);
        return file.existsSync() && file.lengthSync() >= 5;
      });
    }

    try {
      final archivePath = backingFile(sources.first);
      if (sources.any((source) => backingFile(source) != archivePath)) {
        return false;
      }
      final zipFile = File(archivePath);
      if (!zipFile.existsSync()) return false;

      final input = InputFileStream(archivePath);
      try {
        final archive = ZipDecoder().decodeStream(input);
        final names = sources.map(entryName).toList();
        if (archive.length != names.length ||
            names.toSet().length != names.length) {
          return false;
        }
        for (final name in names) {
          final file = archive.find(name);
          if (file == null || !file.isFile) return false;
          final bytes = file.readBytes();
          if (bytes == null ||
              bytes.length != file.size ||
              getCrc32(bytes) != file.crc32) {
            return false;
          }
          file.clear();
        }
        return true;
      } finally {
        input.closeSync();
      }
    } catch (_) {
      return false;
    }
  });

  static Future<void> _readTail = Future<void>.value();

  static Future<Uint8List> read(String source) {
    // Thumbnail grids can request hundreds of pages; bound ZIP worker memory.
    final result = _readTail.then((_) => Isolate.run(() => readSync(source)));
    _readTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  static String relocate(String source, String documentsPath) {
    final path = backingFile(source);
    final prefix = RegExp(
      r'^(/private)?/var/mobile/Containers/Data/Application/[^/]+/Documents(?=/|$)',
    );
    if (!prefix.hasMatch(path)) return source;
    final relocated = path.replaceFirst(prefix, documentsPath);
    return isEntry(source) ? entry(relocated, entryName(source)) : relocated;
  }

  static Uint8List readSync(String source) {
    if (!isEntry(source)) return File(source).readAsBytesSync();
    final input = InputFileStream(backingFile(source));
    try {
      final archive = ZipDecoder().decodeStream(input);
      return _readEntry(archive.find(entryName(source)));
    } finally {
      input.closeSync();
    }
  }

  static Uint8List _readEntry(ArchiveFile? file) {
    if (file == null || !file.isFile) throw StateError('ZIP page is missing');
    final bytes = file.readBytes();
    if (bytes == null ||
        bytes.length != file.size ||
        getCrc32(bytes) != file.crc32) {
      throw StateError('ZIP page is damaged');
    }
    return bytes;
  }

  /// Read page dimensions in source order, opening each ZIP once per batch.
  static Future<List<(int, int)?>> imageSizes(List<String> sources) =>
      Isolate.run(() {
        final sizes = List<(int, int)?>.filled(sources.length, null);
        final archives = <String, Map<String, List<int>>>{};
        for (var index = 0; index < sources.length; index++) {
          final source = sources[index];
          try {
            if (isEntry(source)) {
              final entries = archives.putIfAbsent(
                backingFile(source),
                () => {},
              );
              entries.putIfAbsent(entryName(source), () => []).add(index);
            } else {
              final size = dimensions.ImageSizeGetter.getSize(
                FileInput(File(source)),
              );
              sizes[index] = (size.width, size.height);
            }
          } catch (_) {
            // Missing or unreadable pages use the viewer's default dimensions.
          }
        }

        for (final archive in archives.entries) {
          _readZipImageSizes(archive.key, archive.value, sizes);
        }
        return sizes;
      });

  static void _readZipImageSizes(
    String path,
    Map<String, List<int>> entries,
    List<(int, int)?> sizes,
  ) {
    try {
      final input = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        for (final entry in entries.entries) {
          final file = archive.find(entry.key);
          try {
            final size = dimensions.ImageSizeGetter.getSize(
              dimensions.MemoryInput(_readEntry(file)),
            );
            for (final index in entry.value) {
              sizes[index] = (size.width, size.height);
            }
          } catch (_) {
            // A damaged entry does not prevent reading other pages in the ZIP.
          } finally {
            file?.clear();
          }
        }
      } finally {
        input.closeSync();
      }
    } catch (_) {
      // A missing or damaged archive leaves its pages at default dimensions.
    }
  }

  /// Write and verify in an isolate. Originals remain intact until the caller
  /// commits the new references to the database. STORE avoids recompressing images.
  static Future<List<String>> create(
    String destination,
    List<String> files,
  ) => Isolate.run(() async {
    if (files.isEmpty) throw StateError('Cannot archive an empty download');
    final temporary = '$destination.part';
    final encoder = ZipFileEncoder();
    final names = <String>[];
    var opened = false;
    try {
      encoder.create(temporary, level: 0);
      opened = true;
      for (var i = 0; i < files.length; i++) {
        final source = File(files[i]);
        if (!source.existsSync() || source.lengthSync() < 5) {
          throw StateError('Download page is missing or incomplete');
        }
        final prefix = p.basename(files[i]).startsWith('thumbnail')
            ? 'thumbnail-'
            : '';
        final name =
            '$prefix${i.toString().padLeft(6, '0')}${p.extension(files[i])}';
        names.add(name);
        final pageInput = InputFileStream(source.path);
        try {
          encoder.addArchiveFile(
            ArchiveFile.stream(name, pageInput)
              ..compression = CompressionType.none,
          );
        } finally {
          await pageInput.close();
        }
      }
      await encoder.close();
      opened = false;
      // Verify one page at a time, including CRC, before publishing the ZIP.
      final input = InputFileStream(temporary);
      try {
        final archive = ZipDecoder().decodeStream(input);
        if (archive.length != names.length)
          throw StateError('ZIP page count mismatch');
        for (var i = 0; i < names.length; i++) {
          final file = archive.find(names[i]);
          final bytes = file?.readBytes();
          if (file == null ||
              bytes == null ||
              bytes.length != File(files[i]).lengthSync() ||
              getCrc32(bytes) != file.crc32) {
            throw StateError('ZIP verification failed');
          }
          file.clear();
        }
      } finally {
        input.closeSync();
      }
      await File(temporary).rename(destination);
      return names.map((name) => entry(destination, name)).toList();
    } finally {
      try {
        if (opened) await encoder.close();
      } finally {
        final part = File(temporary);
        if (part.existsSync()) part.deleteSync();
      }
    }
  });

  static Future<void> deleteSources(Iterable<String> sources) async {
    for (final path in sources.map(backingFile).toSet()) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }
}
