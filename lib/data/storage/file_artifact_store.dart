import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/errors/plugin_error.dart';
import '../../core/result.dart';
import '../../core/utils/safe_paths.dart';
import '../../domain/entities/enums.dart';
import '../../domain/repositories/extension_store.dart';

/// Filesystem [ArtifactStore].
///
/// Layout: `<root>/<ecosystem>/<pluginId>/<version>/`. Writes land in a staging
/// directory (`.staging-<id>-<millis>`) and are swapped into place with
/// `rename`, which is the closest thing to an atomic install the filesystems we
/// target offer. Nothing is deleted before the new version is on disk, so a
/// failed update leaves the old install runnable.
final class FileArtifactStore implements ArtifactStore {
  FileArtifactStore(this._root);

  /// The root directory, usually `<appSupport>/plugins`.
  final String _root;

  @override
  Future<String> pluginsRoot() async => _root;

  @override
  Future<Result<String>> install({
    required PluginEcosystem ecosystem,
    required String id,
    required String version,
    required Map<String, List<int>> files,
    List<int>? originalArchive,
    String? expectedSha256,
  }) async {
    if (!isSafeSegment(id)) {
      return Err<String>(
        PluginSandboxError(
          'Unsafe plugin id "$id"',
          pluginId: id,
          violation: 'path-traversal',
        ),
      );
    }
    if (!isSafeSegment(version)) {
      return Err<String>(
        PluginSandboxError(
          'Unsafe plugin version "$version"',
          pluginId: id,
          violation: 'path-traversal',
        ),
      );
    }

    final integrity = _verifyHash(id, files, originalArchive, expectedSha256);
    if (integrity != null) return Err<String>(integrity);

    final versionRoot = '$id/$version';
    final target = resolveWithin('$_root/${ecosystem.name}', versionRoot);
    if (target == null) {
      return Err<String>(
        PluginSandboxError(
          'Install path escapes the plugin root',
          pluginId: id,
          violation: 'path-traversal',
        ),
      );
    }

    final staging = Directory(
      '${Directory(target).parent.path}/.staging-$id-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );

    try {
      await staging.create(recursive: true);
      for (final entry in files.entries) {
        final path = resolveWithin(staging.path, entry.key);
        if (path == null) {
          throw PluginSandboxError(
            'Archive entry escapes the plugin directory: ${entry.key}',
            pluginId: id,
            violation: 'path-traversal',
          );
        }
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
      }

      if (originalArchive != null) {
        await File('${staging.path}/artifact.bin')
            .writeAsBytes(originalArchive, flush: true);
      }

      final targetDirectory = Directory(target);
      if (await targetDirectory.exists()) {
        final backup = Directory('${targetDirectory.parent.path}/.old-$id');
        if (await backup.exists()) await backup.delete(recursive: true);
        await targetDirectory.rename(backup.path);
        await staging.rename(target);
        if (await backup.exists()) await backup.delete(recursive: true);
      } else {
        await staging.rename(target);
      }
      return Ok<String>(target);
    } on PluginError catch (error) {
      await _deleteQuietly(staging);
      return Err<String>(error.copyWithPlugin(id));
    } on FileSystemException catch (error) {
      await _deleteQuietly(staging);
      return Err<String>(
        PluginUnknownError(
          'Could not write the plugin files: ${error.message}',
          pluginId: id,
          cause: error,
        ),
      );
    }
  }

  /// Returns an error when the artifact's hash does not match what the
  /// repository promised. A repository that publishes no hash is accepted (the
  /// listing is the only trust anchor we have for community plugins), and that
  /// decision is surfaced in the install dialog rather than hidden here.
  PluginError? _verifyHash(
    String id,
    Map<String, List<int>> files,
    List<int>? archive,
    String? expected,
  ) {
    if (expected == null || expected.trim().isEmpty) return null;
    final algorithmSplit = expected.split('-');
    if (algorithmSplit.length != 2) return null;
    final algorithm = algorithmSplit.first.toLowerCase();
    final wanted = algorithmSplit[1].toLowerCase();

    final data = archive ??
        (files.values.expand((bytes) => bytes).toList(growable: false));
    final digest = switch (algorithm) {
      'sha256' => sha256.convert(data).toString(),
      'sha1' => sha1.convert(data).toString(),
      'md5' => md5.convert(data).toString(),
      _ => null,
    };
    if (digest == null) return null;
    if (digest.toLowerCase() == wanted) return null;
    return PluginSandboxError(
      'Artifact hash mismatch: expected $wanted, got $digest',
      pluginId: id,
      violation: 'integrity',
    );
  }

  @override
  Future<void> remove(String artifactPath) async {
    final directory = Directory(artifactPath);
    if (!isWithin(_root, artifactPath)) return;
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  @override
  Future<bool> exists(String artifactPath) async {
    if (!isWithin(_root, artifactPath)) return false;
    final directory = Directory(artifactPath);
    if (!await directory.exists()) return false;
    final children = await directory.list().take(1).toList();
    return children.isNotEmpty;
  }

  @override
  Future<String?> readEntry(String artifactPath, String entryName) async {
    final path = resolveWithin(artifactPath, entryName);
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<List<String>> listEntries(String artifactPath) async {
    final directory = Directory(artifactPath);
    if (!await directory.exists()) return const <String>[];
    final entries = <String>[];
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) continue;
      entries.add(entity.path.substring(directory.path.length + 1));
    }
    entries.sort();
    return entries;
  }

  @override
  Future<int> totalSize() async {
    final root = Directory(_root);
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Staging cleanup is best effort; the next install overwrites it.
    }
  }
}
