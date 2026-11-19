import 'package:aerostream/core/platform/ecosystem_status.dart';
import 'package:aerostream/core/platform/platform_profile.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

PlatformProfile _profile(TargetPlatform target, {bool web = false}) =>
    PlatformProfile(
      target: target,
      operatingSystem: web ? 'web' : target.name,
      isWeb: web,
    );

EcosystemStatus _for(
  PluginEcosystem ecosystem,
  PlatformProfile platform, {
  required bool host,
}) =>
    ecosystemStatus(
      ecosystem,
      platform: platform,
      cloudStreamHost: host,
    );

void main() {
  group('Android', () {
    test('runs all three ecosystems when the native host answers', () {
      final statuses = ecosystemStatuses(
        platform: _profile(TargetPlatform.android),
        cloudStreamHost: true,
      );

      expect(statuses, hasLength(PluginEcosystem.values.length));
      expect(statuses.every((status) => status.runs), isTrue);
      expect(statuses.every((status) => status.reason == null), isTrue);
    });

    test('admits when the CloudStream host is missing from the build', () {
      final cloudstream = _for(
        PluginEcosystem.cloudstream,
        _profile(TargetPlatform.android),
        host: false,
      );

      expect(cloudstream.runs, isFalse);
      expect(cloudstream.reason, contains('not part of this build'));
      // Installed-but-unstartable is the honest state, so the reason says so.
      expect(cloudstream.reason, contains('installed'));
    });
  });

  group('desktop', () {
    for (final target in <TargetPlatform>[
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    ]) {
      test('${target.name} runs the JavaScript ecosystems only', () {
        final platform = _profile(target);

        expect(
          _for(PluginEcosystem.skystream, platform, host: false).runs,
          isTrue,
        );
        expect(_for(PluginEcosystem.vega, platform, host: false).runs, isTrue);

        final cloudstream =
            _for(PluginEcosystem.cloudstream, platform, host: false);
        expect(cloudstream.runs, isFalse);
        expect(cloudstream.reason, contains('Android only'));
      });
    }

    test('iOS is the same story', () {
      final cloudstream = _for(
        PluginEcosystem.cloudstream,
        _profile(TargetPlatform.iOS),
        host: false,
      );

      expect(cloudstream.runs, isFalse);
      expect(cloudstream.reason, contains('Android only'));
    });
  });

  group('web', () {
    test('no ecosystem runs, and each says why', () {
      final statuses = ecosystemStatuses(
        platform: _profile(TargetPlatform.android, web: true),
        cloudStreamHost: false,
      );

      for (final status in statuses) {
        expect(status.runs, isFalse, reason: status.label);
        expect(status.reason, isNotNull, reason: status.label);
      }
      expect(
        _for(
          PluginEcosystem.skystream,
          _profile(TargetPlatform.android, web: true),
          host: false,
        ).reason,
        contains('JavaScript sandbox'),
      );
    });
  });

  test('a runnable status never carries a reason', () {
    // Built at runtime: as a constant, the assertion would fire at compile time.
    expect(
      () => EcosystemStatus(
        ecosystem: PluginEcosystem.vega,
        runs: true,
        reason: 'contradiction',
      ),
      throwsAssertionError,
    );
  });
}
