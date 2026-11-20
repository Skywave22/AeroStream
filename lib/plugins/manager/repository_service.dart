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
import 'repository_input.dart';

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

  /// Adds a repository from whatever the user typed.
  ///
  /// The three ecosystems accept different input — a manifest URL, a
  /// `cloudstreamrepo://` deep link, a `cutt.ly` shortcode, a Vega author name —
  /// so normalisation happens in [RepositoryInputResolver] and this method only
  /// has to try the resulting URLs until one parses.
  Future<Result<PluginRepository>> addRepository(
    String input, {
    PluginEcosystem? expect,
  }) async {
    final resolved = await RepositoryInputResolver(
      followRedirect: _followRedirect,
    ).resolve(input);
    if (resolved is Err<RepositoryInput>) {
      return Err<PluginRepository>(resolved.error);
    }
    final target = (resolved as Ok<RepositoryInput>).value;

    PluginError? lastError;
    for (final uri in target.attempts) {
      final fetched = await _http.get(uri);
      if (fetched is Err<HttpPayload>) {
        lastError = fetched.error;
        continue;
      }
      final body = (fetched as Ok<HttpPayload>).value.text;
      final decoded = _tryDecode(body);

      // Some repositories publish the plugin array itself instead of a
      // manifest that points at one. Which ecosystem owns that array is read
      // from its entries — assuming Vega here used to file CloudStream and
      // SkyStream lists as Vega sources, where every entry then looked
      // unreadable.
      if (decoded is List) {
        final detected = PluginListParser.detectEcosystemInBody(body) ?? expect;
        if (detected == null || detected == PluginEcosystem.vega) {
          return _addVegaRepository(uri, body);
        }
        return _addListRepository(uri, body, detected);
      }
      if (decoded is! Map) {
        lastError = const PluginParseError(
          'The URL did not return a repository manifest',
          field: 'root',
        );
        continue;
      }

      final manifest =
          RepositoryManifest.parse(body, sourceUrl: uri.toString());
      if (manifest is Err<RepositoryManifest>) {
        lastError = manifest.error;
        continue;
      }
      return _storeRepository(
        (manifest as Ok<RepositoryManifest>).value,
        sourceUrl: uri.toString(),
        hint: expect,
      );
    }

    return Err<PluginRepository>(
      lastError ??
          const PluginParseError(
            'No repository answered at that address',
            field: 'url',
          ),
    );
  }

  /// One hop of redirect, http(s) only. Shortcodes are the only thing that
  /// needs this, and they never legitimately chain.
  Future<Uri?> _followRedirect(Uri url) async {
    final result = await _http.resolveRedirect(url);
    return result is Ok<Uri> ? result.value : null;
  }

  /// The newest repository `manifestVersion` this build understands.
  static const int supportedManifestVersion = 1;

  Future<Result<PluginRepository>> _storeRepository(
    RepositoryManifest parsed, {
    required String sourceUrl,
    PluginEcosystem? hint,
  }) async {
    if (!parsed.isUsable) {
      return const Err<PluginRepository>(
        PluginParseError(
          'The repository lists no plugins and points at no other repository',
          field: 'pluginLists',
        ),
      );
    }

    if (parsed.manifestVersion > supportedManifestVersion) {
      // CloudStream does the same: a newer manifest may mean fields this build
      // would silently ignore, so it is refused by name rather than half-read.
      return Err<PluginRepository>(
        PluginParseError(
          'This repository needs a newer AeroStream: it asks for manifest '
          'version ${parsed.manifestVersion} and this build reads '
          '$supportedManifestVersion',
          field: 'manifestVersion',
        ),
      );
    }

    final id = _repositoryId(parsed, sourceUrl);

    // Learn the ecosystem from the first list we can read. The section the
    // user added it from is a hint, not an override: a repository that answers
    // with another ecosystem's entries is filed where its entries belong, so
    // the plugin list is never parsed as the wrong shape later.
    PluginEcosystem ecosystem = hint ?? PluginEcosystem.skystream;
    for (final listUrl in parsed.pluginLists) {
      final listing = await fetchPluginList(
        listUrl,
        repositoryId: id,
        hint: hint,
      );
      if (listing case Ok<ParsedPluginList>(:final value)
          when value.plugins.isNotEmpty) {
        ecosystem = value.ecosystem;
        break;
      }
    }

    final repository = PluginRepository(
      id: id,
      name: parsed.name,
      url: sourceUrl,
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

  /// A repository that publishes its plugin array directly, in [ecosystem].
  ///
  /// SkyStream and CloudStream both do this: the repository manifest is
  /// optional, and the plugin list is the file people actually share. Filing
  /// the list where its entries belong is what makes "add the URL someone
  /// gave me" work in every section.
  Future<Result<PluginRepository>> _addListRepository(
    Uri uri,
    String body,
    PluginEcosystem ecosystem,
  ) async {
    final repositoryId = _hashId('${ecosystem.wire}|$uri');
    final listing = PluginListParser.parse(
      body,
      sourceUrl: uri.toString(),
      repositoryId: repositoryId,
      hint: ecosystem,
    );
    if (listing is Err<ParsedPluginList>) {
      return Err<PluginRepository>(listing.error);
    }
    if ((listing as Ok<ParsedPluginList>).value.plugins.isEmpty) {
      return Err<PluginRepository>(
        PluginParseError(
          'That ${ecosystem.label} plugin list has no readable entries',
          field: 'pluginLists',
        ),
      );
    }
    final repository = PluginRepository(
      id: repositoryId,
      name: _listRepositoryName(uri),
      url: uri.toString(),
      ecosystem: ecosystem,
      description: '${ecosystem.label} plugin list',
      pluginLists: <String>[uri.toString()],
      addedAt: DateTime.now(),
      lastCheckedAt: DateTime.now(),
    );
    // Re-adding the same list refreshes it in place, like a manifest.
    final existing = (await _store.repositories())
        .where((candidate) => candidate.id == repository.id)
        .firstOrNull;
    final merged = existing == null
        ? repository
        : repository.copyWith(addedAt: existing.addedAt);
    await _store.upsertRepository(merged);
    AppLog.info('${ecosystem.label} plugin list added: ${merged.name}');
    return Ok<PluginRepository>(merged);
  }

  /// A readable name for a repository known only by the file it publishes.
  ///
  /// `raw.githubusercontent.com/<owner>/<repo>/<branch>/plugins.json` is named
  /// after its repository; anything else falls back to the folder or the host.
  static String _listRepositoryName(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length >= 3 && uri.host.contains('githubusercontent')) {
      return '${segments[0]}/${segments[1]}';
    }
    if (segments.length >= 2) return segments[segments.length - 2];
    return uri.host.isEmpty ? 'Plugin list' : uri.host;
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
    final body = (response as Ok<HttpPayload>).value.text;
    final primary = PluginListParser.parse(
      body,
      sourceUrl: url,
      repositoryId: repositoryId,
      hint: hint,
    );

    // A hint is a guess, and a wrong guess parses to an empty list rather than
    // to an error — every ecosystem's entries are objects. So when the hinted
    // parse finds nothing, the same body is read as each ecosystem and the
    // richest reading wins. No second request: this is all local.
    if (primary case Ok<ParsedPluginList>(:final value)
        when value.plugins.isNotEmpty) {
      return primary;
    }

    ParsedPluginList? best =
        primary is Ok<ParsedPluginList> ? primary.value : null;
    for (final ecosystem in PluginEcosystem.values) {
      if (ecosystem == hint) continue;
      final attempt = PluginListParser.parse(
        body,
        sourceUrl: url,
        repositoryId: repositoryId,
        hint: ecosystem,
      );
      if (attempt case Ok<ParsedPluginList>(:final value)
          when value.plugins.isNotEmpty) {
        if (best == null || value.plugins.length > best.plugins.length) {
          best = value;
        }
      }
    }
    if (best != null) return Ok<ParsedPluginList>(best);
    return primary;
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
