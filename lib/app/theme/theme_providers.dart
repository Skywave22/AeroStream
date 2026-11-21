import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Which of AeroStream's three palettes is active.
enum AppThemeVariant {
  system,
  light,
  dark,
  amoled;

  ThemeMode get mode => switch (this) {
        AppThemeVariant.system => ThemeMode.system,
        AppThemeVariant.light => ThemeMode.light,
        AppThemeVariant.dark || AppThemeVariant.amoled => ThemeMode.dark,
      };

  String get label => switch (this) {
        AppThemeVariant.system => 'Follow system',
        AppThemeVariant.light => 'Light',
        AppThemeVariant.dark => 'Dark',
        AppThemeVariant.amoled => 'AMOLED black',
      };
}

/// The chosen palette, persisted across launches.
final persistedThemeProvider =
    NotifierProvider<ThemeController, AppThemeVariant>(ThemeController.new);

class ThemeController extends Notifier<AppThemeVariant> {
  static const String _key = 'ui.themeVariant';

  @override
  AppThemeVariant build() {
    final raw = ref.read(settingsStoreProvider).getString(_key);
    return AppThemeVariant.values.firstWhere(
      (variant) => variant.name == raw,
      orElse: () => AppThemeVariant.system,
    );
  }

  Future<void> select(AppThemeVariant variant) async {
    state = variant;
    await ref.read(settingsStoreProvider).setString(_key, variant.name);
  }
}
