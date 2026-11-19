import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

import '../../core/errors/plugin_error.dart';
import '../../core/logging/app_log.dart';
import '../../core/network/http_service.dart';
import '../../core/result.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/plugin_repository.dart';
import '../../domain/repositories/extension_store.dart';
import '../manifest/plugin_list_parser.dart';
import '../manifest/repository_manifest.dart';

/// Adds, refreshes and removes plugin repositories.
///
/// The flow for every ecosystem is:
///   1. fetch the URL the user typed;
///   2. parse it as an outer repository manifest, or — for Vega, whose
///      repositories *are* a provider list — as a provider array;
///   3. fetch the first plugin list to learn the ecosystem from its entries;
///   4. persist the repository so its plugins can be browsed.
final class RepositoryService {
  RepositoryService({required HttpService http, required ExtensionStore store})
    : _http = http,
      _store = store;

  final HttpService _http;
  final ExtensionStore _store;

  /// Adds a repository from a user-entered URL.
  Future<Result<PluginRepository>> addRepository(String input) async {
    final normalized = normalizeUrl(input);
    if (normalized == null) {
      return const Err<PluginRepository>(
        PluginParseError(
          'That does not look like a repository URL',
          field: 'url',
        ),
      );
    }
    final uri = Uri.parse(normalized);

    final fetched = await _http.get(uri);
    if (fetched is Err<HttpPayload>) {
      return Err<PluginRepository>(fetched.error);
    }
    final body = (fetched as Ok<HttpPayload>).value.text;

    // Vega publishes the provider array itself; everything else publishes a
    // repository manifest that points at plugin lists.
    final decoded = _tryDecode(body);
    if (decoded is List) {
      return _addVegaRepository(uri, body);
    }
    if (decoded is! Map) {
      return const Err<PluginRepository>(
        PluginParseError(
          'The URL did not return a repository manifest',
          field: 'root',
        ),
      );
    }

    final manifest = RepositoryManifest.parse(body, sourceUrl: normalized);
    if (manifest is Err<RepositoryManifest>) {
      return Err<PluginRepository>(manifest.error);
    }
    final parsed = (manifest as Ok<RepositoryManifest>).value;
    if (!parsed.isUsable) {
      return const Err<PluginRepository>(
        PluginParseError(
          'The repository lists no plugins and points at no other repository',
          field: 'pluginLists',
        ),
      );
    }

    // Learn the ecosystem from the first list we can read.
    PluginEcosystem ecosystem = PluginEcosystem.skystream;
    for (final listUrl in parsed.pluginLists) {
      final listing = await fetchPluginList(
        listUrl,
        repositoryId: _repositoryId(parsed, normalized),
      );
      if (listing is Ok<ParsedPluginList>) {
        ecosystem = listing.value.ecosystem;
        break;
      }
    }

    final repository = PluginRepository(
      id: _repositoryId(parsed, normalized),
      name: parsed.name,
      url: normalized,
      ecosystem: ecosystem,
      description: parsed.description,
      iconUrl: parsed.iconUrl,
      pluginLists: parsed.pluginLists,
      includedRepos: parsed.includedRepos,
      manifestVersion: parsed.manifestVersion,
      addedAt: DateTime.now(),
      lastCheckedAt: DateTime.now(),
    );

    // Re-adding a repository the user already has refreshes it in place.
    final existing = (await _store.repositories())
        .where((candidate) => candidate.id == repository.id)
        .firstOrNull;
    final merged = existing == null
        ? repository
        : repository.copyWith(addedAt: existing.addedAt);

    await _store.upsertRepository(merged);
    AppLog.info(
      'Repository added: ${merged.name} (${merged.ecosystem.wire})',
    );
    return Ok<PluginRepository>(merged);
  }

  Future<Result<PluginRepository>> _addVegaRepository(
    Uri uri,
    String body,
  ) async {
    final listing = PluginListParser.parse(
      body,
      sourceUrl: uri.toString(),
      repositoryId: _hashId(uri.toString()),
      hint: PluginEcosystem.vega,
    );
    if (listing is Err<ParsedPluginList>) {
      return Err<PluginRepository>(listing.error);
    }
    final repository = PluginRepository(
      id: _hashId(uri.toString()),
      name: uri.host.isEmpty ? 'Vega providers' : uri.host,
      url: uri.toString(),
      ecosystem: PluginEcosystem.vega,
      description: 'Vega provider bundle',
      pluginLists: <String>[uri.toString()],
      addedAt: DateTime.now(),
      lastCheckedAt: DateTime.now(),
    );
    await _store.upsertRepository(repository);
    AppLog.info('Vega repository added: ${repository.name}');
    return Ok<PluginRepository>(repository);
  }

  /// Fetches and parses one plugin list.
  Future<Result<ParsedPluginList>> fetchPluginList(
    String url, {
    required String repositoryId,
    PluginEcosystem? hint,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      return const Err<ParsedPluginList>(
        PluginParseError('Plugin list URL is not http(s)', field: 'url'),
      );
    }
    final response = await _http.get(uri);
    if (response is Err<HttpPayload>) {
      return Err<ParsedPluginList>(response.error);
    }
    return PluginListParser.parse(
      (response as Ok<HttpPayload>).value.text,
      sourceUrl: url,
      repositoryId: repositoryId,
      hint: hint,
    );
  }

  /// Every plugin offered by [repository], across all of its plugin lists.
  Future<Result<List<AvailablePlugin>>> browse(
    PluginRepository repository, {
    PluginEcosystem? hint,
  }) async {
    final collected = <AvailablePlugin>[];
    final seen = <String>{};
    PluginError? firstError;

    for (final listUrl in repository.pluginLists) {
      final listing = await fetchPluginList(
        listUrl,
        repositoryId: repository.id,
        hint: hint ?? repository.ecosystem,
      );
      switch (listing) {
        case Ok<ParsedPluginList>(:final value):
          for (final plugin in value.plugins) {
            if (seen.add('${plugin.ecosystem.wire}:${plugin.id}')) {
              collected.add(plugin);
            }
          }
        case Err<ParsedPluginList>(:final error):
          firstError ??= error;
      }
    }

    if (collected.isEmpty && firstError != null) {
      return Err<List<AvailablePlugin>>(firstError);
    }

    for (final included in repository.includedRepos) {
      final nested = await _browseIncluded(included, repository, seen);
      collected.addAll(nested);
    }

    return Ok<List<AvailablePlugin>>(
      List<AvailablePlugin>.unmodifiable(collected),
    );
  }

  /// A CloudStream "mega-repo" points at other repository manifests; pull in
  /// their listings too, one level deep, so browsing a single URL shows the
  /// plugins the user expects.
  Future<List<AvailablePlugin>> _browseIncluded(
    String url,
    PluginRepository parent,
    Set<String> seen,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return const <AvailablePlugin>[];
    final response = await _http.get(uri);
    if (response is! Ok<HttpPayload>) return const <AvailablePlugin>[];

    final manifest = RepositoryManifest.parse(
      response.value.text,
      sourceUrl: url,
    );
    if (manifest is! Ok<RepositoryManifest>) return const <AvailablePlugin>[];

    final results = <AvailablePlugin>[];
    for (final listUrl in manifest.value.pluginLists) {
      final listing = await fetchPluginList(
        listUrl,
        repositoryId: parent.id,
        hint: PluginEcosystem.cloudstream,
      );
      if (listing is! Ok<ParsedPluginList>) continue;
      for (final plugin in listing.value.plugins) {
        if (seen.add('${plugin.ecosystem.wire}:${plugin.id}')) {
          results.add(plugin);
        }
      }
    }
    return results;
  }

  /// Re-fetches [repository]'s manifest and returns the updated record.
  Future<Result<PluginRepository>> refresh(PluginRepository repository) async {
    final uri = Uri.tryParse(repository.url);
    if (uri == null) {
      return const Err<PluginRepository>(
        PluginParseError('Repository URL is not valid', field: 'url'),
      );
    }
    final response = await _http.get(uri);
    if (response is Err<HttpPayload>) {
      return Err<PluginRepository>(response.error);
    }
    final body = (response as Ok<HttpPayload>).value.text;
    final decoded = _tryDecode(body);

    if (decoded is List) {
      final refreshed = repository.copyWith(lastCheckedAt: DateTime.now());
      await _store.upsertRepository(refreshed);
      return Ok<PluginRepository>(refreshed);
    }

    final manifest = RepositoryManifest.parse(body, sourceUrl: repository.url);
    if (manifest is Err<RepositoryManifest>) {
      return Err<PluginRepository>(manifest.error);
    }
    final parsed = (manifest as Ok<RepositoryManifest>).value;
    final refreshed = repository.copyWith(
      name: parsed.name,
      description: parsed.description,
      iconUrl: parsed.iconUrl,
      pluginLists: parsed.pluginLists,
      includedRepos: parsed.includedRepos,
      manifestVersion: parsed.manifestVersion,
      lastCheckedAt: DateTime.now(),
    );
    await _store.upsertRepository(refreshed);
    return Ok<PluginRepository>(refreshed);
  }

  Future<void> remove(PluginRepository repository) =>
      _store.deleteRepository(repository.id);

  /// Accepts `host.tld/path`, `https://…` and `http://…`.
  ///
  /// A bare string that contains a dot and no spaces is assumed to be https;
  /// anything else is rejected rather than guessed at.
  static String? normalizeUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.contains(RegExp(r'\s'))) return null;

    final withScheme = trimmed.contains('://')
        ? trimmed
        : trimmed.startsWith('//')
            ? 'https:$trimmed'
            : 'https://$trimmed';

    final uri = Uri.tryParse(withScheme);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty || !uri.host.contains('.')) return null;
    return uri.toString();
  }

  static String _repositoryId(RepositoryManifest manifest, String url) =>
      manifest.packageName ?? _hashId(url);

  static String _hashId(String url) =>
      sha256.convert(utf8.encode(url)).toString().substring(0, 10);

  static Object? _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }
}
