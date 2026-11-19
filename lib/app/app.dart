import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme/app_theme.dart';
import 'theme/theme_providers.dart';

/// The application widget: theme, routing, and nothing else.
class AeroStreamApp extends ConsumerWidget {
  const AeroStreamApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final variant = ref.watch(themeVariantProvider);
    return MaterialApp.router(
      title: 'AeroStream',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: variant == AppThemeVariant.amoled
          ? AppTheme.amoled()
          : AppTheme.dark(),
      themeMode: variant.mode,
      routerConfig: appRouter,
      builder: (context, child) {
        // Clamp text scaling to keep layouts intact on TV and small phones.
        final scale = MediaQuery.textScalerOf(context).clamp(
          minScaleFactor: 0.85,
          maxScaleFactor: 1.6,
        );
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scale),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
