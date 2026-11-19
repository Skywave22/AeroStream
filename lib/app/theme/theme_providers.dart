import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The active palette.
///
/// Phase 10 replaces the default with the persisted setting; keeping the
/// provider here means the swap touches one write site.
final themeVariantProvider = StateProvider<AppThemeVariant>(
  (ref) => AppThemeVariant.system,
);
