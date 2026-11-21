import '../../core/result.dart';
import '../entities/enums.dart';
import '../entities/installed_plugin.dart';
import '../entities/plugin_repository.dart';

/// Composite identity for a plugin: the same manifest id can exist in two
/// ecosystems, and both installs must survive independently.
String pluginKey(PluginEcosystem ecosystem, String id) =>
    '${ecosystem.name}:$id';

/// Persistence contract for repositories and installed plugins.
///
/// The app layer depends on this, never on SQLite directly, so the whole
/// extension flow can be exercised in tests with an in-memory implementation.
abstract interface class ExtensionStore {
  // ---- repositories -------------------------------------------------------

  Future<List<PluginRepository>> repositories();

  Future<void> upsertRepository(PluginRepository repository);

  Future<void> deleteRepository(String id);

  // ---- installed plugins --------------------------------------------------

  Future<List<InstalledPlugin>> installedPlugins();

  /// Lookup by [pluginKey].
  Future<InstalledPlugin?> installedPlugin(String key);

  Future<void> upsertInstalledPlugin(InstalledPlugin plugin);

  /// Removes by [pluginKey].
  Future<void> deleteInstalledPlugin(String key);

  /// Persists enable/disable and ordering without touching the artifact.
  Future<void> setEnabled(String key, {required bool enabled});

  Future<void> setPriority(String key, {required int priority});
}

/// Key/value settings (app preferences, per-plugin option values, secrets
/// pointer). Implemented over `shared_preferences`; kept behind an interface so
/// tests do not need the platform channel.
abstract interface class SettingsStore {
  String? getString(String key);

  bool getBool(String key, {bool fallback = false});

  int getInt(String key, {int fallback = 0});

  Future<void> setString(String key, String value);

  Future<void> setBool(String key, {required bool value});

  Future<void> setInt(String key, {required int value});

  Future<void> remove(String key);

  /// All keys starting with [prefix], for per-plugin settings sections.
  Map<String, String> entriesWithPrefix(String prefix);
}

/// Storage for plugin artifacts on disk.
///
/// Every ecosystem ends up as a directory of files so the runtime has one shape
/// to load: a `.sky` archive is extracted, a Vega provider keeps its modules,
/// and a `.cs3` keeps its raw DEX or resource-bearing package intact. The
/// original artifact is retained for hash re-verification and exports.
abstract interface class ArtifactStore {
  /// Directory that holds every installed artifact.
  Future<String> pluginsRoot();

  /// Installs [files] (relative path -> bytes) as `<ecosystem>/<id>/<version>/`.
  ///
  /// The write is staged in a sibling directory and swapped in, so a failure
  /// never leaves the previous install destroyed. When [expectedSha256] is
  /// given it is checked against [originalArchive] (or the concatenation of
  /// [files] when there is no archive) before anything is swapped.
  Future<Result<String>> install({
    required PluginEcosystem ecosystem,
    required String id,
    required String version,
    required Map<String, List<int>> files,
    List<int>? originalArchive,
    String? expectedSha256,
  });

  /// Removes an installed artifact, bounded to the plugin root.
  Future<void> remove(String artifactPath);

  /// Reads a file out of an installed artifact (`plugin.json`, `posts.js`, …).
  Future<String?> readEntry(String artifactPath, String entryName);

  /// Lists the files of an installed artifact, relative to its root.
  Future<List<String>> listEntries(String artifactPath);

  /// Whether an artifact directory still exists and is non-empty.
  Future<bool> exists(String artifactPath);

  Future<int> totalSize();
}

/// How an ecosystem's artifact arrives on the wire.
enum ArtifactFormat {
  /// `.sky`: a zip archive.
  skyArchive,

  /// Vega: a directory of `.js` modules described by `manifest.json`.
  vegaBundle,

  /// `.cs3`: a raw DEX or a ZIP package containing `classes.dex`.
  cs3File,
}
