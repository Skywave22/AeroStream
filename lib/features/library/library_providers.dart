import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/json/json_read.dart';
import '../../domain/entities/media_item.dart';

/// The saved library.
///
/// Stored as a JSON list in settings so entries survive plugin removal: an item
/// keeps its plugin id and snapshot metadata, and the details screen shows
/// "extension missing" instead of dropping the row.
final libraryProvider =
    NotifierProvider<LibraryController, List<MediaItem>>(LibraryController.new);

class LibraryController extends Notifier<List<MediaItem>> {
  static const String _key = 'library.items';

  @override
  List<MediaItem> build() => _load();

  List<MediaItem> _load() {
    final raw = ref.read(settingsStoreProvider).getString(_key);
    if (raw == null || raw.isEmpty) return const <MediaItem>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <MediaItem>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map(
            (entry) => MediaItem.fromJson(readMap(entry)),
          )
          .toList(growable: false);
    } on FormatException {
      return const <MediaItem>[];
    }
  }

  bool contains(String id) => state.any((item) => item.id == id);

  Future<void> toggle(MediaItem item) async {
    final saved = contains(item.id);
    state = saved
        ? state.where((entry) => entry.id != item.id).toList(growable: false)
        : <MediaItem>[item, ...state];
    await _persist();
  }

  Future<void> remove(String id) async {
    state = state.where((entry) => entry.id != id).toList(growable: false);
    await _persist();
  }

  Future<void> clear() async {
    state = const <MediaItem>[];
    await _persist();
  }

  Future<void> _persist() async {
    await ref.read(settingsStoreProvider).setString(
      _key,
      jsonEncode(state.map((item) => item.toJson()).toList(growable: false)),
    );
  }
}
