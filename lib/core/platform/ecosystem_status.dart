import '../../domain/entities/enums.dart';
import 'platform_profile.dart';

/// Whether one ecosystem can run on this device, and why not when it cannot.
///
/// The support matrix is a product statement, so it lives in one testable place
/// instead of being re-derived in each screen. CloudStream uses different
/// native hosts on Android, iOS and desktop, but all must answer the same engine
/// handshake before the UI calls the ecosystem runnable.
final class EcosystemStatus {
  const EcosystemStatus({
    required this.ecosystem,
    required this.runs,
    this.reason,
  }) : assert(
          runs == (reason == null),
          'a runnable ecosystem has no reason, an unrunnable one needs one',
        );

  final PluginEcosystem ecosystem;
  final bool runs;

  /// One sentence for the UI; null when [runs].
  final String? reason;

  String get label => ecosystem.label;

  @override
  String toString() =>
      'EcosystemStatus(${ecosystem.wire}, ${runs ? 'runs' : reason})';
}

/// The truth table for this device.
///
/// [cloudStreamHost] is the result of the cs3 engine's `hello` call, not a
/// platform guess. It can be false if native packaging is incomplete, desktop
/// Java cannot start, or the embedded host itself fails.
List<EcosystemStatus> ecosystemStatuses({
  required PlatformProfile platform,
  required bool cloudStreamHost,
}) {
  return <EcosystemStatus>[
    for (final ecosystem in PluginEcosystem.values)
      _statusFor(
        ecosystem,
        platform: platform,
        cloudStreamHost: cloudStreamHost,
      ),
  ];
}

EcosystemStatus _statusFor(
  PluginEcosystem ecosystem, {
  required PlatformProfile platform,
  required bool cloudStreamHost,
}) {
  if (platform.isWeb) {
    return EcosystemStatus(
      ecosystem: ecosystem,
      runs: false,
      reason: ecosystem == PluginEcosystem.cloudstream
          ? 'The CloudStream engine is available in native Android, iOS, '
              'macOS, Windows and Linux builds, not on the web'
          : '${ecosystem.label} plugins run in a JavaScript sandbox, which '
              'this build does not have on the web',
    );
  }

  if (!platform.isSupportedNativeTarget) {
    return EcosystemStatus(
      ecosystem: ecosystem,
      runs: false,
      reason: 'This operating system is not a supported AeroStream target',
    );
  }

  switch (ecosystem) {
    case PluginEcosystem.cloudstream:
      if (!cloudStreamHost) {
        return const EcosystemStatus(
          ecosystem: PluginEcosystem.cloudstream,
          runs: false,
          reason: 'The cross-platform CloudStream engine did not start in '
              'this build; check diagnostics for its native host error',
        );
      }
      return const EcosystemStatus(
        ecosystem: PluginEcosystem.cloudstream,
        runs: true,
      );
    case PluginEcosystem.skystream:
    case PluginEcosystem.vega:
      return EcosystemStatus(ecosystem: ecosystem, runs: true);
  }
}

/// The status for one ecosystem, from the same table.
EcosystemStatus ecosystemStatus(
  PluginEcosystem ecosystem, {
  required PlatformProfile platform,
  required bool cloudStreamHost,
}) =>
    _statusFor(ecosystem, platform: platform, cloudStreamHost: cloudStreamHost);
