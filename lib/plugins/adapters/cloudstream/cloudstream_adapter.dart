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
import '../adapter_support.dart';
import 'cloudstream_bridge.dart';

/// CloudStream extension adapter (Android).
///
/// The native host talks CloudStream's own language — `MainAPI`,
/// `newHomePageResponse`, `SearchResponse`, `LoadResponse`, `ExtractorLink` —
/// and answers here in the JSON shape documented in `docs/PLUGIN_SPEC.md`.
/// This adapter is the only place that shape is interpreted, so a host change
/// is a change in one file.
final class CloudStreamAdapter implements MediaProvider {
  CloudStreamAdapter({
    required this.info,
    required CloudStreamBridge bridge,
    required this.artifactPath,
    this.providerName,
  }) : _bridge = bridge;

  final CloudStreamBridge _bridge;

  /// Where the `.cs3` lives, passed to the host on every call so the host can
  /// (re)load the extension without keeping state across app restarts.
  final String artifactPath;

  /// The extension can expose several providers; this adapter is bound to one.
  /// `null` means "the extension's first provider".
  final String? providerName;

  @override
  final PluginInfo info;

  @override
  PluginCapabilities get capabilities => info.capabilities;

  @override
  Future<Result<List<HomeSection>>> getHome() async {
    final reply = await _invoke('getMainPage', <String, Object?>{});
    return switch (reply) {
      Err<Map<String, Object?>>(:final error) => Err<List<HomeSection>>(error),
      Ok<Map<String, Object?>>(:final value) => Ok<List<HomeSection>>(
        mapHome(value),
      ),
    };
  }

  @override
  Future<Result<SearchPage>> search(String query, {int page = 1}) async {
    final reply = await _invoke('search', <String, Object?>{'query': query});
    return switch (reply) {
      Err<Map<String, Object?>>(:final error) => Err<SearchPage>(error),
      Ok<Map<String, Object?>>(:final value) => Ok<SearchPage>(
        SearchPage(items: _items(value['items']), pluginId: info.id),
      ),
    };
  }

  @override
  Future<Result<MediaDetails>> getDetails(MediaItem item) async {
    final url = item.url;
    if (url == null || url.isEmpty) {
      return const Err<MediaDetails>(
        PluginParseError('This item has no extension handle', field: 'url'),
      );
    }
    final reply = await _invoke('load', <String, Object?>{'url': url});
    return switch (reply) {
      Err<Map<String, Object?>>(:final error) => Err<MediaDetails>(error),
      Ok<Map<String, Object?>>(:final value) => Ok<MediaDetails>(
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
    final url = episode?.url.isNotEmpty == true ? episode!.url : item.url;
    if (url == null || url.isEmpty) {
      return const Err<StreamResult>(
        PluginParseError('Nothing to resolve: the item has no handle'),
      );
    }
    final reply = await _invoke('loadLinks', <String, Object?>{
      'url': url,
      'data': episode?.extras ?? item.extras,
    });
    return switch (reply) {
      Err<Map<String, Object?>>(:final error) => Err<StreamResult>(error),
      Ok<Map<String, Object?>>(:final value) => Ok<StreamResult>(
        StreamResult(
          sources: mapStreams(value),
          subtitles: mapSubtitles(value),
        ),
      ),
    };
  }

  @override
  Future<void> dispose() async {}

  /// Unloads the extension from the host (called when it is disabled or
  /// removed).
  Future<void> unload() => _invoke('unloadPlugin', <String, Object?>{});

  Future<Result<Map<String, Object?>>> _invoke(
    String command,
    Map<String, Object?> arguments,
  ) =>
      _bridge.invoke(command, <String, Object?>{
        'pluginPath': artifactPath,
        'provider': providerName,
        ...arguments,
      });

  // ---- mapping (pure, unit-tested) ---------------------------------------

  /// `{sections: [{name, items: [{title, url, posterUrl, …}]}]}`
  List<HomeSection> mapHome(Map<String, Object?> raw) {
    final sections = <HomeSection>[];
    for (final entry in readMapList(raw['sections'])) {
      final name = readString(entry['name']) ?? 'Browse';
      final items = _items(entry['items']);
      if (items.isEmpty) continue;
      sections.add(
        HomeSection(title: name, items: items, pluginId: info.id),
      );
    }
    // Some extensions answer with a bare list instead of sections.
    if (sections.isEmpty) {
      final items = _items(raw['items']);
      if (items.isNotEmpty) {
        sections.add(
          HomeSection(title: 'Latest', items: items, pluginId: info.id),
        );
      }
    }
    return List<HomeSection>.unmodifiable(sections);
  }

  MediaDetails mapDetails(
    Map<String, Object?> raw, {
    required MediaItem fallback,
  }) {
    final itemMap = readMap(raw['item']);
    final parsed = AdapterSupport.mediaItem(itemMap, pluginId: info.id);
    final item = parsed == null ? fallback : parsed.copyWith(id: fallback.id);

    final episodes = <Episode>[];
    for (final entry in readMapList(raw['episodes'])) {
      final url = readString(entry['url']);
      if (url == null) continue;
      final extras = readMap(entry['data']);
      episodes.add(
        Episode(
          id: AdapterSupport.itemId(
            '${info.id}/episode',
            url: url,
            title: readString(entry['name']),
          ),
          url: url,
          number: readInt(entry['episode']) ?? 1,
          seasonNumber: readInt(entry['season']) ?? 1,
          title: readString(entry['name']),
          description: readString(entry['description']),
          thumbnailUrl: AdapterSupport.imageUrl(entry['posterUrl']),
          extras: extras,
        ),
      );
    }
    episodes.sort((a, b) {
      if (a.seasonNumber != b.seasonNumber) {
        return a.seasonNumber.compareTo(b.seasonNumber);
      }
      return a.number.compareTo(b.number);
    });

    final seasons = <int, int>{};
    for (final episode in episodes) {
      seasons.update(
        episode.seasonNumber,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final numbers = seasons.keys.toList()..sort();

    return MediaDetails(
      item: item.copyWith(
        type: episodes.isEmpty ? item.type : MediaType.series,
        description: readString(itemMap['description']) ?? item.description,
      ),
      description: readString(itemMap['description']),
      genres: readStringList(itemMap['tags'] ?? itemMap['genres']),
      seasons: numbers
          .map((number) => Season(number: number, episodeCount: seasons[number]))
          .toList(growable: false),
      episodes: List<Episode>.unmodifiable(episodes),
      headers: readStringMap(raw['headers']),
    );
  }

  /// CloudStream `ExtractorLink`s: `{url, quality, name, headers, isM3u8}`.
  List<StreamSource> mapStreams(Map<String, Object?> raw) {
    final sources = <StreamSource>[];
    for (final entry in readMapList(raw['links'])) {
      final url = readString(entry['url']);
      if (url == null || !url.contains('://')) continue;
      sources.add(
        StreamSource(
          url: url,
          label: readString(entry['name']) ??
              readString(entry['source']) ??
              'CloudStream',
          quality: readString(entry['quality']),
          headers: readStringMap(entry['headers']),
          isHls: readBool(entry['isM3u8']) ||
              url.toLowerCase().contains('.m3u8'),
          isDash: readBool(entry['isDash']),
          extractorName: readString(entry['extractor']),
        ),
      );
    }
    return List<StreamSource>.unmodifiable(sources);
  }

  List<SubtitleTrack> mapSubtitles(Map<String, Object?> raw) {
    final tracks = <SubtitleTrack>[];
    for (final entry in readMapList(raw['subtitles'])) {
      final url = readString(entry['url']);
      if (url == null || !url.contains('://')) continue;
      tracks.add(
        SubtitleTrack(
          url: url,
          language: readString(entry['language']) ?? 'und',
          label: readString(entry['label']),
          format: readString(entry['format']) ?? 'srt',
        ),
      );
    }
    return List<SubtitleTrack>.unmodifiable(tracks);
  }

  List<MediaItem> _items(Object? raw) {
    final items = <MediaItem>[];
    for (final entry in readMapList(raw)) {
      final item = AdapterSupport.mediaItem(entry, pluginId: info.id);
      if (item != null) items.add(item);
    }
    return List<MediaItem>.unmodifiable(items);
  }

  /// The JSON contract this adapter expects, for the host implementation and
  /// for the docs.
  static String get contractDescription => jsonEncode(<String, Object?>{
    'handshake': '<bool>',
    'loadPlugin': '{providers: [string]}',
    'getMainPage': '{sections: [{name, items: [item]}]}',
    'search': '{items: [item]}',
    'load': '{item: item, episodes: [{name, url, season, episode, data}]}',
    'loadLinks': '{links: [{url, name, quality, headers, isM3u8}], '
        'subtitles: [...]}',
  });
}
