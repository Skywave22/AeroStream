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

  bool get isSupportedNativeTarget => isMobile || isDesktop;

  /// Whether a plugin of [ecosystem] can execute on this class of platform.
  ///
  /// Native CloudStream hosts differ internally — Android DEX, desktop JVM
  /// sidecar, iOS OpenJDK Zero — but expose one protocol on every native target.
  /// Whether the packaged host actually starts is checked separately by its
  /// handshake; this method only excludes the unsupported web target.
  bool supports(PluginEcosystem ecosystem) => isSupportedNativeTarget;

  /// Explanation shown next to a plugin that cannot run here.
  String? unsupportedReason(PluginEcosystem ecosystem) {
    if (supports(ecosystem)) return null;
    if (!isWeb) return 'This operating system is not a supported target.';
    return switch (ecosystem) {
      PluginEcosystem.cloudstream =>
        'The cross-platform CloudStream engine is not available on web.',
      PluginEcosystem.skystream ||
      PluginEcosystem.vega =>
        'The JavaScript sandbox is not available on web.',
    };
  }
}
