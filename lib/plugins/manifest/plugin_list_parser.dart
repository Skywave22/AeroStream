import 'dart:convert';

import 'package:collection/collection.dart';

import '../../core/errors/plugin_error.dart';
import '../../core/json/json_read.dart';
import '../../core/result.dart';
import '../../core/utils/version.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/plugin_repository.dart';

/// One plugin list, already normalised, plus the ecosystem it turned out to be.
final class ParsedPluginList {
  const ParsedPluginList({required this.ecosystem, required this.plugins});

  final PluginEcosystem ecosystem;
  final List<AvailablePlugin> plugins;

  bool get isEmpty => plugins.isEmpty;
}

/// Parses a repository's plugin list into [AvailablePlugin]s.
///
/// The three ecosystems publish *different* list shapes, and the outer manifest
/// is identical for two of them, so detection happens here, on the entries:
///
/// * CloudStream — `plugins.json` is an array of
///   `{url, version, name, internalName, authors, description, fileSize,
///   repositoryUrl, language, tvTypes, iconUrl, apiVersion, fileHash, status}`
///   where `url` is a `.cs3` file.
/// * SkyStream — an array of plugin manifests that carry `packageName` and a
///   `.sky` download URL.
/// * Vega — `manifest.json` is an array of
///   `{display_name, value, version, icon, type, hasSettings, disabled}` and
///   the modules live next to it under `dist/<value>/`.
abstract final class PluginListParser {
  /// Parses [body], using [sourceUrl] to resolve relative download URLs.
  ///
  /// [hint] short-circuits detection when the repository is already known
  /// (an update check on an installed repository).
  static Result<ParsedPluginList> parse(
    String body, {
    required String sourceUrl,
    required String repositoryId,
    PluginEcosystem? hint,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      return Err<ParsedPluginList>(
        PluginParseError('Plugin list is not valid JSON', cause: error),
      );
    }

    if (decoded is! List) {
      return const Err<ParsedPluginList>(
        PluginParseError(
          'Plugin list must be a JSON array',
          field: 'root',
        ),
      );
    }

    final entries = readMapList(decoded);
    if (entries.isEmpty) {
      // A valid, empty list is not an error: repositories publish one while
      // their extensions are being rebuilt.
      return Ok<ParsedPluginList>(
        ParsedPluginList(
          ecosystem: hint ?? PluginEcosystem.skystream,
          plugins: const <AvailablePlugin>[],
        ),
      );
    }

    final ecosystem = hint ??
        detectEcosystem(entries) ??
        PluginEcosystem.skystream;

    final base = Uri.tryParse(sourceUrl);
    final plugins = <AvailablePlugin>[];
    for (final entry in entries) {
      final plugin = switch (ecosystem) {
        PluginEcosystem.cloudstream => _cloudStream(entry, base, repositoryId),
        PluginEcosystem.skystream => _skyStream(entry, base, repositoryId),
        PluginEcosystem.vega => _vega(entry, base, repositoryId),
      };
      if (plugin != null) plugins.add(plugin);
    }

    return Ok<ParsedPluginList>(
      ParsedPluginList(
        ecosystem: ecosystem,
        plugins: List<AvailablePlugin>.unmodifiable(plugins),
      ),
    );
  }

  /// Guesses the ecosystem from the shape of the entries.
  static PluginEcosystem? detectEcosystem(
    List<Map<String, Object?>> entries,
  ) {
    if (entries.isEmpty) return null;
    final first = entries.first;

    // Vega: `value` + `display_name` and no download URL of its own.
    if (first.containsKey('value') &&
        (first.containsKey('display_name') || first.containsKey('displayName'))) {
      return PluginEcosystem.vega;
    }
    // CloudStream: .cs3 artifacts, tvTypes, or a `status` int.
    if (first.containsKey('tvTypes') ||
        first.containsKey('internalName') ||
        (readString(first['url'])?.toLowerCase().endsWith('.cs3') ?? false)) {
      return PluginEcosystem.cloudstream;
    }
    // SkyStream: .sky artifacts or a packageName manifest.
    if (readString(first['url'])?.toLowerCase().endsWith('.sky') ?? false) {
      return PluginEcosystem.skystream;
    }
    if (first.containsKey('packageName')) return PluginEcosystem.skystream;
    if (first.containsKey('apiVersion')) return PluginEcosystem.cloudstream;
    return null;
  }

  static AvailablePlugin? _cloudStream(
    Map<String, Object?> entry,
    Uri? base,
    String repositoryId,
  ) {
    final downloadUrl = _absolute(readString(entry['url']), base);
    final id = readString(entry['internalName']) ??
        readString(entry['name']) ??
        readString(entry['id']);
    if (downloadUrl == null || id == null) return null;
    return AvailablePlugin(
      id: id,
      name: readString(entry['name']) ?? id,
      version: PluginVersion.parse(entry['version']),
      description: readString(entry['description']),
      authors: readStringList(entry['authors']),
      language: readString(entry['language']),
      iconUrl: _absolute(readString(entry['iconUrl']), base),
      supportedTypes: readStringList(entry['tvTypes'])
          .map(MediaType.fromWire)
          .toSet(),
      downloadUrl: downloadUrl,
      ecosystem: PluginEcosystem.cloudstream,
      repositoryId: repositoryId,
      fileSize: readInt(entry['fileSize']),
      fileHash: readString(entry['fileHash']),
      apiVersion: readInt(entry['apiVersion']),
      // Missing status means "publish it, it works".
      status: readInt(entry['status']) ?? 1,
    );
  }

  static AvailablePlugin? _skyStream(
    Map<String, Object?> entry,
    Uri? base,
    String repositoryId,
  ) {
    final downloadUrl = _absolute(
      readString(entry['url']) ?? readString(entry['downloadUrl']),
      base,
    );
    final id = readString(entry['packageName']) ?? readString(entry['id']);
    if (downloadUrl == null || id == null) return null;
    return AvailablePlugin(
      id: id,
      name: readString(entry['name']) ?? id,
      version: PluginVersion.parse(entry['version']),
      description: readString(entry['description']),
      authors: readStringList(entry['authors']),
      language: readStringList(entry['languages']).firstOrNull ??
          readString(entry['language']),
      iconUrl: _absolute(readString(entry['iconUrl']), base),
      supportedTypes: readStringList(
        entry['types'] ?? entry['categories'],
      ).map(MediaType.fromWire).toSet(),
      downloadUrl: downloadUrl,
      ecosystem: PluginEcosystem.skystream,
      repositoryId: repositoryId,
      fileSize: readInt(entry['fileSize']),
      fileHash: readString(entry['fileHash']) ?? readString(entry['sha256']),
      settings: _settingKeys(entry['settings']),
    );
  }

  /// Vega entries point at a directory, not a file: the provider's modules are
  /// fetched from `<base>/dist/<value>/` at install time.
  static AvailablePlugin? _vega(
    Map<String, Object?> entry,
    Uri? base,
    String repositoryId,
  ) {
    final value = readString(entry['value']) ?? readString(entry['id']);
    if (value == null || base == null) return null;
    final distRoot = base.resolve('dist/');
    final providerUrl = distRoot.resolve('$value/').toString();
    return AvailablePlugin(
      id: value,
      name: readString(entry['display_name']) ??
          readString(entry['displayName']) ??
          value,
      version: PluginVersion.parse(entry['version']),
      description: readString(entry['description']),
      authors: readStringList(entry['author'] ?? entry['authorName']),
      iconUrl: _absolute(readString(entry['icon']), base),
      supportedTypes: const <MediaType>{},
      downloadUrl: providerUrl,
      ecosystem: PluginEcosystem.vega,
      repositoryId: repositoryId,
      status: readBool(entry['disabled']) ? 0 : 1,
      settings: readBool(entry['hasSettings'])
          ? const <String>['settings']
          : const <String>[],
    );
  }

  static List<String> _settingKeys(Object? raw) {
    final settings = readList(raw);
    final keys = <String>[];
    for (final setting in settings) {
      final map = readMap(setting);
      final key = readString(map['key']) ?? readString(map['name']);
      if (key != null) keys.add(key);
    }
    return keys;
  }

  static String? _absolute(String? value, Uri? base) {
    if (value == null) return null;
    final parsed = Uri.tryParse(value);
    if (parsed == null) return null;
    if (parsed.hasScheme) return parsed.toString();
    if (base == null) return null;
    return base.resolveUri(parsed).toString();
  }
}
