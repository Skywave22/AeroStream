import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/errors/plugin_error.dart';
import '../../core/result.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/media_details.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/stream_source.dart';
import '../../domain/services/catalog_service.dart';

/// Full metadata for one item, from the plugin that owns it.
final detailsProvider = FutureProvider.autoDispose
    .family<MediaDetails, MediaItem>((ref, item) async {
  final providers = await ref.watch(mediaProvidersProvider.future);
  final provider = CatalogService.providerFor(providers, item);
  if (provider == null) {
    throw PluginNotFoundError(
      'The extension that provides this title is not installed',
      pluginId: item.pluginId,
    );
  }
  final result = await provider.getDetails(item);
  return switch (result) {
    Ok<MediaDetails>(:final value) => value,
    Err<MediaDetails>(:final error) => throw error,
  };
});

/// What to resolve streams for.
typedef StreamRequest = ({MediaItem item, Episode? episode});

/// Playable links for an item or one of its episodes.
final streamsProvider = FutureProvider.autoDispose
    .family<StreamResult, StreamRequest>((ref, request) async {
  final providers = await ref.watch(mediaProvidersProvider.future);
  final provider = CatalogService.providerFor(providers, request.item);
  if (provider == null) {
    throw PluginNotFoundError(
      'The extension that provides this title is not installed',
      pluginId: request.item.pluginId,
    );
  }
  final result = await provider.getStreams(
    request.item,
    episode: request.episode,
  );
  return switch (result) {
    Ok<StreamResult>(:final value) => value,
    Err<StreamResult>(:final error) => throw error,
  };
});
