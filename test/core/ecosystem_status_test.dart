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
    ecosystemStatus(ecosystem, platform: platform, cloudStreamHost: host);

void main() {
  for (final target in <TargetPlatform>[
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    group(target.name, () {
      test('runs all ecosystems when the cs3 engine answers', () {
        final statuses = ecosystemStatuses(
          platform: _profile(target),
          cloudStreamHost: true,
        );

        expect(statuses, hasLength(PluginEcosystem.values.length));
        expect(statuses.every((status) => status.runs), isTrue);
        expect(statuses.every((status) => status.reason == null), isTrue);
      });

      test(
        'reports an engine startup failure without an Android-only claim',
        () {
          final cloudstream = _for(
            PluginEcosystem.cloudstream,
            _profile(target),
            host: false,
          );

          expect(cloudstream.runs, isFalse);
          expect(cloudstream.reason, contains('did not start'));
          expect(cloudstream.reason, isNot(contains('Android only')));
          expect(
            _for(PluginEcosystem.skystream, _profile(target), host: false).runs,
            isTrue,
          );
        },
      );
    });
  }

  group('web', () {
    test('no ecosystem runs, and each says why', () {
      final statuses = ecosystemStatuses(
        platform: _profile(TargetPlatform.android, web: true),
        cloudStreamHost: true,
      );

      for (final status in statuses) {
        expect(status.runs, isFalse, reason: status.label);
        expect(status.reason, isNotNull, reason: status.label);
      }
      expect(
        _for(
          PluginEcosystem.cloudstream,
          _profile(TargetPlatform.android, web: true),
          host: true,
        ).reason,
        contains('not on the web'),
      );
    });
  });

  test('a runnable status never carries a reason', () {
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
