import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/repositories/extension_store.dart';

/// Settings over `shared_preferences`.
///
/// Reads are synchronous because the underlying store caches every key in
/// memory after [open]; writes are awaited so a crash cannot lose a preference
/// the user just changed.
final class PrefsSettingsStore implements SettingsStore {
  PrefsSettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<PrefsSettingsStore> open() async =>
      PrefsSettingsStore(await SharedPreferences.getInstance());

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  bool getBool(String key, {bool fallback = false}) =>
      _prefs.getBool(key) ?? fallback;

  @override
  int getInt(String key, {int fallback = 0}) => _prefs.getInt(key) ?? fallback;

  @override
  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<void> setBool(String key, {required bool value}) async {
    await _prefs.setBool(key, value);
  }

  @override
  Future<void> setInt(String key, {required int value}) async {
    await _prefs.setInt(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }

  @override
  Map<String, String> entriesWithPrefix(String prefix) {
    final result = <String, String>{};
    for (final key in _prefs.getKeys()) {
      if (!key.startsWith(prefix)) continue;
      final value = _prefs.getString(key);
      if (value != null) result[key] = value;
    }
    return result;
  }
}
