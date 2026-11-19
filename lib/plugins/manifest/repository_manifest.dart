import 'dart:convert';

import '../../core/errors/plugin_error.dart';
import '../../core/json/json_read.dart';
import '../../core/result.dart';

/// The outer manifest every ecosystem's repository publishes.
///
/// Verified against a live CloudStream repository (`repo.json`) and SkyStream's
/// own manifest builder: both use the same six keys. Vega repositories expose
/// the provider list at `manifest.json` directly, so a Vega repository is
/// synthesised from that list and never needs this parser.
final class RepositoryManifest {
  const RepositoryManifest({
    required this.name,
    required this.pluginLists,
    this.description,
    this.iconUrl,
    this.manifestVersion = 1,
    this.includedRepos = const <String>[],
    this.packageName,
  });

  final String name;
  final String? description;
  final String? iconUrl;
  final int manifestVersion;

  /// Absolute URLs of the plugin lists this repository publishes.
  final List<String> pluginLists;

  /// Other repository manifests to pull in (CloudStream mega-repos).
  final List<String> includedRepos;

  /// An explicit repository id, used by CloudStream forks.
  final String? packageName;

  bool get isUsable => pluginLists.isNotEmpty || includedRepos.isNotEmpty;

  /// Parses `repo.json`.
  ///
  /// Relative plugin-list URLs are resolved against [sourceUrl] — several
  /// community repositories ship `/plugins.json` rather than an absolute URL,
  /// and silently ignoring those would list an empty repository.
  static Result<RepositoryManifest> parse(
    String body, {
    required String sourceUrl,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      return Err<RepositoryManifest>(
        PluginParseError(
          'Repository manifest is not valid JSON',
          cause: error,
        ),
      );
    }

    if (decoded is! Map<Object?, Object?>) {
      return const Err<RepositoryManifest>(
        PluginParseError(
          'Repository manifest must be a JSON object',
          field: 'root',
        ),
      );
    }

    final json = readMap(decoded);
    final base = Uri.tryParse(sourceUrl);
    final lists = <String>[];
    for (final entry in readList(json['pluginLists'])) {
      final resolved = _absolute(readString(entry), base);
      if (resolved != null) lists.add(resolved);
    }
    final included = <String>[];
    for (final entry in readList(json['repos'])) {
      final resolved = _absolute(readString(entry), base);
      if (resolved != null) included.add(resolved);
    }

    final name = readString(json['name']);
    if (name == null && lists.isEmpty && included.isEmpty) {
      return const Err<RepositoryManifest>(
        PluginParseError(
          'Not a repository manifest: no name and no plugin lists',
          field: 'name',
        ),
      );
    }

    return Ok<RepositoryManifest>(
      RepositoryManifest(
        name: name ?? Uri.tryParse(sourceUrl)?.host ?? 'Repository',
        description: readString(json['description']),
        iconUrl: _absolute(readString(json['iconUrl']), base),
        manifestVersion: readInt(json['manifestVersion']) ?? 1,
        pluginLists: List<String>.unmodifiable(lists),
        includedRepos: List<String>.unmodifiable(included),
        packageName: readString(json['packageName']),
      ),
    );
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
