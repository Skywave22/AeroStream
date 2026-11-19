import '../../domain/entities/plugin_info.dart';
import '../../domain/repositories/extension_store.dart';

/// Remembers which mirror or sub-provider a user picked for a plugin.
///
/// One value per plugin, stored as `<pluginId>.<endpointId>` under
/// `plugin.endpoint.`: a setting the user made, not a property of the install,
/// so it survives updates and is removed with the plugin.
final class PluginEndpointStore {
  const PluginEndpointStore(this._settings);

  final SettingsStore _settings;

  static String keyFor(String pluginId) => 'plugin.endpoint.$pluginId';

  /// The chosen endpoint, or null when the plugin runs on its manifest default.
  PluginEndpoint? selected(PluginInfo info) {
    final id = _settings.getString(keyFor(info.id));
    if (id == null || id.isEmpty) return null;
    for (final endpoint in info.endpoints) {
      if (endpoint.id == id) return endpoint;
    }
    // A mirror that disappeared from a new version of the plugin is not an
    // error: the manifest default is still correct.
    return null;
  }

  /// The manifest a plugin should actually see: its own, overlaid with whatever
  /// the chosen endpoint needs (`baseUrl`, `providerId`).
  Map<String, Object?> manifestFor(
    PluginInfo info,
    Map<String, Object?> manifest,
  ) {
    final endpoint = selected(info);
    if (endpoint == null) return manifest;
    return <String, Object?>{...manifest, ...endpoint.manifestOverrides};
  }

  Future<void> select(String pluginId, PluginEndpoint? endpoint) async {
    if (endpoint == null) {
      await _settings.remove(keyFor(pluginId));
      return;
    }
    await _settings.setString(keyFor(pluginId), endpoint.id);
  }

  Future<void> forget(String pluginId) => _settings.remove(keyFor(pluginId));
}
