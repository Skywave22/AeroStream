import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/home_section.dart';
import '../../domain/services/catalog_service.dart';

/// The aggregated home feed: every enabled plugin's rows, deduplicated.
final homeFeedProvider = FutureProvider.autoDispose<List<HomeSection>>((
  ref,
) async {
  final providers = await ref.watch(mediaProvidersProvider.future);
  if (providers.isEmpty) return const <HomeSection>[];
  return CatalogService.home(providers);
});

/// Search results across every plugin, grouped by plugin.
final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider = FutureProvider.autoDispose
    .family<List<SearchGroup>, String>((ref, query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return const <SearchGroup>[];
  final providers = await ref.watch(mediaProvidersProvider.future);
  return CatalogService.search(providers, trimmed);
});
