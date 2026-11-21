import 'package:aerostream/app/providers.dart';
import 'package:aerostream/features/player/player_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  test('libVLC is the default internal player', () {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    expect(
      container.read(playerEngineChoiceProvider),
      PlayerEngineChoiceController.vlc,
    );
    expect(container.read(activePlayerEngineProvider).displayName, 'libVLC');
  });

  test('the mpv choice is persisted and restored', () async {
    final store = InMemorySettingsStore();
    final first = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );

    await first
        .read(playerEngineChoiceProvider.notifier)
        .set(PlayerEngineChoiceController.mpv);
    expect(first.read(playerEngineChoiceProvider), 'mpv');
    expect(store.values[PlayerEngineChoiceController.settingsKey], 'mpv');
    first.dispose();

    final restored = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(restored.dispose);
    expect(restored.read(playerEngineChoiceProvider), 'mpv');
    expect(restored.read(activePlayerEngineProvider).displayName, 'mpv');
  });

  test('an unknown stored player falls back to libVLC', () {
    final store = InMemorySettingsStore()
      ..values[PlayerEngineChoiceController.settingsKey] = 'browser';
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);

    expect(container.read(playerEngineChoiceProvider), 'vlc');
  });
}
