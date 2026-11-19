import '../../core/errors/plugin_error.dart';
import '../../core/result.dart';
import '../entities/home_section.dart';
import '../entities/media_item.dart';
import '../entities/plugin_info.dart';
import '../media_provider.dart';

/// One plugin's slice of a search.
final class SearchGroup {
  const SearchGroup({
    required this.plugin,
    required this.items,
    this.error,
    this.hasMore = false,
    this.nextPage,
  });

  final PluginInfo plugin;
  final List<MediaItem> items;

  /// Set when this plugin failed, so the UI can show an inline retry instead of
  /// hiding the group.
  final PluginError? error;

  final bool hasMore;
  final Object? nextPage;

  bool get isEmpty => items.isEmpty && error == null;
}

/// Aggregates several plugins into the home feed and search results.
///
/// The rules that matter for a good experience:
/// * one slow or broken plugin must not delay or hide the others;
/// * duplicates (the same title from two plugins) are collapsed, keeping the
///   higher-priority plugin;
/// * the feed never contains an empty section.
abstract final class CatalogService {
  /// Home rows from every provider, in plugin priority order.
  static Future<List<HomeSection>> home(
    List<MediaProvider> providers, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (providers.isEmpty) return const <HomeSection>[];

    final results = await Future.wait(
      providers.map(
        (provider) => _guarded(provider.info, provider.getHome, timeout),
      ),
    );

    final sections = <HomeSection>[];
    final seenTitles = <String, Set<String>>{};
    for (final result in results) {
      for (final section in result) {
        final seen = seenTitles.putIfAbsent(section.title, () => <String>{});
        final fresh = <MediaItem>[];
        for (final item in section.items) {
          final key = _dedupeKey(item);
          if (seen.add(key)) fresh.add(item);
        }
        if (fresh.isEmpty) continue;
        sections
            .add(section.copyWith(items: List<MediaItem>.unmodifiable(fresh)));
      }
    }
    return sections;
  }

  /// Searches every provider in parallel, keeping failures visible.
  static Future<List<SearchGroup>> search(
    List<MediaProvider> providers,
    String query, {
    int page = 1,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (providers.isEmpty || query.trim().isEmpty) return const <SearchGroup>[];

    final results = await Future.wait(
      providers.map((provider) async {
        try {
          final result =
              await provider.search(query, page: page).timeout(timeout);
          return switch (result) {
            Ok<SearchPage>(:final value) => SearchGroup(
                plugin: provider.info,
                items: value.items,
                hasMore: value.hasMore,
                nextPage: value.nextPage,
              ),
            Err<SearchPage>(:final error) => SearchGroup(
                plugin: provider.info,
                items: const <MediaItem>[],
                error: error,
              ),
          };
        } on Object catch (error) {
          return SearchGroup(
            plugin: provider.info,
            items: const <MediaItem>[],
            error: PluginUnknownError('Search failed: $error'),
          );
        }
      }),
    );

    // Plugins that returned results first, then the ones that errored.
    final groups =
        results.where((group) => !group.isEmpty).toList(growable: false);
    groups.sort((a, b) {
      if (a.error == null && b.error != null) return -1;
      if (a.error != null && b.error == null) return 1;
      return a.plugin.priority.compareTo(b.plugin.priority);
    });
    return groups;
  }

  /// Finds the provider that owns [item] (its plugin id is authoritative).
  static MediaProvider? providerFor(
    List<MediaProvider> providers,
    MediaItem item,
  ) {
    for (final provider in providers) {
      if (provider.info.id == item.pluginId) return provider;
    }
    return null;
  }

  static String _dedupeKey(MediaItem item) =>
      '${item.title.toLowerCase()}|${item.year ?? ''}';

  static Future<List<HomeSection>> _guarded(
    PluginInfo plugin,
    Future<Result<List<HomeSection>>> Function() load,
    Duration timeout,
  ) async {
    try {
      final result = await load().timeout(timeout);
      return switch (result) {
        Ok<List<HomeSection>>(:final value) => value,
        Err<List<HomeSection>>() => const <HomeSection>[],
      };
    } on Object {
      // A plugin that hangs or throws contributes nothing; the rest of the
      // feed still renders.
      return const <HomeSection>[];
    }
  }
}
