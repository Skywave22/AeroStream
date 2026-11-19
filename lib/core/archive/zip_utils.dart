import 'dart:convert';

import 'package:archive/archive.dart';

import '../errors/plugin_error.dart';
import '../result.dart';
import 'safe_paths.dart';

/// A tiny zip reader for plugin packages.
///
/// Used by the installer (a `.sky` is a zip) and by the test fixtures. Entry
/// names are validated before they ever reach the filesystem: an archive is a
/// hostile input by default.
abstract final class ZipUtils {
  /// Whether a byte stream starts with the zip local-file magic `PK`.
  static bool looksLikeZip(List<int> bytes) =>
      bytes.length > 3 && bytes[0] == 0x50 && bytes[1] == 0x4B;

  /// Extracts `relative path -> bytes`, rejecting unsafe entry names.
  static Result<Map<String, List<int>>> extract(List<int> bytes) {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      final files = <String, List<int>>{};
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        final name = entry.name;
        if (!isSafeRelativePath(name)) {
          return Err<Map<String, List<int>>>(
            PluginSandboxError(
              'Archive entry escapes the plugin directory: $name',
              violation: 'path-traversal',
            ),
          );
        }
        final content = entry.content;
        if (content is! List<int>) continue;
        files[name] = content;
      }
      if (files.isEmpty) {
        return const Err<Map<String, List<int>>>(
          PluginParseError('Archive is empty'),
        );
      }
      return Ok<Map<String, List<int>>>(files);
    } on Object catch (error, stack) {
      return Err<Map<String, List<int>>>(
        PluginParseError(
          'Could not read the plugin archive: $error',
          cause: error,
          stackTrace: stack,
        ),
      );
    }
  }

  /// Decodes a JSON manifest out of raw bytes, or `null` when it is not one.
  static Map<String, Object?>? decodeManifest(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value as Object?),
        );
      }
      return null;
    } on FormatException {
      return null;
    }
  }
}
