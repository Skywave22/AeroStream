import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import 'media_kit_engine.dart';
import 'playback_engine.dart';
import 'vlc_engine.dart';

/// The libVLC engine. Constructed lazily; each surface owns its real player.
final vlcEngineProvider = Provider<PlaybackEngine>((ref) {
  final engine = VlcPlaybackEngine();
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

/// The mpv engine (`media_kit`). Constructed lazily as above.
final mediaKitEngineProvider = Provider<PlaybackEngine>((ref) {
  final engine = MediaKitPlaybackEngine();
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

/// Which internal engine the user picked: `vlc` (the default) or `mpv`.
///
/// Persisted through the settings store so the choice survives relaunches.
final playerEngineChoiceProvider =
    NotifierProvider<PlayerEngineChoiceController, String>(
  PlayerEngineChoiceController.new,
);

final class PlayerEngineChoiceController extends Notifier<String> {
  static const String settingsKey = 'playback.engine';
  static const String vlc = 'vlc';
  static const String mpv = 'mpv';

  @override
  String build() {
    final stored = ref.read(settingsStoreProvider).getString(settingsKey);
    return stored == mpv ? mpv : vlc;
  }

  Future<void> set(String choice) async {
    final normalized = choice == mpv ? mpv : vlc;
    if (state == normalized) return;
    state = normalized;
    await ref.read(settingsStoreProvider).setString(settingsKey, normalized);
  }
}

/// The engine that will render the selected source right now.
final activePlayerEngineProvider = Provider<PlaybackEngine>((ref) {
  final choice = ref.watch(playerEngineChoiceProvider);
  if (choice == PlayerEngineChoiceController.mpv) {
    return ref.watch(mediaKitEngineProvider);
  }
  return ref.watch(vlcEngineProvider);
});
