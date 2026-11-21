import 'dart:io';

import 'package:aerostream/core/app_info.dart';
import 'package:flutter_test/flutter_test.dart';

/// The UI must not advertise a version the build does not have.
///
/// `pubspec.yaml` is what pub, the store and `--build-name` read; `app_info.dart`
/// is what the About tile shows. This test is the only thing keeping the two
/// from drifting apart after a release bump.
void main() {
  test('app_info matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*(\d[\w.]*)\+(\d+)\s*$', multiLine: true)
        .firstMatch(pubspec);

    expect(match, isNotNull, reason: 'pubspec.yaml has no version: line');
    expect(match!.group(1), appVersion);
    expect(int.parse(match.group(2)!), appBuildNumber);
  });

  test('the About label carries both numbers', () {
    expect(appVersionLabel, '$appVersion ($appBuildNumber)');
  });
}
