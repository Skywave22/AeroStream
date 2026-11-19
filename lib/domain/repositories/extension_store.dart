import '../../core/result.dart';
import '../entities/installed_plugin.dart';
import '../entities/plugin_repository.dart';

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

  Future<InstalledPlugin?> installedPlugin(String id);

  Future<void> upsertInstalledPlugin(InstalledPlugin plugin);

  Future<void> deleteInstalledPlugin(String id);

  /// Persists enable/disable and ordering without touching the artifact.
  Future<void> setEnabled(String id, {required bool enabled});

  Future<void> setPriority(String id, {required int priority});
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
abstract interface class ArtifactStore {
  /// Directory that holds every installed artifact.
  Future<String> pluginsRoot();

  /// Installs [bytes] as [id]@[version] and returns the artifact path.
  Future<Result<String>> install({
    required String id,
    required String version,
    required List<int> bytes,
    required ArtifactFormat format,
    String? expectedSha256,
  });

  /// Removes an installed artifact, bounding the delete to the plugin root.
  Future<void> remove(String artifactPath);

  /// Reads a small file out of an installed artifact (manifest lookup).
  Future<String?> readEntry(String artifactPath, String entryName);

  /// Lists the entries of an installed archive artifact.
  Future<List<String>> listEntries(String artifactPath);

  Future<int> totalSize();
}

/// How an ecosystem's artifact is stored on disk.
enum ArtifactFormat {
  /// `.sky`: a zip archive, extracted next to a copy of the original.
  skyArchive,

  /// Vega: a directory of `.js` modules + `manifest.json`.
  vegaBundle,

  /// `.cs3`: a single DEX file, loaded by the Android host.
  cs3File,
}
