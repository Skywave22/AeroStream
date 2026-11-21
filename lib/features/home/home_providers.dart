import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/home_section.dart';
import '../../domain/entities/plugin_info.dart';
import '../../domain/services/catalog_service.dart';

/// Persistent choice of which enabled providers may contribute Home rows.
///
/// Missing settings mean "all", preserving the original aggregated feed and
/// automatically including providers installed later. An explicit empty set is
/// different: it intentionally leaves Home with no provider rows.
final class HomeProviderSelection {
  HomeProviderSelection._({required this.isAll, required Set<String> keys})
      : keys = UnmodifiableSetView<String>(keys);

  factory HomeProviderSelection.all() =>
      HomeProviderSelection._(isAll: true, keys: <String>{});

  factory HomeProviderSelection.only(Iterable<String> keys) =>
      HomeProviderSelection._(isAll: false, keys: keys.toSet());

  final bool isAll;
  final Set<String> keys;

  bool includes(String key) => isAll || keys.contains(key);

  @override
  bool operator ==(Object other) =>
      other is HomeProviderSelection &&
      other.isAll == isAll &&
      other.keys.length == keys.length &&
      other.keys.containsAll(keys);

  @override
  int get hashCode {
    final sorted = keys.toList()..sort();
    return Object.hash(isAll, Object.hashAll(sorted));
  }
}

/// Stable identity for Home selection. Plugin ids can collide across
/// ecosystems, so the ecosystem is part of the key just as it is in storage.
String homeProviderKey(PluginInfo info) => '${info.ecosystem.name}:${info.id}';

final homeProviderSelectionProvider =
    NotifierProvider<HomeProviderSelectionController, HomeProviderSelection>(
  HomeProviderSelectionController.new,
);

final class HomeProviderSelectionController
    extends Notifier<HomeProviderSelection> {
  static const String settingsKey = 'home.providers';

  @override
  HomeProviderSelection build() {
    final stored = ref.read(settingsStoreProvider).getString(settingsKey);
    if (stored == null) return HomeProviderSelection.all();
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! List) return HomeProviderSelection.all();
      return HomeProviderSelection.only(decoded.whereType<String>());
    } on FormatException {
      return HomeProviderSelection.all();
    }
  }

  /// Changes one checkbox. Leaving the "all" mode snapshots the currently
  /// available providers first, so unchecking one does not clear every other
  /// row.
  Future<void> setProvider({
    required String key,
    required bool selected,
    required Iterable<String> availableKeys,
  }) async {
    final keys = state.isAll ? availableKeys.toSet() : state.keys.toSet();
    if (selected) {
      keys.add(key);
    } else {
      keys.remove(key);
    }
    state = HomeProviderSelection.only(keys);
    await _persist(keys);
  }

  /// Includes every current and future enabled provider.
  Future<void> useAllProviders() async {
    state = HomeProviderSelection.all();
    await ref.read(settingsStoreProvider).remove(settingsKey);
  }

  /// An intentional empty Home feed, distinct from the default all mode.
  Future<void> selectNone() async {
    state = HomeProviderSelection.only(const <String>[]);
    await _persist(const <String>{});
  }

  Future<void> _persist(Set<String> keys) async {
    final sorted = keys.toList()..sort();
    await ref
        .read(settingsStoreProvider)
        .setString(settingsKey, jsonEncode(sorted));
  }
}

/// The aggregated home feed from the providers the user selected.
final homeFeedProvider = FutureProvider.autoDispose<List<HomeSection>>((
  ref,
) async {
  final selection = ref.watch(homeProviderSelectionProvider);
  if (!selection.isAll && selection.keys.isEmpty) {
    return const <HomeSection>[];
  }
  final providers = await ref.watch(mediaProvidersProvider.future);
  if (providers.isEmpty) return const <HomeSection>[];
  final selected = providers
      .where(
        (provider) =>
            provider.capabilities.home &&
            selection.includes(homeProviderKey(provider.info)),
      )
      .toList(growable: false);
  return CatalogService.home(selected);
});

/// Search remains deliberately independent of the Home filter: selecting a
/// quiet Home feed must not make an installed provider impossible to search.
final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider = FutureProvider.autoDispose
    .family<List<SearchGroup>, String>((ref, query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const <SearchGroup>[];
  final providers = await ref.watch(mediaProvidersProvider.future);
  return CatalogService.search(providers, trimmed);
});
