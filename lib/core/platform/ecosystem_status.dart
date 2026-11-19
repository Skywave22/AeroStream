import '../../domain/entities/enums.dart';
import 'platform_profile.dart';

/// Whether one ecosystem can run on this device, and why not when it cannot.
///
/// The support matrix is a *product* statement, so it lives in one testable
/// place instead of being re-derived in each screen. It is also why the
/// CloudStream row is more than "are we on Android": Android alone is not
/// enough, because `.cs3` extensions need the native host that only some builds
/// ship, and a build without it must say so rather than failing on playback.
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
/// [cloudStreamHost] is the handshake result from the native host, not a guess
/// from the platform name: `false` on every non-Android build, and `false` on
/// an Android build whose host did not answer.
List<EcosystemStatus> ecosystemStatuses({
  required PlatformProfile platform,
  required bool cloudStreamHost,
}) {
  return <EcosystemStatus>[
    for (final ecosystem in PluginEcosystem.values)
      _statusFor(ecosystem, platform: platform, cloudStreamHost: cloudStreamHost),
  ];
}

EcosystemStatus _statusFor(
  PluginEcosystem ecosystem, {
  required PlatformProfile platform,
  required bool cloudStreamHost,
}) {
  switch (ecosystem) {
    case PluginEcosystem.cloudstream:
      if (!platform.isAndroid) {
        return const EcosystemStatus(
          ecosystem: PluginEcosystem.cloudstream,
          runs: false,
          reason: 'Android only: .cs3 extensions are Kotlin, loaded by the '
              'Android host',
        );
      }
      if (!cloudStreamHost) {
        return const EcosystemStatus(
          ecosystem: PluginEcosystem.cloudstream,
          runs: false,
          reason: 'The CloudStream host is not part of this build, so .cs3 '
              'extensions can be installed but not started',
        );
      }
      return const EcosystemStatus(
        ecosystem: PluginEcosystem.cloudstream,
        runs: true,
      );
    case PluginEcosystem.skystream:
    case PluginEcosystem.vega:
      if (platform.isWeb) {
        return EcosystemStatus(
          ecosystem: ecosystem,
          runs: false,
          reason: '${ecosystem.label} plugins run in a JavaScript sandbox, '
              'which this build does not have on the web',
        );
      }
      return EcosystemStatus(ecosystem: ecosystem, runs: true);
  }
}

/// The status for one ecosystem, from the same table.
EcosystemStatus ecosystemStatus(
  PluginEcosystem ecosystem, {
  required PlatformProfile platform,
  required bool cloudStreamHost,
}) => _statusFor(
  ecosystem,
  platform: platform,
  cloudStreamHost: cloudStreamHost,
);
