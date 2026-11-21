import '../core/result.dart';
import 'entities/episode.dart';
import 'entities/home_section.dart';
import 'entities/media_details.dart';
import 'entities/media_item.dart';
import 'entities/plugin_info.dart';
import 'entities/stream_source.dart';

/// The one interface every ecosystem is adapted onto.
///
/// Implementations must never throw: a broken plugin becomes an `Err` with a
/// typed error, so the UI can show a retry affordance instead of a red screen.
/// Capability flags are authoritative: when `PluginInfo.capabilities` says a
/// method is unsupported, callers must not invoke it, and implementations
/// return `PluginUnsupportedError` when they do.
abstract interface class MediaProvider {
  /// Manifest data for the plugin behind this provider.
  PluginInfo get info;

  PluginCapabilities get capabilities;

  /// Home rows for the plugin's start screen.
  Future<Result<List<HomeSection>>> getHome();

  /// One page of search results.
  Future<Result<SearchPage>> search(String query, {int page = 1});

  /// Full metadata for [item].
  Future<Result<MediaDetails>> getDetails(MediaItem item);

  /// Episodes of [item], optionally restricted to [season].
  Future<Result<List<Episode>>> getEpisodes(MediaItem item, {Season? season});

  /// Playable links for [item] or one [episode] of it.
  Future<Result<StreamResult>> getStreams(MediaItem item, {Episode? episode});

  /// Releases the plugin runtime and any native resources it holds.
  Future<void> dispose();
}
