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

/// SkyStream plugin adapter.
///
/// Verified against the SkyStream plugin template (`plugin.json` + `plugin.js`)
/// and the app's own JS provider:
///
/// ```js
/// globalThis.getHome(cb)              // cb({success, data: {category: [item]}})
/// globalThis.search(query, page, cb)  // cb({success, data: [item]})
/// globalThis.load(url, cb)            // cb({success, data: item})
/// globalThis.loadStreams(url, cb)     // cb({success, data: [stream]})
/// ```
///
/// Items are `MultimediaItem`s (`title`, `url`, `posterUrl`, `bannerUrl`,
/// `type`, `year`, `score`, `tags`, `headers`, `episodes`, `streams`), where a
/// `StreamResult` is `{url, source, headers}`.
final class SkyStreamAdapter implements MediaProvider {
  SkyStreamAdapter({
    required this.info,
    required JsPluginHost host,
    this.baseUrl,
  }) : _host = host;

  final JsPluginHost _host;

  /// The manifest's `baseUrl`, used to resolve relative artwork paths.
  final String? baseUrl;

  @override
  final PluginInfo info;

  @override
  PluginCapabilities get capabilities => info.capabilities;

  @override
  Future<Result<List<HomeSection>>> getHome() async {
    if (!capabilities.home) return _unsupported('getHome');
    final response = await _host.call('getHome');
    return switch (response) {
      Err<Object?>(:final error) => Err<List<HomeSection>>(error),
      Ok<Object?>(:final value) => Ok<List<HomeSection>>(
          mapHome(value),
        ),
    };
  }

  @override
  Future<Result<SearchPage>> search(String query, {int page = 1}) async {
    if (!capabilities.search) return _unsupported('search');
    // One argument, like SkyStream: the SDK's `search(query, cb)` has no page
    // parameter, and passing one puts the page number where the plugin expects
    // its callback — `r({success: …})` on a number, which throws.
    // Pagination is the host's business; the plugin returns what it returns.
    final response = await _host.call('search', args: <Object?>[query]);
    return switch (response) {
      Err<Object?>(:final error) => Err<SearchPage>(error),
      Ok<Object?>(:final value) => Ok<SearchPage>(mapSearchPage(value)),
    };
  }

  @override
  Future<Result<MediaDetails>> getDetails(MediaItem item) async {
    if (!capabilities.details) return _unsupported('load');
    final handle = item.url;
    if (handle == null || handle.isEmpty) {
      return const Err<MediaDetails>(
        PluginParseError('This item has no plugin handle', field: 'url'),
      );
    }
    final response = await _host.call('load', args: <Object?>[handle]);
    return switch (response) {
      Err<Object?>(:final error) => Err<MediaDetails>(error),
      Ok<Object?>(:final value) => _detailsFrom(value, item),
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
    if (!capabilities.streams) return _unsupported('loadStreams');
    final handle = (episode?.url.isNotEmpty ?? false) ? episode!.url : item.url;
    if (handle == null || handle.isEmpty) {
      return const Err<StreamResult>(
        PluginParseError('Nothing to resolve: the item has no handle'),
      );
    }

    final response = await _host.call('loadStreams', args: <Object?>[handle]);
    return switch (response) {
      Err<Object?>(:final error) => Err<StreamResult>(error),
      Ok<Object?>(:final value) => Ok<StreamResult>(
          StreamResult(
            sources: mapStreams(value),
            subtitles: mapSubtitles(value),
            diagnostics: mapDiagnostics(value),
          ),
        ),
    };
  }

  @override
  Future<void> dispose() => _host.dispose();

  // ---- mapping (pure, unit-tested) ---------------------------------------

  /// `{category: [item]}` — or a bare list, which some plugins return.
  List<HomeSection> mapHome(Object? raw) {
    if (raw is List) {
      final items = _items(raw);
      if (items.isEmpty) return const <HomeSection>[];
      return <HomeSection>[
        HomeSection(title: 'Latest', items: items, pluginId: info.id),
      ];
    }
    if (raw is! Map) return const <HomeSection>[];

    final sections = <HomeSection>[];
    for (final entry in raw.entries) {
      final title = entry.key.toString();
      final items = _items(entry.value);
      if (items.isEmpty) continue;
      sections.add(
        HomeSection(
          title: title,
          items: items,
          pluginId: info.id,
          // SkyStream reserves "Trending" for the hero carousel.
          layout: title.toLowerCase() == 'trending'
              ? HomeSectionLayout.carousel
              : HomeSectionLayout.posterRow,
        ),
      );
    }
    // The carousel always leads, whatever order the plugin emitted.
    sections.sort((a, b) {
      if (a.layout == b.layout) return 0;
      return a.layout == HomeSectionLayout.carousel ? -1 : 1;
    });
    return List<HomeSection>.unmodifiable(sections);
  }

  SearchPage mapSearchPage(Object? raw) {
    final items = _items(AdapterSupport.items(raw));
    final map = raw is Map ? readMap(raw) : const <String, Object?>{};
    final hasMore = readBool(map['hasMore']) ||
        readBool(map['hasNextPage']) ||
        map['nextPage'] != null;
    return SearchPage(
      items: items,
      pluginId: info.id,
      hasMore: hasMore,
      nextPage: map['nextPage'],
    );
  }

  Result<MediaDetails> _detailsFrom(Object? raw, MediaItem fallback) {
    if (raw is! Map) {
      return const Err<MediaDetails>(
        PluginParseError('The plugin returned no details', field: 'data'),
      );
    }
    final parsed = AdapterSupport.mediaItem(
      readMap(raw),
      pluginId: info.id,
      baseUrl: baseUrl,
    );
    final item = parsed == null ? fallback : _merge(parsed, fallback);

    final episodes = <Episode>[];
    for (final entry in AdapterSupport.items(raw['episodes'])) {
      final episode = mapEpisode(entry);
      if (episode != null) episodes.add(episode);
    }
    episodes.sort((a, b) {
      if (a.seasonNumber != b.seasonNumber) {
        return a.seasonNumber.compareTo(b.seasonNumber);
      }
      return a.number.compareTo(b.number);
    });

    final seasons = <Season>[];
    for (final entry in readMapList(raw['seasons'])) {
      final number = readInt(entry['number']) ?? readInt(entry['season']);
      if (number == null) continue;
      seasons.add(
        Season(
          number: number,
          title: readString(entry['title'] ?? entry['name']),
          episodeCount: readInt(entry['episodeCount']),
          posterUrl: readString(entry['posterUrl']),
        ),
      );
    }

    final recommendations = <MediaItem>[];
    for (final entry in AdapterSupport.items(raw['recommendations'])) {
      final recommendation = AdapterSupport.mediaItem(
        entry,
        pluginId: info.id,
        baseUrl: baseUrl,
      );
      if (recommendation != null) recommendations.add(recommendation);
    }

    return Ok<MediaDetails>(
      MediaDetails(
        item: item,
        description: readString(raw['description']) ?? item.description,
        genres: readStringList(raw['tags'] ?? raw['genres']).isEmpty
            ? item.genres
            : readStringList(raw['tags'] ?? raw['genres']),
        cast: readMapList(raw['cast'])
            .map(Actor.fromJson)
            .toList(growable: false),
        trailers: readMapList(raw['trailers'])
            .map(
              (trailer) => Trailer(
                url: readString(trailer['url']) ?? '',
                name: readString(trailer['name']),
              ),
            )
            .where((trailer) => trailer.url.isNotEmpty)
            .toList(growable: false),
        seasons: seasons,
        episodes: List<Episode>.unmodifiable(episodes),
        recommendations: List<MediaItem>.unmodifiable(recommendations),
        status: readString(raw['status']),
        runtimeMinutes: readInt(raw['duration']),
        logoUrl: AdapterSupport.imageUrl(raw['logoUrl'], baseUrl: baseUrl),
        contentRating: readString(raw['contentRating']),
        playbackPolicy: PlaybackPolicy.fromWire(raw['playbackPolicy']),
        instantSources: mapStreams(raw),
        headers: readStringMap(raw['headers']),
        syncData: readMap(raw['syncData']),
      ),
    );
  }

  /// Prefers the richer payload field while keeping the caller's identity.
  MediaItem _merge(MediaItem parsed, MediaItem fallback) => parsed.copyWith(
        id: fallback.id,
        headers: parsed.headers.isEmpty ? fallback.headers : parsed.headers,
      );

  Episode? mapEpisode(Map<String, Object?> raw) {
    final url = readString(raw['url']) ?? readString(raw['link']);
    if (url == null) return null;
    final number = readInt(raw['episode']) ??
        readInt(raw['number']) ??
        readInt(raw['episodeNumber']) ??
        1;
    final seasonNumber =
        readInt(raw['season']) ?? readInt(raw['seasonNumber']) ?? 1;
    return Episode(
      id: AdapterSupport.itemId(
        '${info.id}/episode',
        url: url,
        title: readString(raw['name']) ?? readString(raw['title']),
      ),
      url: url,
      number: number,
      seasonNumber: seasonNumber,
      title: readString(raw['name']) ?? readString(raw['title']),
      description: readString(raw['description']),
      thumbnailUrl: AdapterSupport.imageUrl(
        raw['posterUrl'] ?? raw['thumbnail'],
        baseUrl: baseUrl,
      ),
      airDate: readDate(raw['airDate']),
      runtimeMinutes: readInt(raw['duration']),
      headers: readStringMap(raw['headers']),
      extras: readMap(raw['extras']),
    );
  }

  /// Accepts a list of `StreamResult`s or a `{streams: [...]}` wrapper.
  List<StreamSource> mapStreams(Object? raw) {
    final entries = raw is List
        ? readMapList(raw)
        : readMapList(raw is Map ? raw['streams'] : null);
    final sources = <StreamSource>[];
    for (final entry in entries) {
      final url = readString(entry['url']) ?? readString(entry['link']);
      if (url == null) continue;
      if (!url.contains('://')) continue;
      sources.add(
        StreamSource(
          url: url,
          label: readString(entry['source']) ??
              readString(entry['label']) ??
              readString(entry['server']) ??
              'Default',
          quality: qualityLabel(entry['quality']),
          headers: readStringMap(entry['headers']),
          isHls: url.toLowerCase().contains('.m3u8'),
          isDash: url.toLowerCase().contains('.mpd'),
          extractorName: readString(entry['extractor']),
          isDrmProtected: _isDrm(entry),
        ),
      );
    }
    return List<StreamSource>.unmodifiable(sources);
  }

  /// `quality` is a height in the SkyStream schema (`1080`, or the string
  /// `"720p"`), and `0`/`"Auto"` marks an HLS master whose variants the player
  /// picks. Numbers arrive as numbers, so `readString` alone would drop them.
  static String? qualityLabel(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw <= 0 ? null : '${raw.round()}';
    final text = raw.toString().trim();
    if (text.isEmpty) return null;
    return text;
  }

  /// SkyStream reports DRM as a key id and/or a licence URL on the stream.
  static bool _isDrm(Object? raw) {
    final map = raw is Map ? readMap(raw) : const <String, Object?>{};
    final kid = readString(map['drmKid']) ?? readString(map['drm_kid']);
    final licence =
        readString(map['licenseUrl']) ?? readString(map['license_url']);
    return (kid?.isNotEmpty ?? false) || (licence?.isNotEmpty ?? false);
  }

  /// Things the user should know before pressing play.
  ///
  /// SkyStream lets a plugin hand back `MAGIC_PROXY_v1<base64>` and
  /// `magic_m3u8:<base64>` pseudo-URLs that only work inside SkyStream's own
  /// proxy. They are not playable here, so they are reported instead of
  /// disappearing from the list with no explanation.
  List<String> mapDiagnostics(Object? raw) {
    final entries = raw is List
        ? readMapList(raw)
        : readMapList(raw is Map ? raw['streams'] : null);
    var proxied = 0;
    var drmVariant = 0;
    for (final entry in entries) {
      final url = readString(entry['url']) ?? readString(entry['link']) ?? '';
      if (url.startsWith('MAGIC_PROXY_') || url.startsWith('magic_m3u8:')) {
        proxied++;
      } else if (_isDrm(entry)) {
        drmVariant++;
      }
    }
    return <String>[
      if (proxied > 0)
        '$proxied link${proxied == 1 ? '' : 's'} needed SkyStream\'s byte proxy '
            'and cannot be played here',
      if (drmVariant > 0)
        '$drmVariant link${drmVariant == 1 ? '' : 's'} are DRM-protected and '
            'cannot be decrypted here',
    ];
  }

  /// Subtitles arrive either on the envelope or on each stream.
  ///
  /// The schema documents `{url, label, lang}` per stream, so a plugin that
  /// attaches a track to the one source it belongs to is normal — merging both
  /// places (de-duplicated by URL) is what keeps that track visible.
  List<SubtitleTrack> mapSubtitles(Object? raw) {
    final map = raw is Map ? readMap(raw) : const <String, Object?>{};
    final entries = <Map<String, Object?>>[
      ...AdapterSupport.subtitles(map['subtitles'] ?? map['tracks']),
    ];
    final streams =
        raw is List ? readMapList(raw) : readMapList(map['streams']);
    for (final stream in streams) {
      entries.addAll(AdapterSupport.subtitles(stream['subtitles']));
    }

    final tracks = <SubtitleTrack>[];
    final seen = <String>{};
    for (final entry in entries) {
      final url = readString(entry['url']);
      if (url == null || !url.contains('://')) continue;
      if (!seen.add(url)) continue;
      tracks.add(
        SubtitleTrack(
          url: url,
          language: readString(entry['language']) ??
              readString(entry['lang']) ??
              'und',
          label: readString(entry['label']) ?? readString(entry['name']),
          format: readString(entry['format']) ?? 'vtt',
          headers: readStringMap(entry['headers']),
        ),
      );
    }
    return List<SubtitleTrack>.unmodifiable(tracks);
  }

  List<MediaItem> _items(Object? raw) {
    final entries = raw is List
        ? raw
        : readMapList(raw is Map ? (raw['items'] ?? raw['data']) : null);
    final items = <MediaItem>[];
    for (final entry in entries) {
      final map = entry is Map ? readMap(entry) : null;
      if (map == null) continue;
      final item = AdapterSupport.mediaItem(
        map,
        pluginId: info.id,
        baseUrl: baseUrl,
      );
      if (item != null) items.add(item);
    }
    return List<MediaItem>.unmodifiable(items);
  }

  Result<T> _unsupported<T>(String operation) => Err<T>(
        PluginUnsupportedError(
          'This plugin does not implement $operation',
          pluginId: info.id,
          operation: operation,
        ),
      );
}
