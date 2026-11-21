import '../../domain/repositories/extension_store.dart';

/// The plugin-owned half of the settings store.
///
/// Every value a plugin writes lands under `plugin.` — its namespace, the
/// mirror choice, the per-plugin option values — which makes "delete
/// everything the plugins know about me" a prefix operation rather than a
/// table of key patterns maintained by hand. Preferences, library and history
/// live outside that prefix and are untouched.
final class PluginDataStore {
  const PluginDataStore(this._settings);

  final SettingsStore _settings;

  /// The prefix every plugin-owned key starts with.
  static const String prefix = 'plugin.';

  /// Everything plugins have stored, for a "what will be deleted" count.
  Map<String, String> stored() => _settings.entriesWithPrefix(prefix);

  /// Deletes it all and reports how many values went.
  ///
  /// Credentials a plugin saved, cached tokens and mirror choices are all
  /// covered: plugins are expected to survive a lost session by asking again.
  Future<int> forgetAll() async {
    final keys = stored().keys.toList(growable: false);
    for (final key in keys) {
      await _settings.remove(key);
    }
    return keys.length;
  }
}
