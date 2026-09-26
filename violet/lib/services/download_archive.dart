import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// A ZIP page reference is metadata only: no extracted file is created.
class DownloadArchive {
  static const int _maxArchiveFileNameBytes = 200;

  static bool isEntry(String source) => source.startsWith('violet-zip:');

  static String fileName(String id, String? title) {
    var sanitized = title
            ?.trim()
            .replaceAll(RegExp(r'[:/\\*?"<>|\x00-\x1F]'), '_')
            .replaceFirst(RegExp(r'[. ]+
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
      final file = archive.find(entryName(source));
      if (file == null || !file.isFile) throw StateError('ZIP page is missing');
      final bytes = file.readBytes();
      if (bytes == null ||
          bytes.length != file.size ||
          getCrc32(bytes) != file.crc32) {
        throw StateError('ZIP page is damaged');
      }
      return bytes;
    } finally {
      input.closeSync();
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
), '') ??
        '';

    if (sanitized.isEmpty) return '$id.zip';

    final prefix = '$id (';
    const suffix = ').zip';
    final titleBudget =
        _maxArchiveFileNameBytes - utf8.encode('$prefix$suffix').length;
    if (titleBudget <= 0) return '$id.zip';

    sanitized = _truncateUtf8(sanitized, titleBudget)
        .replaceFirst(RegExp(r'[. ]+
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
      final file = archive.find(entryName(source));
      if (file == null || !file.isFile) throw StateError('ZIP page is missing');
      final bytes = file.readBytes();
      if (bytes == null ||
          bytes.length != file.size ||
          getCrc32(bytes) != file.crc32) {
        throw StateError('ZIP page is damaged');
      }
      return bytes;
    } finally {
      input.closeSync();
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
), '');
    if (sanitized.isEmpty) return '$id.zip';

    return '$prefix$sanitized$suffix';
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
      final file = archive.find(entryName(source));
      if (file == null || !file.isFile) throw StateError('ZIP page is missing');
      final bytes = file.readBytes();
      if (bytes == null ||
          bytes.length != file.size ||
          getCrc32(bytes) != file.crc32) {
        throw StateError('ZIP page is damaged');
      }
      return bytes;
    } finally {
      input.closeSync();
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
