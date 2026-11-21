import 'dart:convert';

import '../../core/archive/zip_utils.dart';
import '../../core/errors/plugin_error.dart';
import '../../core/json/json_read.dart';
import '../../core/logging/app_log.dart';
import '../../core/network/http_service.dart';
import '../../core/platform/platform_profile.dart';
import '../../core/result.dart';
import '../../core/utils/version.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/installed_plugin.dart';
import '../../domain/entities/plugin_info.dart';
import '../../domain/entities/plugin_repository.dart';
import '../../domain/media_provider.dart';
import '../../domain/repositories/extension_store.dart';

/// Builds a runnable provider for an installed plugin.
///
/// The manager owns installation, not execution: it asks a factory for a
/// provider so the JS and CloudStream runtimes stay swappable and testable.
typedef ProviderFactory = Future<Result<MediaProvider>> Function(
    InstalledPlugin installed);

/// Install, update, roll back and remove plugins of every ecosystem.
final class ExtensionManager {
  ExtensionManager({
    required ExtensionStore store,
    required ArtifactStore artifacts,
    required HttpService http,
    required this.platform,
    ProviderFactory? providerFactory,
  })  : _store = store,
        _artifacts = artifacts,
        _http = http,
        _providerFactory = providerFactory;

  final ExtensionStore _store;
  final ArtifactStore _artifacts;
  final HttpService _http;
  final PlatformProfile platform;
  final ProviderFactory? _providerFactory;

  /// Vega providers are published as separate modules; these are the ones the
  /// adapter knows how to call. Missing optional modules are fine.
  ///
  /// `headers.js` and `providerContext.js` are not in this list on purpose:
  /// they live once at `<source>/dist/`, not inside a provider's folder, and
  /// nothing needs them here — a provider bundle is self-contained (esbuild
  /// inlines what it imports) and the sandbox supplies its own
  /// `providerContext`. Requesting them per provider only 404s.
  static const List<String> vegaModules = <String>[
    'posts.js',
    'stream.js',
    'meta.js',
    'catalog.js',
    'episodes.js',
    'settings.js',
  ];

  /// Modules Vega's own loader treats as mandatory: a bundle missing one of
  /// these is half a provider, and installing it only moves the failure to the
  /// first playback attempt.
  static const List<String> requiredVegaModules = <String>[
    'posts.js',
    'meta.js',
    'stream.js',
    'catalog.js',
  ];

  /// Downloads and installs [listed].
  Future<Result<InstalledPlugin>> install(AvailablePlugin listed) async {
    if (!listed.isInstallable(
      isNative: platform.isSupportedNativeTarget,
    )) {
      return Err<InstalledPlugin>(
        PluginUnsupportedError(
          platform.unsupportedReason(listed.ecosystem) ??
              'This plugin cannot be installed here',
          pluginId: listed.id,
          operation: 'install',
        ),
      );
    }

    AppLog.info('Installing ${listed.id} @ ${listed.version.raw}');
    final payload = await _fetchArtifact(listed);
    if (payload is Err<_Artifact>) {
      return Err<InstalledPlugin>(payload.error);
    }
    final artifact = (payload as Ok<_Artifact>).value;

    final installed = await _artifacts.install(
      ecosystem: listed.ecosystem,
      id: listed.id,
      version: _versionSegment(listed.version),
      files: artifact.files,
      originalArchive: artifact.archive,
      expectedSha256: listed.fileHash,
    );
    if (installed is Err<String>) {
      return Err<InstalledPlugin>(installed.error);
    }

    final previous = await _store.installedPlugin(
      pluginKey(listed.ecosystem, listed.id),
    );

    final info = artifact.info.copyWith(
      repositoryId: listed.repositoryId,
      sourceUrl: listed.downloadUrl,
      installedAt: DateTime.now(),
      enabled: true,
      priority: previous?.info.priority ?? 0,
      sizeBytes: artifact.files.values.fold<int>(
        0,
        (sum, bytes) => sum + bytes.length,
      ),
    );

    final record = InstalledPlugin(
      info: info,
      artifactPath: (installed as Ok<String>).value,
      previousArtifactPath: previous?.artifactPath,
    );
    await _store.upsertInstalledPlugin(record);
    AppLog.info('Installed ${info.id} @ ${info.version.raw}');
    return Ok<InstalledPlugin>(record);
  }

  /// Installs [listed] as an update of [installed], keeping the old artifact
  /// for one-step rollback.
  Future<Result<InstalledPlugin>> update(
    InstalledPlugin installed,
    AvailablePlugin listed,
  ) async {
    if (!(listed.version > installed.info.version)) {
      return const Err<InstalledPlugin>(
        PluginUnsupportedError(
          'The repository is not offering a newer version',
          operation: 'update',
        ),
      );
    }
    final result = await install(listed);
    return switch (result) {
      Ok<InstalledPlugin>(:final value) => Ok<InstalledPlugin>(
          value.copyWith(
            previousArtifactPath: installed.artifactPath,
            info: value.info.copyWith(priority: installed.info.priority),
          ),
        ),
      Err<InstalledPlugin>(:final error) => Err<InstalledPlugin>(error),
    };
  }

  /// Restores the artifact an update replaced.
  Future<Result<InstalledPlugin>> rollback(InstalledPlugin installed) async {
    final previousPath = installed.previousArtifactPath;
    if (previousPath == null) {
      return const Err<InstalledPlugin>(
        PluginNotFoundError('There is no previous version to restore'),
      );
    }
    if (!await _artifacts.exists(previousPath)) {
      return const Err<InstalledPlugin>(
        PluginNotFoundError('The previous version is no longer on disk'),
      );
    }
    // Recover the version the previous artifact declares, so the reverted
    // install is not offered the same update again.
    final version = await _versionOf(previousPath) ?? installed.info.version;
    final restored = InstalledPlugin(
      info: installed.info.copyWith(version: version),
      artifactPath: previousPath,
    );
    await _store.upsertInstalledPlugin(restored);
    return Ok<InstalledPlugin>(restored);
  }

  /// Removes the plugin record and its files.
  Future<void> uninstall(InstalledPlugin installed) async {
    await _store.deleteInstalledPlugin(installed.key);
    await _artifacts.remove(installed.artifactPath);
    final previous = installed.previousArtifactPath;
    if (previous != null) await _artifacts.remove(previous);
    AppLog.info('Uninstalled ${installed.info.id}');
  }

  /// Enables or disables a plugin without touching its files.
  Future<void> setEnabled(InstalledPlugin installed, {required bool enabled}) =>
      _store.setEnabled(installed.key, enabled: enabled);

  /// Reorders plugins; lower runs first in aggregated queries.
  Future<void> setPriority(
    InstalledPlugin installed, {
    required int priority,
  }) =>
      _store.setPriority(installed.key, priority: priority);

  /// Providers for every enabled plugin that can run on this platform.
  Future<List<MediaProvider>> activeProviders() async {
    final factory = _providerFactory;
    if (factory == null) return const <MediaProvider>[];

    final installed = await _store.installedPlugins();
    final providers = <MediaProvider>[];
    for (final plugin in installed) {
      if (!plugin.info.enabled) continue;
      if (!platform.supports(plugin.info.ecosystem)) continue;
      final provider = await factory(plugin);
      switch (provider) {
        case Ok<MediaProvider>(:final value):
          providers.add(value);
        case Err<MediaProvider>(:final error):
          AppLog.error(
            'Could not start ${plugin.info.id}: ${error.message}',
            pluginId: plugin.info.id,
          );
      }
    }
    return providers;
  }

  /// Pairs installed plugins with newer listings from their repositories.
  Future<List<({InstalledPlugin installed, AvailablePlugin upgrade})>>
      findUpdates(List<AvailablePlugin> listings) async {
    final installed = await _store.installedPlugins();
    final updates = <({InstalledPlugin installed, AvailablePlugin upgrade})>[];
    for (final plugin in installed) {
      for (final listing in listings) {
        if (listing.ecosystem != plugin.info.ecosystem) continue;
        if (listing.id != plugin.info.id) continue;
        if (listing.version > plugin.info.version) {
          updates.add((installed: plugin, upgrade: listing));
        }
      }
    }
    return updates;
  }

  Future<PluginVersion?> _versionOf(String artifactPath) async {
    final raw = await _artifacts.readEntry(artifactPath, 'plugin.json');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return PluginVersion.parse(decoded['version']);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  // ---- artifact acquisition ----------------------------------------------

  Future<Result<_Artifact>> _fetchArtifact(AvailablePlugin listed) async {
    switch (listed.ecosystem) {
      case PluginEcosystem.cloudstream:
        return _fetchCloudStream(listed);
      case PluginEcosystem.skystream:
        return _fetchSkyStream(listed);
      case PluginEcosystem.vega:
        return _fetchVega(listed);
    }
  }

  Future<Result<_Artifact>> _fetchCloudStream(AvailablePlugin listed) async {
    final uri = Uri.tryParse(listed.downloadUrl);
    if (uri == null) {
      return _artifactError(listed, 'Download URL is not valid');
    }
    final response = await _http.get(uri);
    if (response is Err<HttpPayload>) {
      return Err<_Artifact>(response.error.copyWithPlugin(listed.id));
    }
    final bytes = (response as Ok<HttpPayload>).value.bytes;
    var valid = _looksLikeDex(bytes);
    if (!valid && ZipUtils.looksLikeZip(bytes)) {
      // Extensions that ship Android resources are packaged CloudStream files:
      // a zip containing classes.dex, resources.arsc and compiled res/*. A
      // plain provider can still arrive as a raw DEX. cs3_engine accepts both,
      // so rejecting the packaged form here made real resource-bearing .cs3
      // extensions impossible to install even though the runtime supports them.
      final extracted = ZipUtils.extract(bytes);
      if (extracted is Err<Map<String, List<int>>>) {
        return Err<_Artifact>(extracted.error.copyWithPlugin(listed.id));
      }
      valid = _looksLikeDex(
        (extracted as Ok<Map<String, List<int>>>).value['classes.dex'],
      );
    }
    if (!valid) {
      return _artifactError(
        listed,
        'The downloaded .cs3 is neither a DEX nor a package with classes.dex',
      );
    }
    return Ok<_Artifact>(
      _Artifact(
        files: <String, List<int>>{'plugin.cs3': bytes},
        archive: bytes,
        info: _infoFromListing(listed),
      ),
    );
  }

  Future<Result<_Artifact>> _fetchSkyStream(AvailablePlugin listed) async {
    final uri = Uri.tryParse(listed.downloadUrl);
    if (uri == null) {
      return _artifactError(listed, 'Download URL is not valid');
    }
    final response = await _http.get(uri);
    if (response is Err<HttpPayload>) {
      return Err<_Artifact>(response.error.copyWithPlugin(listed.id));
    }
    final bytes = (response as Ok<HttpPayload>).value.bytes;

    // A .sky may arrive as a zip or, for a single-file plugin, as plain JS.
    if (!ZipUtils.looksLikeZip(bytes)) {
      final text = utf8.decode(bytes, allowMalformed: true);
      if (!text.contains('globalThis') && !text.contains('function')) {
        return _artifactError(listed, 'The .sky file is not a plugin package');
      }
      return Ok<_Artifact>(
        _Artifact(
          files: <String, List<int>>{
            'plugin.js': bytes.toList(growable: false),
            'plugin.json': utf8
                .encode(jsonEncode(_fallbackManifest(listed)))
                .toList(growable: false),
          },
          archive: bytes,
          info: _infoFromListing(listed),
        ),
      );
    }

    final extracted = ZipUtils.extract(bytes);
    if (extracted is Err<Map<String, List<int>>>) {
      return Err<_Artifact>(extracted.error.copyWithPlugin(listed.id));
    }
    final files = (extracted as Ok<Map<String, List<int>>>).value;

    final manifestBytes = files['plugin.json'];
    if (manifestBytes == null) {
      return _artifactError(
        listed,
        'The package has no plugin.json (SkyStream v2 requires one)',
      );
    }
    final manifest = ZipUtils.decodeManifest(manifestBytes);
    if (manifest == null) {
      return _artifactError(listed, 'plugin.json is not valid JSON');
    }
    final declared =
        readString(manifest['packageName']) ?? readString(manifest['id']);
    if (declared != null && declared != listed.id) {
      // The archive must be the plugin the repository listed: otherwise an
      // archive could take over another plugin's install slot.
      return _artifactError(
        listed,
        'The package is "$declared" but the repository listed "${listed.id}"',
      );
    }

    return Ok<_Artifact>(
      _Artifact(
        files: files,
        archive: bytes,
        info: _infoFromSkyManifest(manifest, listed),
      ),
    );
  }

  Future<Result<_Artifact>> _fetchVega(AvailablePlugin listed) async {
    final base = listed.downloadUrl.endsWith('/')
        ? listed.downloadUrl
        : '${listed.downloadUrl}/';
    final files = <String, List<int>>{};
    final errors = <String, Object>{};

    // Vega busts caches with the provider version and a timestamp, because
    // these files are served straight from raw.githubusercontent.com.
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final query = 'v=${Uri.encodeQueryComponent(listed.version.raw)}&t=$stamp';

    for (final module in vegaModules) {
      final uri = Uri.tryParse('$base$module?$query');
      if (uri == null) continue;
      final response = await _http.get(uri);
      switch (response) {
        case Ok<HttpPayload>(:final value):
          files[module] = value.bytes.toList(growable: false);
        case Err<HttpPayload>(:final error):
          errors[module] = error;
      }
    }

    final missing = requiredVegaModules
        .where((module) => !files.containsKey(module))
        .toList(growable: false);
    if (missing.isNotEmpty) {
      final because = missing
          .map((module) => '$module (${errors[module] ?? 'not found'})')
          .join(', ');
      return _artifactError(listed, 'The provider bundle is missing $because');
    }

    return Ok<_Artifact>(
      _Artifact(files: files, info: _infoFromListing(listed, vega: true)),
    );
  }

  static bool _looksLikeDex(List<int>? bytes) =>
      bytes != null &&
      bytes.length >= 4 &&
      bytes[0] == 0x64 &&
      bytes[1] == 0x65 &&
      bytes[2] == 0x78 &&
      bytes[3] == 0x0A;

  Result<_Artifact> _artifactError(AvailablePlugin listed, String message) =>
      Err<_Artifact>(
        PluginParseError(message, pluginId: listed.id, field: 'artifact'),
      );

  PluginInfo _infoFromListing(AvailablePlugin listed, {bool vega = false}) {
    final capabilities = switch (listed.ecosystem) {
      PluginEcosystem.cloudstream => PluginCapabilities.all,
      PluginEcosystem.skystream => const PluginCapabilities(
          home: true,
          search: true,
          details: true,
          episodes: true,
          streams: true,
          settings: true,
        ),
      PluginEcosystem.vega => const PluginCapabilities(
          home: true,
          search: true,
          details: true,
          streams: true,
          settings: true,
          catalogs: true,
        ),
    };

    return PluginInfo(
      id: listed.id,
      name: listed.name,
      ecosystem: listed.ecosystem,
      version: listed.version,
      description: listed.description,
      authors: listed.authors,
      language: listed.language,
      iconUrl: listed.iconUrl,
      supportedTypes: listed.supportedTypes,
      capabilities: capabilities,
      repositoryId: listed.repositoryId,
      sourceUrl: listed.downloadUrl,
      apiVersion: listed.apiVersion,
      settings: listed.settings
          .map((key) => PluginSetting(key: key, title: key))
          .toList(growable: false),
    );
  }

  /// Reads a SkyStream `plugin.json` into the unified [PluginInfo].
  PluginInfo _infoFromSkyManifest(
    Map<String, Object?> manifest,
    AvailablePlugin listed,
  ) {
    final id = readString(manifest['packageName']) ??
        readString(manifest['id']) ??
        listed.id;
    final types = readStringList(manifest['types']).isEmpty
        ? listed.supportedTypes
        : readStringList(manifest['types']).map(MediaType.fromWire).toSet();
    final languages = readStringList(manifest['languages']);

    return _infoFromListing(listed).copyWith(
      id: id,
      name: readString(manifest['name']) ?? listed.name,
      version: PluginVersion.parse(manifest['version']),
      description: readString(manifest['description']) ?? listed.description,
      authors: readStringList(manifest['authors']).isEmpty
          ? listed.authors
          : readStringList(manifest['authors']),
      language: languages.isEmpty ? listed.language : languages.first,
      supportedTypes: types,
      settings: _settingsFromManifest(manifest['settings']),
      endpoints: PluginEndpoint.parseAll(manifest),
    );
  }

  List<PluginSetting> _settingsFromManifest(Object? raw) {
    final settings = <PluginSetting>[];
    for (final entry in readMapList(raw)) {
      final key = readString(entry['key']) ?? readString(entry['name']);
      if (key == null) continue;
      settings.add(PluginSetting.fromJson(entry));
    }
    return settings;
  }

  Map<String, Object?> _fallbackManifest(AvailablePlugin listed) =>
      <String, Object?>{
        'packageName': listed.id,
        'name': listed.name,
        'version': listed.version.raw,
        if (listed.description != null) 'description': listed.description,
      };

  /// A version is used as a directory name, so it must be a safe segment.
  static String _versionSegment(PluginVersion version) {
    final raw = version.isNone ? '1' : version.raw;
    final sanitized = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    return sanitized.isEmpty ? '1' : sanitized;
  }
}

/// The bytes and manifest an install produced, before it is written.
final class _Artifact {
  const _Artifact({required this.files, required this.info, this.archive});

  final Map<String, List<int>> files;
  final PluginInfo info;
  final List<int>? archive;
}
