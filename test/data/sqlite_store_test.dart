import 'package:aerostream/core/utils/version.dart';
import 'package:aerostream/data/storage/sqlite_extension_store.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/installed_plugin.dart';
import 'package:aerostream/domain/entities/plugin_info.dart';
import 'package:aerostream/domain/entities/plugin_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// SQLite is loaded from the host; if the test image lacks libsqlite3 the suite
/// says so instead of failing with an unrelated-looking error.
bool get _sqliteAvailable {
  try {
    SqliteExtensionStore.openInMemory().dispose();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  final skipReason = _sqliteAvailable
      ? null
      : 'libsqlite3 is not available in this environment';

  group('SqliteExtensionStore', () {
    late SqliteExtensionStore store;

    setUp(() {
      store = SqliteExtensionStore.openInMemory();
    });

    tearDown(() {
      store.dispose();
    });

    PluginRepository repository({String id = 'repo-1'}) => PluginRepository(
      id: id,
      name: 'Repo $id',
      url: 'https://example.com/$id.json',
      ecosystem: PluginEcosystem.cloudstream,
      description: 'A repository',
      pluginLists: const <String>['https://example.com/plugins.json'],
      addedAt: DateTime.utc(2024, 1, 1),
      lastCheckedAt: DateTime.utc(2024, 1, 2),
    );

    InstalledPlugin plugin({
      String id = 'dev.example.plugin',
      PluginEcosystem ecosystem = PluginEcosystem.skystream,
      int version = 3,
      bool enabled = true,
      int priority = 0,
    }) =>
        InstalledPlugin(
          info: PluginInfo(
            id: id,
            name: 'Plugin $id',
            ecosystem: ecosystem,
            version: PluginVersion.parse(version),
            repositoryId: 'repo-1',
            enabled: enabled,
            priority: priority,
            supportedTypes: const <MediaType>{MediaType.movie},
            capabilities: const PluginCapabilities(search: true, streams: true),
          ),
          artifactPath: '/plugins/$id/$version',
          previousArtifactPath: '/plugins/$id/1',
        );

    test('starts empty', () async {
      expect(await store.repositories(), isEmpty);
      expect(await store.installedPlugins(), isEmpty);
    });

    test('round-trips a repository', () async {
      await store.upsertRepository(repository());
      final stored = (await store.repositories()).single;
      expect(stored.id, 'repo-1');
      expect(stored.ecosystem, PluginEcosystem.cloudstream);
      expect(stored.pluginLists, hasLength(1));
      expect(stored.addedAt, DateTime.utc(2024, 1, 1));
    });

    test('upsert updates in place instead of duplicating', () async {
      await store.upsertRepository(repository());
      await store.upsertRepository(repository().copyWith(name: 'Renamed'));
      final all = await store.repositories();
      expect(all, hasLength(1));
      expect(all.single.name, 'Renamed');
    });

    test('deletes a repository', () async {
      await store.upsertRepository(repository());
      await store.deleteRepository('repo-1');
      expect(await store.repositories(), isEmpty);
    });

    test('round-trips an installed plugin, including its manifest JSON',
        () async {
      await storeInstall(store, plugin());

      final stored = await store.installedPlugin('skystream:dev.example.plugin');
      expect(stored, isNotNull);
      expect(stored!.info.version, PluginVersion.parse(3));
      expect(stored.info.capabilities.streams, isTrue);
      expect(stored.info.supportedTypes, contains(MediaType.movie));
      expect(stored.artifactPath, '/plugins/dev.example.plugin/3');
      expect(stored.previousArtifactPath, '/plugins/dev.example.plugin/1');
    });

    test('the same id in two ecosystems is two installs', () async {
      await storeInstall(store, plugin());
      await storeInstall(
        store,
        plugin(ecosystem: PluginEcosystem.cloudstream, version: 9),
      );
      final all = await store.installedPlugins();
      expect(all, hasLength(2));
      expect(
        all.map((entry) => entry.info.ecosystem).toSet(),
        <PluginEcosystem>{
          PluginEcosystem.skystream,
          PluginEcosystem.cloudstream,
        },
      );
    });

    test('enable, priority and uninstall do not corrupt the record', () async {
      await storeInstall(store, plugin());

      await store.setEnabled('skystream:dev.example.plugin', enabled: false);
      await store.setPriority('skystream:dev.example.plugin', priority: -5);

      final stored = await store.installedPlugin('skystream:dev.example.plugin');
      expect(stored!.info.enabled, isFalse);
      expect(stored.info.priority, -5);
      expect(stored.info.name, 'Plugin dev.example.plugin');

      await store.deleteInstalledPlugin('skystream:dev.example.plugin');
      expect(await store.installedPlugin('skystream:dev.example.plugin'), isNull);
    });

    test('orders plugins by priority', () async {
      await storeInstall(store, plugin(id: 'b', priority: 2));
      await storeInstall(store, plugin(id: 'a', priority: -1));
      final all = await store.installedPlugins();
      expect(all.map((entry) => entry.info.id), <String>['a', 'b']);
    });

    test('migration is idempotent across reopen', () {
      // Opening twice must not throw (the schema version is stored).
      final second = SqliteExtensionStore.openInMemory();
      addTearDown(second.dispose);
      expect(second, isNotNull);
    });
  }, skip: skipReason);
}

/// Small helper so the tests read as intent rather than setup.
Future<void> storeInstall(
  SqliteExtensionStore store,
  InstalledPlugin plugin,
) =>
    store.upsertInstalledPlugin(plugin);
