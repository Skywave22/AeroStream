import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../domain/entities/enums.dart';
import '../../domain/entities/installed_plugin.dart';
import '../../domain/entities/plugin_info.dart';
import '../../domain/entities/plugin_repository.dart';
import '../../domain/repositories/extension_store.dart';

/// SQLite-backed [ExtensionStore].
///
/// Schema is versioned with `PRAGMA user_version`; migrations run inside a
/// transaction so a half-applied upgrade cannot brick the install list. JSON
/// columns hold the maps the domain already knows how to serialise, which keeps
/// the schema stable as entities grow.
final class SqliteExtensionStore implements ExtensionStore {
  SqliteExtensionStore._(this._db) {
    _migrate();
  }

  factory SqliteExtensionStore.openInMemory() =>
      SqliteExtensionStore._(sqlite3.openInMemory());

  factory SqliteExtensionStore.openFile(String path) =>
      SqliteExtensionStore._(sqlite3.open(path));

  final Database _db;

  /// Current schema version. Bump it and add a branch in [_migrate].
  static const int schemaVersion = 1;

  int get _userVersion =>
      _db.select('PRAGMA user_version').first.values.first! as int;

  void _migrate() {
    if (_userVersion >= schemaVersion) return;
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('BEGIN');
    try {
      if (_userVersion < 1) {
        _db.execute('''
          CREATE TABLE repositories (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            url TEXT NOT NULL,
            ecosystem TEXT NOT NULL,
            description TEXT,
            icon_url TEXT,
            plugin_lists TEXT NOT NULL,
            included_repos TEXT NOT NULL,
            manifest_version INTEGER NOT NULL,
            added_at TEXT,
            last_checked_at TEXT,
            enabled INTEGER NOT NULL,
            is_built_in INTEGER NOT NULL
          )
        ''');
        _db.execute('''
          CREATE TABLE plugins (
            key TEXT PRIMARY KEY,
            id TEXT NOT NULL,
            ecosystem TEXT NOT NULL,
            name TEXT NOT NULL,
            version TEXT NOT NULL,
            payload TEXT NOT NULL,
            artifact_path TEXT NOT NULL,
            previous_artifact_path TEXT,
            repository_id TEXT,
            priority INTEGER NOT NULL,
            enabled INTEGER NOT NULL
          )
        ''');
        _db.execute(
          'CREATE INDEX plugins_priority ON plugins (priority, name)',
        );
      }
      _db.execute('PRAGMA user_version = $schemaVersion');
      _db.execute('COMMIT');
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ---- repositories -------------------------------------------------------

  @override
  Future<List<PluginRepository>> repositories() async {
    final rows = _db.select(
      'SELECT * FROM repositories ORDER BY is_built_in DESC, name COLLATE NOCASE',
    );
    return rows.map(_repositoryFromRow).toList(growable: false);
  }

  @override
  Future<void> upsertRepository(PluginRepository repository) async {
    _db.execute(
      '''
      INSERT INTO repositories (
        id, name, url, ecosystem, description, icon_url, plugin_lists,
        included_repos, manifest_version, added_at, last_checked_at, enabled,
        is_built_in
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        url = excluded.url,
        ecosystem = excluded.ecosystem,
        description = excluded.description,
        icon_url = excluded.icon_url,
        plugin_lists = excluded.plugin_lists,
        included_repos = excluded.included_repos,
        manifest_version = excluded.manifest_version,
        last_checked_at = excluded.last_checked_at,
        enabled = excluded.enabled,
        is_built_in = excluded.is_built_in
      ''',
      <Object?>[
        repository.id,
        repository.name,
        repository.url,
        repository.ecosystem.wire,
        repository.description,
        repository.iconUrl,
        jsonEncode(repository.pluginLists),
        jsonEncode(repository.includedRepos),
        repository.manifestVersion,
        repository.addedAt?.toIso8601String(),
        repository.lastCheckedAt?.toIso8601String(),
        repository.enabled ? 1 : 0,
        repository.isBuiltIn ? 1 : 0,
      ],
    );
  }

  @override
  Future<void> deleteRepository(String id) async {
    _db.execute('DELETE FROM repositories WHERE id = ?', <Object?>[id]);
  }

  PluginRepository _repositoryFromRow(Row row) {
    final addedAt = row['added_at'] as String?;
    final checkedAt = row['last_checked_at'] as String?;
    return PluginRepository(
      id: row['id'] as String,
      name: row['name'] as String,
      url: row['url'] as String,
      ecosystem: PluginEcosystem.fromWire(row['ecosystem']),
      description: row['description'] as String?,
      iconUrl: row['icon_url'] as String?,
      pluginLists: _decodeStringList(row['plugin_lists']),
      includedRepos: _decodeStringList(row['included_repos']),
      manifestVersion: row['manifest_version'] as int,
      addedAt: addedAt == null ? null : DateTime.tryParse(addedAt),
      lastCheckedAt: checkedAt == null ? null : DateTime.tryParse(checkedAt),
      enabled: (row['enabled'] as int) == 1,
      isBuiltIn: (row['is_built_in'] as int) == 1,
    );
  }

  // ---- installed plugins --------------------------------------------------

  @override
  Future<List<InstalledPlugin>> installedPlugins() async {
    final rows = _db.select(
      'SELECT * FROM plugins ORDER BY priority ASC, name COLLATE NOCASE',
    );
    return rows.map(_pluginFromRow).toList(growable: false);
  }

  @override
  Future<InstalledPlugin?> installedPlugin(String key) async {
    final rows = _db.select('SELECT * FROM plugins WHERE key = ?', <Object?>[
      key,
    ]);
    if (rows.isEmpty) return null;
    return _pluginFromRow(rows.first);
  }

  @override
  Future<void> upsertInstalledPlugin(InstalledPlugin plugin) async {
    final info = plugin.info;
    _db.execute(
      '''
      INSERT INTO plugins (
        key, id, ecosystem, name, version, payload, artifact_path,
        previous_artifact_path, repository_id, priority, enabled
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(key) DO UPDATE SET
        name = excluded.name,
        version = excluded.version,
        payload = excluded.payload,
        artifact_path = excluded.artifact_path,
        previous_artifact_path = excluded.previous_artifact_path,
        repository_id = excluded.repository_id,
        priority = excluded.priority,
        enabled = excluded.enabled
      ''',
      <Object?>[
        plugin.key,
        info.id,
        info.ecosystem.wire,
        info.name,
        info.version.raw,
        jsonEncode(info.toJson()),
        plugin.artifactPath,
        plugin.previousArtifactPath,
        info.repositoryId,
        info.priority,
        info.enabled ? 1 : 0,
      ],
    );
  }

  @override
  Future<void> deleteInstalledPlugin(String key) async {
    _db.execute('DELETE FROM plugins WHERE key = ?', <Object?>[key]);
  }

  @override
  Future<void> setEnabled(String key, {required bool enabled}) async {
    _db.execute('UPDATE plugins SET enabled = ? WHERE key = ?', <Object?>[
      enabled ? 1 : 0,
      key,
    ]);
  }

  @override
  Future<void> setPriority(String key, {required int priority}) async {
    _db.execute('UPDATE plugins SET priority = ? WHERE key = ?', <Object?>[
      priority,
      key,
    ]);
  }

  InstalledPlugin _pluginFromRow(Row row) {
    final payload = jsonDecode(row['payload'] as String);
    final info = PluginInfo.fromJson(
      payload is Map<String, Object?> ? payload : const <String, Object?>{},
    );
    return InstalledPlugin(
      info: info.copyWith(
        priority: row['priority'] as int,
        enabled: (row['enabled'] as int) == 1,
      ),
      artifactPath: row['artifact_path'] as String,
      previousArtifactPath: row['previous_artifact_path'] as String?,
    );
  }

  List<String> _decodeStringList(Object? raw) {
    if (raw is! String) return const <String>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    return decoded.map((entry) => entry.toString()).toList(growable: false);
  }

  /// Releases the database handle. Safe to call twice.
  void dispose() => _db.dispose();
}
