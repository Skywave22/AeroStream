import 'dart:convert';
import 'dart:typed_data';

import 'package:aerostream/core/errors/plugin_error.dart';
import 'package:aerostream/core/network/http_service.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/installed_plugin.dart';
import 'package:aerostream/domain/entities/plugin_repository.dart';
import 'package:aerostream/domain/repositories/extension_store.dart';

/// An [HttpService] backed by a URL -> body map.
///
/// Hand-written rather than mocked: the fakes in this directory are shared by
/// several suites and must stay readable when a request goes wrong.
final class FakeHttpService implements HttpService {
  FakeHttpService([Map<String, Object>? routes]) : routes = routes ?? {};

  /// URL -> `String` (UTF-8 body), `List<int>` (binary body) or [PluginError].
  final Map<String, Object> routes;

  /// Every URL requested, in order, for assertions about traffic.
  final List<String> requested = <String>[];

  @override
  Future<Result<HttpPayload>> get(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    requested.add(url.toString());
    final body = routes[url.toString()];
    if (body == null) {
      return Err<HttpPayload>(
        PluginNetworkError(
          'Not found in fixture: $url',
          statusCode: 404,
          url: url.toString(),
        ),
      );
    }
    if (body is PluginError) return Err<HttpPayload>(body);
    final bytes = body is String ? utf8.encode(body) : body as List<int>;
    return Ok<HttpPayload>(
      HttpPayload(
        bytes: Uint8List.fromList(bytes),
        statusCode: 200,
        url: url.toString(),
      ),
    );
  }

  @override
  Future<Result<HttpPayload>> post(
    Uri url, {
    Object? body,
    Map<String, String>? headers,
  }) =>
      get(url, headers: headers);
}

/// In-memory [ExtensionStore].
final class InMemoryExtensionStore implements ExtensionStore {
  final Map<String, PluginRepository> _repositories =
      <String, PluginRepository>{};
  final Map<String, InstalledPlugin> _plugins = <String, InstalledPlugin>{};

  @override
  Future<List<PluginRepository>> repositories() async =>
      _repositories.values.toList(growable: false);

  @override
  Future<void> upsertRepository(PluginRepository repository) async {
    _repositories[repository.id] = repository;
  }

  @override
  Future<void> deleteRepository(String id) async {
    _repositories.remove(id);
  }

  @override
  Future<List<InstalledPlugin>> installedPlugins() async =>
      _plugins.values.toList(growable: false);

  @override
  Future<InstalledPlugin?> installedPlugin(String key) async => _plugins[key];

  @override
  Future<void> upsertInstalledPlugin(InstalledPlugin plugin) async {
    _plugins[plugin.key] = plugin;
  }

  @override
  Future<void> deleteInstalledPlugin(String key) async {
    _plugins.remove(key);
  }

  @override
  Future<void> setEnabled(String key, {required bool enabled}) async {
    final plugin = _plugins[key];
    if (plugin == null) return;
    _plugins[key] = plugin.copyWith(
      info: plugin.info.copyWith(enabled: enabled),
    );
  }

  @override
  Future<void> setPriority(String key, {required int priority}) async {
    final plugin = _plugins[key];
    if (plugin == null) return;
    _plugins[key] = plugin.copyWith(
      info: plugin.info.copyWith(priority: priority),
    );
  }
}

/// In-memory [ArtifactStore] that records what was written.
final class InMemoryArtifactStore implements ArtifactStore {
  final Map<String, Map<String, List<int>>> installed =
      <String, Map<String, List<int>>>{};
  final List<String> removed = <String>[];
  PluginError? failWith;

  @override
  Future<String> pluginsRoot() async => '/memory/plugins';

  @override
  Future<Result<String>> install({
    required PluginEcosystem ecosystem,
    required String id,
    required String version,
    required Map<String, List<int>> files,
    List<int>? originalArchive,
    String? expectedSha256,
  }) async {
    if (failWith != null) return Err<String>(failWith!);
    final path = '/memory/plugins/${ecosystem.name}/$id/$version';
    installed[path] = files;
    return Ok<String>(path);
  }

  @override
  Future<void> remove(String artifactPath) async {
    removed.add(artifactPath);
    installed.remove(artifactPath);
  }

  @override
  Future<String?> readEntry(String artifactPath, String entryName) async {
    final files = installed[artifactPath];
    final bytes = files?[entryName];
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<List<String>> listEntries(String artifactPath) async =>
      installed[artifactPath]?.keys.toList(growable: false) ?? const <String>[];

  @override
  Future<bool> exists(String artifactPath) async =>
      installed.containsKey(artifactPath);

  @override
  Future<int> totalSize() async => installed.values.fold<int>(
        0,
        (sum, files) => sum + files.values.fold<int>(0, (a, b) => a + b.length),
      );
}

/// In-memory [SettingsStore].
final class InMemorySettingsStore implements SettingsStore {
  final Map<String, String> values = <String, String>{};

  @override
  String? getString(String key) => values[key];

  @override
  bool getBool(String key, {bool fallback = false}) =>
      values[key] == null ? fallback : values[key] == 'true';

  @override
  int getInt(String key, {int fallback = 0}) =>
      int.tryParse(values[key] ?? '') ?? fallback;

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    values[key] = '$value';
  }

  @override
  Future<void> setInt(String key, {required int value}) async {
    values[key] = '$value';
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Map<String, String> entriesWithPrefix(String prefix) => <String, String>{
        for (final entry in values.entries)
          if (entry.key.startsWith(prefix)) entry.key: entry.value,
      };
}
