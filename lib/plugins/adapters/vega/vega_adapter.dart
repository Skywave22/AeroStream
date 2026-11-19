import 'dart:convert';

import '../../../core/errors/plugin_error.dart';
import '../../../core/json/json_read.dart';
import '../../../core/result.dart';
import '../../../domain/entities/enums.dart';
import '../../../domain/entities/episode.dart';
import '../../../domain/entities/home_section.dart';
import '../../../domain/entities/media_details.dart';
import '../../../domain/entities/media_item.dart';
import '../../../domain/entities/plugin_info.dart';
import '../../../domain/entities/stream_source.dart';
import '../../../domain/media_provider.dart';
import '../../runtime/js_plugin_host.dart';
import '../adapter_support.dart';

/// Vega provider adapter.
///
/// A Vega provider is a folder of CommonJS bundles next to a `manifest.json`:
///
/// ```js
/// // dist/<provider>/posts.js
/// exports.getPosts = async ({ filter, page, providerValue, providerContext }) =>
///   [{ title, link, image }];
/// exports.getSearchPosts = async ({ searchQuery, page, … }) => [ … ];
///
/// // dist/<provider>/meta.js
/// exports.getMeta = async ({ link, providerValue, providerContext }) => ({ … });
///
/// // dist/<provider>/stream.js
/// exports.getStream = async ({ link, type, … }) =>
///   [{ server, link, type, quality }];
/// ```
///
/// Assumption stated for the record: `getMeta` returns the item's metadata and,
/// when the title is episodic, an `episodes` array; `getStream` takes the
/// episode `link`. Both shapes are mapped leniently, so a provider that returns
/// a superset (or names fields differently) still works.
final class VegaAdapter implements MediaProvider {
  VegaAdapter({
    required this.info,
    required JsPluginHost host,
    this.providerValue,
  }) : _host = host;

  final JsPluginHost _host;

  /// The provider's `value` from the repository manifest; sent as
  /// `providerValue` on every call, which some providers use for settings.
  final String? providerValue;

  @override
  final PluginInfo info;

  @override
  PluginCapabilities get capabilities => info.capabilities;

  @override
  Future<Result<List<HomeSection>>> getHome() async {
    final response = await _call(
      'posts',
      'getPosts',
      <String, Object?>{
        'filter': null,
        'page': 1,
        'providerValue': providerValue,
      },
    );
    return switch (response) {
      Err<Object?>(:final error) => Err<List<HomeSection>>(error),
      Ok<Object?>(:final value) => Ok<List<HomeSection>>(mapHome(value)),
    };
  }

  @override
  Future<Result<SearchPage>> search(String query, {int page = 1}) async {
    final response = await _call(
      'posts',
      'getSearchPosts',
      <String, Object?>{
        'searchQuery': query,
        'page': page,
        'providerValue': providerValue,
      },
    );
    return switch (response) {
      Err<Object?>(:final error) => Err<SearchPage>(error),
      Ok<Object?>(:final value) => Ok<SearchPage>(
          SearchPage(
            items: _items(value),
            pluginId: info.id,
            hasMore: (value is List) && value.isNotEmpty,
            nextPage: page + 1,
          ),
        ),
    };
  }

  @override
  Future<Result<MediaDetails>> getDetails(MediaItem item) async {
    final link = item.url;
    if (link == null || link.isEmpty) {
      return const Err<MediaDetails>(
        PluginParseError('This item has no provider link', field: 'url'),
      );
    }
    final response = await _call(
      'meta',
      'getMeta',
      <String, Object?>{'link': link, 'providerValue': providerValue},
    );
    return switch (response) {
      Err<Object?>(:final error) => Err<MediaDetails>(error),
      Ok<Object?>(:final value) => Ok<MediaDetails>(
          mapDetails(value, fallback: item),
        ),
    };
  }

  @override
  Future<Result<List<Episode>>> getEpisodes(
    MediaItem item, {
    Season? season,
  }) async {
    final details = await getDetails(item);
    return switch (details) {
      Err<MediaDetails>(:final error) => Err<List<Episode>>(error),
      Ok<MediaDetails>(:final value) => Ok<List<Episode>>(
          season == null ? value.episodes : value.episodesOf(season.number),
        ),
    };
  }

  @override
  Future<Result<StreamResult>> getStreams(
    MediaItem item, {
    Episode? episode,
  }) async {
    final link = (episode?.url.isNotEmpty ?? false) ? episode!.url : item.url;
    if (link == null || link.isEmpty) {
      return const Err<StreamResult>(
        PluginParseError('Nothing to resolve: the item has no link'),
      );
    }
    final response = await _call(
      'stream',
      'getStream',
      <String, Object?>{
        'link': link,
        'type': item.type.wire,
        'isDownload': false,
        'providerValue': providerValue,
      },
    );
    return switch (response) {
      Err<Object?>(:final error) => Err<StreamResult>(error),
      Ok<Object?>(:final value) => Ok<StreamResult>(
          StreamResult(
            sources: mapStreams(value),
            subtitles: mapSubtitles(value),
          ),
        ),
    };
  }

  @override
  Future<void> dispose() => _host.dispose();

  /// Calls `__vegaCall(module, function, options)` inside the sandbox.
  Future<Result<Object?>> _call(
    String module,
    String function,
    Map<String, Object?> options,
  ) async {
    final available = await _host.evaluateExpression(
      '__vegaHas(${jsonEncode(module)}, ${jsonEncode(function)})',
    );
    if (available is Ok<Object?> && available.value == 'false') {
      return Err<Object?>(
        PluginUnsupportedError(
          'This provider does not export $function',
          pluginId: info.id,
          operation: function,
        ),
      );
    }
    return _host.call(
      '__vegaCall',
      args: <Object?>[module, function, jsonEncode(options)],
    );
  }

  // ---- mapping (pure, unit-tested) ---------------------------------------

  List<HomeSection> mapHome(Object? raw) {
    final items = _items(raw);
    if (items.isEmpty) return const <HomeSection>[];
    return <HomeSection>[
      HomeSection(
        title: 'Latest',
        items: items,
        pluginId: info.id,
        layout: HomeSectionLayout.posterRow,
      ),
    ];
  }

  MediaDetails mapDetails(Object? raw, {required MediaItem fallback}) {
    final map = raw is Map ? readMap(raw) : const <String, Object?>{};
    final parsed = AdapterSupport.mediaItem(map, pluginId: info.id);
    final item = parsed == null
        ? fallback
        : parsed.copyWith(
            id: fallback.id,
            type: parsed.type == MediaType.other ? fallback.type : parsed.type,
          );

    final episodes = <Episode>[];
    for (final entry in AdapterSupport.items(map['episodes'])) {
      final link = readString(entry['link']) ?? readString(entry['url']);
      if (link == null) continue;
      final seasonNumber =
          readInt(entry['season']) ?? readInt(entry['seasonNumber']) ?? 1;
      final number = readInt(entry['episode']) ?? readInt(entry['number']) ?? 1;
      episodes.add(
        Episode(
          id: AdapterSupport.itemId(
            '${info.id}/episode',
            url: link,
            title: readString(entry['title']),
          ),
          url: link,
          number: number,
          seasonNumber: seasonNumber,
          title: readString(entry['title']) ?? readString(entry['name']),
          description: readString(entry['description']),
          thumbnailUrl: AdapterSupport.imageUrl(
            entry['image'] ?? entry['thumbnail'],
          ),
          airDate: readDate(entry['airDate'] ?? entry['released']),
        ),
      );
    }

    final seasons = <int, int>{};
    for (final episode in episodes) {
      seasons.update(
        episode.seasonNumber,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final seasonNumbers = seasons.keys.toList()..sort();

    return MediaDetails(
      item: item.copyWith(
        type: episodes.isEmpty ? item.type : MediaType.series,
      ),
      description: readString(map['description']) ?? item.description,
      genres: readStringList(map['genres'] ?? map['tags']),
      cast:
          readMapList(map['cast']).map(Actor.fromJson).toList(growable: false),
      trailers: readMapList(map['trailer'] is List ? map['trailer'] : null)
          .map(
            (trailer) => Trailer(
              url: readString(trailer['url']) ?? '',
              name: readString(trailer['name']),
            ),
          )
          .where((trailer) => trailer.url.isNotEmpty)
          .toList(growable: false),
      seasons: seasonNumbers
          .map(
            (number) => Season(number: number, episodeCount: seasons[number]),
          )
          .toList(growable: false),
      episodes: List<Episode>.unmodifiable(episodes),
      status: readString(map['status']),
      runtimeMinutes: readInt(map['runtime'] ?? map['duration']),
      headers: readStringMap(map['headers']),
    );
  }

  List<MediaItem> _items(Object? raw) {
    final items = <MediaItem>[];
    for (final entry in AdapterSupport.items(raw)) {
      final item = AdapterSupport.mediaItem(
        entry,
        pluginId: info.id,
        defaultType: MediaType.other,
      );
      if (item != null) items.add(item);
    }
    return List<MediaItem>.unmodifiable(items);
  }

  /// Vega stream entries are `{server, link, type, quality}`.
  List<StreamSource> mapStreams(Object? raw) {
    final entries = raw is List
        ? readMapList(raw)
        : readMapList(raw is Map ? (raw['sources'] ?? raw['links']) : null);
    final sources = <StreamSource>[];
    for (final entry in entries) {
      final url = readString(entry['link']) ?? readString(entry['url']);
      if (url == null || !url.contains('://')) continue;
      final kind = readString(entry['type'])?.toLowerCase() ?? '';
      sources.add(
        StreamSource(
          url: url,
          label: readString(entry['server']) ??
              readString(entry['name']) ??
              readString(entry['label']) ??
              'Default',
          quality: readString(entry['quality']),
          headers: readStringMap(entry['headers']),
          isHls: kind == 'm3u8' ||
              kind == 'hls' ||
              url.toLowerCase().contains('.m3u8'),
          isDash: kind == 'mpd' || kind == 'dash',
          extractorName: readString(entry['extractor']),
        ),
      );
    }
    return List<StreamSource>.unmodifiable(sources);
  }

  List<SubtitleTrack> mapSubtitles(Object? raw) {
    final map = raw is Map ? readMap(raw) : const <String, Object?>{};
    final entries = AdapterSupport.subtitles(map['subtitles']);
    return List<SubtitleTrack>.unmodifiable(
      entries
          .map(
            (entry) => SubtitleTrack(
              url: readString(entry['url']) ?? '',
              language: readString(entry['language']) ?? 'und',
              label: readString(entry['label']),
              format: readString(entry['format']) ?? 'srt',
            ),
          )
          .where((track) => track.url.contains('://')),
    );
  }
}
