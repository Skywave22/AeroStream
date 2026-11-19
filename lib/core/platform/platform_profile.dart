import 'package:flutter/foundation.dart';

import '../../domain/entities/enums.dart';

/// Where AeroStream is running, reduced to the facts the runtime needs.
///
/// Kept as a value object rather than sprinkling `Platform.isAndroid` through
/// the code, so platform decisions are testable (pass a fake) and the
/// support matrix lives in one place.
@immutable
final class PlatformProfile {
  const PlatformProfile({
    required this.target,
    this.operatingSystem = '',
    this.isWeb = false,
  });

  final TargetPlatform target;
  final String operatingSystem;
  final bool isWeb;

  /// The host as it actually is.
  static PlatformProfile get current => PlatformProfile(
        target: defaultTargetPlatform,
        operatingSystem: _detectOs(),
        isWeb: kIsWeb,
      );

  static String _detectOs() {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }

  bool get isAndroid => target == TargetPlatform.android && !isWeb;

  bool get isIOS => target == TargetPlatform.iOS && !isWeb;

  bool get isMobile => isAndroid || isIOS;

  bool get isDesktop =>
      !isWeb &&
      (target == TargetPlatform.macOS ||
          target == TargetPlatform.windows ||
          target == TargetPlatform.linux);

  /// Whether a plugin of [ecosystem] can execute here.
  ///
  /// CloudStream extensions are Kotlin compiled against the CloudStream
  /// library; only the Android host can load them (see docs/PLUGIN_SPEC.md).
  bool supports(PluginEcosystem ecosystem) => switch (ecosystem) {
        PluginEcosystem.cloudstream => isAndroid,
        PluginEcosystem.skystream => !isWeb,
        PluginEcosystem.vega => !isWeb,
      };

  /// Explanation shown next to a plugin that cannot run here.
  String? unsupportedReason(PluginEcosystem ecosystem) {
    if (supports(ecosystem)) return null;
    return switch (ecosystem) {
      PluginEcosystem.cloudstream =>
        'CloudStream extensions are Kotlin (.cs3) and need the Android runtime.',
      PluginEcosystem.skystream ||
      PluginEcosystem.vega =>
        'The JavaScript sandbox is not available on web.',
    };
  }
}
