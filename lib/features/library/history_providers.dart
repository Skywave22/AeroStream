import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/json/json_read.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/media_item.dart';

/// One thing the user has watched, and how far they got.
///
/// The item is stored as a snapshot rather than a reference: history must
/// survive an uninstall, and "you were 34 minutes into this" is still true even
/// when the plugin that provided it is gone.
final class WatchHistoryEntry {
  const WatchHistoryEntry({
    required this.item,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.episode,
  });

  final MediaItem item;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;
  final Episode? episode;

  /// Where the user got to, 0..1.
  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    final ratio = position.inMilliseconds / duration.inMilliseconds;
    return ratio.clamp(0.0, 1.0);
  }

  /// Finished means "do not offer to resume"; the last 5% is credits.
  bool get isFinished => progress >= 0.95;

  /// Worth showing in "Continue watching": started, and not finished.
  bool get isResumable => progress >= 0.02 && !isFinished;

  /// Identity for de-duplication: an episode is its own entry.
  String get key => '${item.id}#${episode?.id ?? ''}';

  WatchHistoryEntry copyWith({
    Duration? position,
    Duration? duration,
    DateTime? updatedAt,
  }) => WatchHistoryEntry(
    item: item,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    updatedAt: updatedAt ?? this.updatedAt,
    episode: episode,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'item': item.toJson(),
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
    'updatedAt': updatedAt.toIso8601String(),
    if (episode != null) 'episode': episode!.toJson(),
  };

  factory WatchHistoryEntry.fromJson(Map<String, Object?> json) {
    final episodeJson = json['episode'];
    return WatchHistoryEntry(
      item: MediaItem.fromJson(readMap(json['item'])),
      position: Duration(milliseconds: readInt(json['positionMs']) ?? 0),
      duration: Duration(milliseconds: readInt(json['durationMs']) ?? 0),
      updatedAt:
          readDate(json['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      episode: episodeJson is Map
          ? Episode.fromJson(readMap(episodeJson))
          : null,
    );
  }
}

/// Watch history, newest first.
final historyProvider = NotifierProvider<HistoryController, List<WatchHistoryEntry>>(
  HistoryController.new,
);

class HistoryController extends Notifier<List<WatchHistoryEntry>> {
  static const String storageKey = 'history.entries';

  /// Long enough to cover a series, short enough to stay a settings value.
  static const int maxEntries = 100;

  @override
  List<WatchHistoryEntry> build() => _load();

  List<WatchHistoryEntry> _load() {
    final raw = ref.read(settingsStoreProvider).getString(storageKey);
    if (raw == null || raw.isEmpty) return const <WatchHistoryEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <WatchHistoryEntry>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map((entry) => WatchHistoryEntry.fromJson(readMap(entry)))
          .toList(growable: false);
    } on FormatException {
      return const <WatchHistoryEntry>[];
    }
  }

  /// The saved position for an item (and episode, when episodic).
  WatchHistoryEntry? entryFor(MediaItem item, {Episode? episode}) {
    final key = '${item.id}#${episode?.id ?? ''}';
    for (final entry in state) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  /// Where playback should start, if anywhere.
  Duration? resumePosition(MediaItem item, {Episode? episode}) {
    final entry = entryFor(item, episode: episode);
    if (entry == null || !entry.isResumable) return null;
    return entry.position;
  }

  /// Records progress. Called several times during playback, so it must stay
  /// cheap and must never throw into the player.
  Future<void> record({
    required MediaItem item,
    Episode? episode,
    required Duration position,
    required Duration duration,
  }) async {
    if (position <= Duration.zero) return;
    final entry = WatchHistoryEntry(
      item: item,
      episode: episode,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    final updated = <WatchHistoryEntry>[
      entry,
      ...state.where((existing) => existing.key != entry.key),
    ];
    state = List<WatchHistoryEntry>.unmodifiable(
      updated.take(maxEntries).toList(growable: false),
    );
    await _persist();
  }

  Future<void> remove(WatchHistoryEntry entry) async {
    state = state
        .where((existing) => existing.key != entry.key)
        .toList(growable: false);
    await _persist();
  }

  Future<void> clear() async {
    state = const <WatchHistoryEntry>[];
    await _persist();
  }

  Future<void> _persist() async {
    await ref
        .read(settingsStoreProvider)
        .setString(
          storageKey,
          jsonEncode(
            state.map((entry) => entry.toJson()).toList(growable: false),
          ),
        );
  }
}

/// The "continue watching" shortlist: resumable entries, newest first.
final continueWatchingProvider = Provider<List<WatchHistoryEntry>>((ref) {
  final history = ref.watch(historyProvider);
  return history.where((entry) => entry.isResumable).toList(growable: false);
});
