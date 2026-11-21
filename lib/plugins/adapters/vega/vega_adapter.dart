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
      Ok<Object?>(:final value) => Ok<List<HomeSection>>(
          mapHome(value, origin: _host.origin),
        ),
    };
  }

  /// The site the provider last reached.
  ///
  /// Vega providers publish links as paths (`/download-.../`). Everything
  /// downstream — details, then the extraction step that turns a page into a
  /// playable URL — expects an absolute address, and the host already knows
  /// which site a bare path belongs to, because it served the request that
  /// produced it.
  String? get _origin => _host.origin;

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
    final origin = _origin;
    return switch (response) {
      Err<Object?>(:final error) => Err<SearchPage>(error),
      Ok<Object?>(:final value) => Ok<SearchPage>(
          SearchPage(
            items: _items(value, origin: origin),
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
    // Vega splits series in two: `meta.js` says there are episodes and gives the
    // handle, `episodes.js getEpisodes({url})` returns them. Providers that put
    // episodes inline in `getMeta` still work through the fallback.
    var link = readString(item.extras['episodesLink']);
    if (link == null || link.isEmpty) {
      // The caller may hold the shelf item rather than the loaded one; the
      // handle only appears after `getMeta`.
      final details = await getDetails(item);
      if (details is Ok<MediaDetails>) {
        link = readString(details.value.item.extras['episodesLink']);
      }
    }
    if (link != null && link.isNotEmpty) {
      final response = await _call(
        'episodes',
        'getEpisodes',
        <String, Object?>{
          'url': link,
          'link': link,
          'providerValue': providerValue
        },
      );
      if (response is Ok<Object?>) {
        final mapped = mapEpisodes(response.value);
        if (mapped.isNotEmpty) {
          return Ok<List<Episode>>(
            season == null
                ? mapped
                : mapped
                    .where((episode) => episode.seasonNumber == season.number)
                    .toList(growable: false),
          );
        }
      }
    }

    final details = await getDetails(item);
    return switch (details) {
      Err<MediaDetails>(:final error) => Err<List<Episode>>(error),
      Ok<MediaDetails>(:final value) => Ok<List<Episode>>(
          season == null ? value.episodes : value.episodesOf(season.number),
        ),
    };
  }

  /// `EpisodeLink[]`: `{id?, title, link, sourceLink?, description?, image?}`.
  List<Episode> mapEpisodes(Object? raw) {
    final episodes = <Episode>[];
    for (final entry in AdapterSupport.items(raw)) {
      final link = readString(entry['link']) ?? readString(entry['url']);
      if (link == null || link.isEmpty) continue;
      final title = readString(entry['title']) ?? readString(entry['name']);
      episodes.add(
        Episode(
          id: AdapterSupport.itemId(
            '${info.id}/episode',
            url: link,
            title: title,
          ),
          url: link,
          number: readInt(entry['episode']) ??
              readInt(entry['number']) ??
              episodes.length + 1,
          seasonNumber:
              readInt(entry['season']) ?? readInt(entry['seasonNumber']) ?? 1,
          title: title,
          description: readString(entry['description']),
          thumbnailUrl: AdapterSupport.imageUrl(entry['image']),
          runtimeMinutes: readInt(entry['runtime'] ?? entry['duration']),
          airDate: readDate(entry['airDate'] ?? entry['released']),
          extras: <String, Object?>{
            if (readString(entry['sourceLink']) != null)
              'sourceLink': readString(entry['sourceLink']),
          },
        ),
      );
    }
    return List<Episode>.unmodifiable(episodes);
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
    // `JSON.stringify(__vegaHas(…))` decodes to a bool, but a provider that
    // shadows the helper can hand back the string; treat both as "missing".
    final exported = available is Ok<Object?> ? available.value : null;
    if (exported == false || exported == 'false') {
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

  List<HomeSection> mapHome(Object? raw, {String? origin}) {
    final items = _items(raw, origin: origin);
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
        extras: <String, Object?>{
          ...item.extras,
          if (_episodesLink(map) case final link?) 'episodesLink': link,
        },
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

  /// The handle `episodes.js` is called with: `episodesLink` on the metadata,
  /// or the first `linkList` entry that has one (that is where Vega providers
  /// usually put it).
  static String? _episodesLink(Map<String, Object?> map) {
    final direct = readString(map['episodesLink']);
    if (direct != null && direct.isNotEmpty) return direct;
    for (final entry in AdapterSupport.items(map['linkList'])) {
      final link = readString(entry['episodesLink']);
      if (link != null && link.isNotEmpty) return link;
    }
    return null;
  }

  List<MediaItem> _items(Object? raw, {String? origin}) {
    final items = <MediaItem>[];
    for (final entry in AdapterSupport.items(raw)) {
      final parsed = AdapterSupport.mediaItem(
        entry,
        pluginId: info.id,
        defaultType: MediaType.other,
      );
      if (parsed == null) continue;
      final url = parsed.url;
      final resolved = origin != null && url != null && url.startsWith('/')
          ? parsed.copyWith(url: '$origin$url')
          : parsed;
      items.add(resolved);
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
