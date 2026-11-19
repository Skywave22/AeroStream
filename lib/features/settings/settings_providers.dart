import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';

/// Playback preferences that the rest of the app honours.
///
/// Kept in one immutable value so a screen can watch the whole thing and a
/// setter can change one field without the others drifting.
final class AppPreferences {
  const AppPreferences({
    this.preferredQuality = 'Auto',
    this.autoplayNext = true,
    this.preferHls = true,
  });

  /// `Auto`, `1080p`, `720p`, `480p` or `360p`.
  final String preferredQuality;

  /// Start the next episode when one finishes.
  final bool autoplayNext;

  /// Put adaptive HLS links ahead of progressive ones when a source offers
  /// both.
  final bool preferHls;

  AppPreferences copyWith({
    String? preferredQuality,
    bool? autoplayNext,
    bool? preferHls,
  }) =>
      AppPreferences(
        preferredQuality: preferredQuality ?? this.preferredQuality,
        autoplayNext: autoplayNext ?? this.autoplayNext,
        preferHls: preferHls ?? this.preferHls,
      );

  @override
  bool operator ==(Object other) =>
      other is AppPreferences &&
      other.preferredQuality == preferredQuality &&
      other.autoplayNext == autoplayNext &&
      other.preferHls == preferHls;

  @override
  int get hashCode => Object.hash(preferredQuality, autoplayNext, preferHls);
}

final preferencesProvider =
    NotifierProvider<PreferencesController, AppPreferences>(
  PreferencesController.new,
);

class PreferencesController extends Notifier<AppPreferences> {
  static const String qualityKey = 'playback.preferredQuality';
  static const String autoplayKey = 'playback.autoplayNext';
  static const String hlsKey = 'playback.preferHls';

  @override
  AppPreferences build() {
    final settings = ref.read(settingsStoreProvider);
    return AppPreferences(
      preferredQuality: settings.getString(qualityKey) ?? 'Auto',
      autoplayNext: settings.getBool(autoplayKey, fallback: true),
      preferHls: settings.getBool(hlsKey, fallback: true),
    );
  }

  Future<void> setQuality(String quality) async {
    state = state.copyWith(preferredQuality: quality);
    await ref.read(settingsStoreProvider).setString(qualityKey, quality);
  }

  Future<void> setAutoplayNext({required bool value}) async {
    state = state.copyWith(autoplayNext: value);
    await ref.read(settingsStoreProvider).setBool(autoplayKey, value: value);
  }

  Future<void> setPreferHls({required bool value}) async {
    state = state.copyWith(preferHls: value);
    await ref.read(settingsStoreProvider).setBool(hlsKey, value: value);
  }
}
