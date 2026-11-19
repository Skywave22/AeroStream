import 'package:aerostream/app/app.dart';
import 'package:aerostream/app/providers.dart';
import 'package:aerostream/core/platform/platform_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// The whole app, with every platform-backed store replaced.
///
/// This is a smoke test on purpose: it renders the real widget tree, the real
/// router and the real theme, and fails if the first run — the state every new
/// install starts in — throws, overflows or shows a blank screen.
void main() {
  testWidgets('first run explains itself instead of showing an empty feed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
          extensionStoreProvider.overrideWithValue(InMemoryExtensionStore()),
          artifactStoreProvider.overrideWithValue(InMemoryArtifactStore()),
          hostBootstrapProvider.overrideWithValue('/* bootstrap */'),
          platformProfileProvider.overrideWithValue(
            const PlatformProfile(target: TargetPlatform.android),
          ),
        ],
        child: const AeroStreamApp(),
      ),
    );

    // Let the install list resolve; nothing animates forever on this path.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('AeroStream'), findsOneWidget);
    expect(find.text('Nothing installed yet'), findsOneWidget);
    expect(find.text('Add a repository'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // The shell is a bottom bar at phone width, and every tab is reachable.
    expect(find.byType(NavigationBar), findsOneWidget);
    for (final label in const <String>[
      'Home',
      'Search',
      'Library',
      'Extensions',
      'Settings',
    ]) {
      expect(find.text(label), findsWidgets, reason: '$label is reachable');
    }
  });
}
