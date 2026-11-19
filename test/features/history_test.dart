import 'dart:convert';

import 'package:aerostream/app/providers.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/episode.dart';
import 'package:aerostream/domain/entities/media_item.dart';
import 'package:aerostream/features/library/history_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

MediaItem item({String id = 'p:1', String title = 'Night Train'}) => MediaItem(
      id: id,
      pluginId: 'p',
      title: title,
      type: MediaType.movie,
      url: 'https://example.test/$id',
    );

Episode episode({String id = 'e1', int number = 1}) =>
    Episode(id: id, url: 'https://example.test/$id', number: number);

/// A container whose only real dependency is an in-memory settings store.
({ProviderContainer container, InMemorySettingsStore store}) harness([
  InMemorySettingsStore? store,
]) {
  final settings = store ?? InMemorySettingsStore();
  final container = ProviderContainer(
    overrides: [settingsStoreProvider.overrideWithValue(settings)],
  );
  addTearDown(container.dispose);
  return (container: container, store: settings);
}

void main() {
  group('WatchHistoryEntry', () {
    test('progress is clamped and safe when the duration is unknown', () {
      final zero = WatchHistoryEntry(
        item: item(),
        position: const Duration(minutes: 5),
        duration: Duration.zero,
        updatedAt: DateTime(2026),
      );
      expect(zero.progress, 0);

      final over = WatchHistoryEntry(
        item: item(),
        position: const Duration(minutes: 90),
        duration: const Duration(minutes: 60),
        updatedAt: DateTime(2026),
      );
      expect(over.progress, 1.0);
    });

    test('resumable means started but not effectively finished', () {
      WatchHistoryEntry at(Duration position, Duration duration) =>
          WatchHistoryEntry(
            item: item(),
            position: position,
            duration: duration,
            updatedAt: DateTime(2026),
          );

      expect(at(Duration.zero, const Duration(minutes: 60)).isResumable, false);
      expect(
        at(const Duration(seconds: 10), const Duration(minutes: 60))
            .isResumable,
        false,
      );
      expect(
        at(const Duration(minutes: 20), const Duration(minutes: 60))
            .isResumable,
        true,
      );
      expect(
        at(const Duration(minutes: 59), const Duration(minutes: 60))
            .isResumable,
        false,
      );
    });

    test('round-trips through JSON, episode included', () {
      final entry = WatchHistoryEntry(
        item: item(),
        episode: episode(),
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 45),
        updatedAt: DateTime.utc(2026, 3, 4, 5, 6, 7),
      );
      final copy = WatchHistoryEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())) as Map<String, Object?>,
      );
      expect(copy.item.id, entry.item.id);
      expect(copy.episode?.id, 'e1');
      expect(copy.position, entry.position);
      expect(copy.duration, entry.duration);
      expect(copy.updatedAt, entry.updatedAt);

      final film = WatchHistoryEntry(
        item: item(),
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 2),
        updatedAt: DateTime(2026),
      );
      expect(
        WatchHistoryEntry.fromJson(
          jsonDecode(jsonEncode(film.toJson())) as Map<String, Object?>,
        ).episode,
        isNull,
      );
    });
  });

  group('HistoryController', () {
    test('records newest first and de-duplicates the same title', () async {
      final h = harness();
      final controller = h.container.read(historyProvider.notifier);
      final first = item(id: 'p:1');
      final second = item(id: 'p:2', title: 'Other');

      await controller.record(
        item: first,
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 50),
      );
      await controller.record(
        item: second,
        position: const Duration(minutes: 1),
        duration: const Duration(minutes: 50),
      );
      await controller.record(
        item: first,
        position: const Duration(minutes: 9),
        duration: const Duration(minutes: 50),
      );

      final state = h.container.read(historyProvider);
      expect(state.map((entry) => entry.item.id), ['p:1', 'p:2']);
      expect(state.first.position, const Duration(minutes: 9));
    });

    test('treats each episode as its own entry', () async {
      final h = harness();
      final controller = h.container.read(historyProvider.notifier);
      final show = item(id: 'p:show');

      await controller.record(
        item: show,
        episode: episode(id: 's1e1', number: 1),
        position: const Duration(minutes: 10),
        duration: const Duration(minutes: 40),
      );
      await controller.record(
        item: show,
        episode: episode(id: 's1e2', number: 2),
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 40),
      );

      final state = h.container.read(historyProvider);
      expect(state, hasLength(2));
      expect(
        controller.resumePosition(
          show,
          episode: episode(id: 's1e1', number: 1),
        ),
        const Duration(minutes: 10),
      );
      expect(controller.resumePosition(show), isNull);
    });

    test('offers a resume point only when it is worth resuming', () async {
      final h = harness();
      final controller = h.container.read(historyProvider.notifier);
      final film = item();

      await controller.record(
        item: film,
        position: const Duration(seconds: 3),
        duration: const Duration(minutes: 90),
      );
      expect(controller.resumePosition(film), isNull);

      await controller.record(
        item: film,
        position: const Duration(minutes: 30),
        duration: const Duration(minutes: 90),
      );
      expect(controller.resumePosition(film), const Duration(minutes: 30));

      await controller.record(
        item: film,
        position: const Duration(minutes: 89),
        duration: const Duration(minutes: 90),
      );
      expect(controller.resumePosition(film), isNull);
    });

    test('ignores a zero position rather than logging a false start', () async {
      final h = harness();
      final controller = h.container.read(historyProvider.notifier);
      await controller.record(
        item: item(),
        position: Duration.zero,
        duration: const Duration(minutes: 30),
      );
      expect(h.container.read(historyProvider), isEmpty);
    });

    test('persists, reloads and caps the list', () async {
      final h = harness();
      final controller = h.container.read(historyProvider.notifier);
      for (var i = 0; i < HistoryController.maxEntries + 5; i++) {
        await controller.record(
          item: item(id: 'p:$i', title: 'Title $i'),
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 30),
        );
      }
      expect(h.container.read(historyProvider), hasLength(100));
      expect(h.container.read(historyProvider).first.item.id, 'p:104');

      // A fresh container over the same store sees the same history.
      final reloaded = harness(h.store);
      expect(reloaded.container.read(historyProvider), hasLength(100));
      expect(
        reloaded.container.read(historyProvider).first.item.title,
        'Title 104',
      );
    });

    test('survives a corrupt payload instead of throwing', () {
      final store = InMemorySettingsStore()
        ..values[HistoryController.storageKey] = '{not json';
      final h = harness(store);
      expect(h.container.read(historyProvider), isEmpty);
    });

    test('remove and clear forget resume points', () async {
      final h = harness();
      final controller = h.container.read(historyProvider.notifier);
      await controller.record(
        item: item(id: 'p:1'),
        position: const Duration(minutes: 4),
        duration: const Duration(minutes: 40),
      );
      await controller.record(
        item: item(id: 'p:2'),
        position: const Duration(minutes: 4),
        duration: const Duration(minutes: 40),
      );

      await controller.remove(h.container.read(historyProvider).first);
      expect(h.container.read(historyProvider).single.item.id, 'p:1');

      await controller.clear();
      expect(h.container.read(historyProvider), isEmpty);
      expect(
        h.store.values[HistoryController.storageKey],
        isNotNull,
      );
    });

    test('continueWatching filters out finished and barely-started titles',
        () async {
      final h = harness();
      final controller = h.container.read(historyProvider.notifier);
      await controller.record(
        item: item(id: 'p:mid'),
        position: const Duration(minutes: 20),
        duration: const Duration(minutes: 60),
      );
      await controller.record(
        item: item(id: 'p:done'),
        position: const Duration(minutes: 60),
        duration: const Duration(minutes: 60),
      );

      final row = h.container.read(continueWatchingProvider);
      expect(row.map((entry) => entry.item.id), ['p:mid']);
    });
  });
}
