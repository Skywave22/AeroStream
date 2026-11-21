import '../../../core/errors/plugin_error.dart';
import '../../../core/json/json_read.dart';
import '../../../core/result.dart';
import '../../../domain/entities/episode.dart';
import '../../../domain/entities/home_section.dart';
import '../../../domain/entities/media_details.dart';
import '../../../domain/entities/media_item.dart';
import '../../../domain/entities/plugin_info.dart';
import '../../../domain/entities/stream_source.dart';
import '../../../domain/media_provider.dart';
import '../adapter_support.dart';
import 'cloudstream_bridge.dart';

/// Adapts every provider registered by one CloudStream extension.
///
/// A `.cs3` can register several `MainAPI`s. AeroStream keeps one runtime per
/// installed extension, but searches and builds home rows from all of them. The
/// provider name is attached to every item so details and `loadLinks` route
/// back to the exact API that produced it.
final class CloudStreamAdapter implements MediaProvider {
  CloudStreamAdapter({
    required this.info,
    required CloudStreamBridge bridge,
    required this.artifactPath,
    List<Map<String, Object?>> providers = const <Map<String, Object?>>[],
    String? providerName,
  })  : _bridge = bridge,
        _providers = providers.isNotEmpty
            ? List<Map<String, Object?>>.unmodifiable(providers)
            : providerName == null
                ? const <Map<String, Object?>>[]
                : <Map<String, Object?>>[
                    <String, Object?>{'name': providerName},
                  ];

  @override
  final PluginInfo info;
  final CloudStreamBridge _bridge;
  final String artifactPath;
  final List<Map<String, Object?>> _providers;

  static const _providerKey = 'cloudstreamProvider';
  static const _dataKey = 'cloudstreamData';

  @override
  PluginCapabilities get capabilities => info.capabilities;

  List<String> get providerNames => _providers
      .map((provider) => readString(provider['name']))
      .whereType<String>()
      .where((name) => name.isNotEmpty)
      .toList(growable: false);

  @override
  Future<Result<List<HomeSection>>> getHome() async {
    if (!capabilities.home) return _unsupported('mainPage');
    final names = providerNames;
    if (names.isEmpty) return _noProviders<List<HomeSection>>();

    final sections = <HomeSection>[];
    PluginError? firstError;
    var answered = false;
    for (final provider in names) {
      final response = await _call('mainPage', <String, Object?>{
        'provider': provider,
        'page': 1,
        'plugin': artifactPath,
      });
      switch (response) {
        case Err<Map<String, Object?>>(:final error):
          firstError ??= error;
        case Ok<Map<String, Object?>>(:final value):
          answered = true;
          for (final section in readMapList(value['sections'])) {
            final items = readMapList(section['items'])
                .map((raw) => _mediaItem(raw, provider))
                .whereType<MediaItem>()
                .toList(growable: false);
            if (items.isEmpty) continue;
            final sectionName = readString(section['name']) ?? provider;
            sections.add(
              HomeSection(
                title: names.length == 1
                    ? sectionName
                    : '$provider · $sectionName',
                items: items,
                pluginId: info.id,
              ),
            );
          }
      }
    }
    if (!answered && firstError != null) {
      return Err<List<HomeSection>>(firstError);
    }
    return Ok<List<HomeSection>>(List<HomeSection>.unmodifiable(sections));
  }

  @override
  Future<Result<SearchPage>> search(String query, {int page = 1}) async {
    if (!capabilities.search) return _unsupported('search');
    final names = providerNames;
    if (names.isEmpty) return _noProviders<SearchPage>();

    final items = <MediaItem>[];
    var hasMore = false;
    var answered = false;
    PluginError? firstError;
    for (final provider in names) {
      final response = await _call('search', <String, Object?>{
        'provider': provider,
        'query': query,
        'page': page,
        'plugin': artifactPath,
      });
      switch (response) {
        case Err<Map<String, Object?>>(:final error):
          firstError ??= error;
        case Ok<Map<String, Object?>>(:final value):
          answered = true;
          hasMore = hasMore || readBool(value['hasNext']);
          items.addAll(
            readMapList(
              value['items'],
            ).map((raw) => _mediaItem(raw, provider)).whereType<MediaItem>(),
          );
      }
    }
    if (!answered && firstError != null) return Err<SearchPage>(firstError);
    return Ok<SearchPage>(
      SearchPage(
        items: List<MediaItem>.unmodifiable(items),
        pluginId: info.id,
        hasMore: hasMore,
        nextPage: hasMore ? page + 1 : null,
      ),
    );
  }

  @override
  Future<Result<MediaDetails>> getDetails(MediaItem item) async {
    if (!capabilities.details) return _unsupported('load');
    final provider = _providerFor(item);
    final url = item.url;
    if (provider == null || url == null || url.isEmpty) {
      return Err<MediaDetails>(
        PluginParseError(
          provider == null
              ? 'No CloudStream provider owns this item'
              : 'The item has no CloudStream URL',
          pluginId: info.id,
          field: provider == null ? _providerKey : 'url',
        ),
      );
    }

    final response = await _call('load', <String, Object?>{
      'provider': provider,
      'url': url,
      'plugin': artifactPath,
    });
    return switch (response) {
      Err<Map<String, Object?>>(:final error) => Err<MediaDetails>(error),
      Ok<Map<String, Object?>>(:final value) => _detailsFrom(
          value,
          item,
          provider,
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
    if (!capabilities.streams) return _unsupported('loadLinks');
    final provider = _providerFor(item);
    final data = episode == null
        ? readString(item.extras[_dataKey]) ?? item.url
        : readString(episode.extras[_dataKey]) ?? episode.url;
    if (provider == null || data == null || data.isEmpty) {
      return Err<StreamResult>(
        PluginParseError(
          provider == null
              ? 'No CloudStream provider owns this playback request'
              : 'Nothing to resolve: CloudStream returned no opaque link data',
          pluginId: info.id,
          field: provider == null ? _providerKey : _dataKey,
        ),
      );
    }

    final response = await _call('loadLinks', <String, Object?>{
      'provider': provider,
      'data': data,
      'timeoutMs': 30000,
      'plugin': artifactPath,
    });
    return switch (response) {
      Err<Map<String, Object?>>(:final error) => Err<StreamResult>(error),
      Ok<Map<String, Object?>>(:final value) => Ok<StreamResult>(
          _streamResult(value),
        ),
    };
  }

  Result<MediaDetails> _detailsFrom(
    Map<String, Object?> raw,
    MediaItem fallback,
    String provider,
  ) {
    final mapped = _mediaItem(raw, provider);
    var item = mapped == null ? fallback : _merge(mapped, fallback);
    final dataUrl = readString(raw['dataUrl']);
    item = item.copyWith(
      extras: <String, Object?>{
        ...item.extras,
        _providerKey: provider,
        if (dataUrl != null) _dataKey: dataUrl,
      },
    );

    final episodes = <Episode>[];
    var sequence = 0;
    for (final episode in readMapList(raw['episodes'])) {
      sequence++;
      final data = readString(episode['data']);
      if (data == null || data.isEmpty) continue;
      final number = readInt(episode['episode']) ?? sequence;
      final season = readInt(episode['season']) ?? 1;
      episodes.add(
        Episode(
          id: AdapterSupport.itemId(
            '${info.id}:episode',
            url: '$provider\u0000$data',
          ),
          // CloudStream episode data is deliberately opaque. Keeping it as the
          // domain handle avoids inventing a URL and sends it back unchanged.
          url: data,
          number: number,
          seasonNumber: season,
          title: readString(episode['name']),
          description: readString(episode['description']),
          thumbnailUrl: AdapterSupport.imageUrl(
            episode['posterUrl'],
            baseUrl: _baseUrlFor(provider),
          ),
          airDate: _epochDate(episode['date']),
          runtimeMinutes: readInt(episode['runTime']),
          extras: <String, Object?>{
            _dataKey: data,
            _providerKey: provider,
            if (episode['dub'] != null) 'dub': episode['dub'],
            if (episode['score'] != null) 'score': episode['score'],
          },
        ),
      );
    }
    episodes.sort((a, b) {
      final season = a.seasonNumber.compareTo(b.seasonNumber);
      return season == 0 ? a.number.compareTo(b.number) : season;
    });

    final seasons = readMapList(raw['seasonNames'])
        .map(
          (season) => Season(
            number: readInt(season['season']) ?? 1,
            title: readString(season['name']) ??
                readString(season['displaySeason']),
          ),
        )
        .toList(growable: false);
    final cast = readMapList(
      raw['actors'],
    ).map(Actor.fromJson).toList(growable: false);
    final trailers = readMapList(raw['trailers'])
        .map(Trailer.fromJson)
        .where((trailer) => trailer.url.isNotEmpty)
        .toList(growable: false);
    final recommendations = readMapList(raw['recommendations'])
        .map((entry) => _mediaItem(entry, provider))
        .whereType<MediaItem>()
        .toList(growable: false);

    return Ok<MediaDetails>(
      MediaDetails(
        item: item,
        description: readString(raw['plot']) ?? item.description,
        genres: readStringList(raw['tags']),
        cast: cast,
        trailers: trailers,
        seasons: seasons,
        episodes: episodes,
        recommendations: recommendations,
        status: readString(raw['showStatus']),
        runtimeMinutes: readInt(raw['duration']),
        logoUrl: AdapterSupport.imageUrl(
          raw['logoUrl'],
          baseUrl: _baseUrlFor(provider),
        ),
        contentRating: readString(raw['contentRating']),
        headers: readStringMap(raw['posterHeaders']),
        syncData: readMap(raw['syncIds']),
      ),
    );
  }

  StreamResult _streamResult(Map<String, Object?> raw) {
    final sources = <StreamSource>[];
    for (final link in readMapList(raw['links'])) {
      final url = readString(link['url']);
      if (url == null || url.isEmpty) continue;
      final headers = <String, String>{...readStringMap(link['headers'])};
      final referer = readString(link['referer']);
      if (referer != null &&
          !headers.keys.any((key) => key.toLowerCase() == 'referer')) {
        headers['Referer'] = referer;
      }
      final wireType = readString(link['type'])?.toLowerCase() ?? '';
      final lowerUrl = url.toLowerCase();
      final qualityNumber = readInt(link['quality']);
      sources.add(
        StreamSource(
          url: url,
          label: readString(link['name']) ??
              readString(link['source']) ??
              'CloudStream',
          quality: qualityNumber != null && qualityNumber > 0
              ? '${qualityNumber}p'
              : readString(link['quality']),
          headers: headers,
          isHls: wireType.contains('m3u8') ||
              wireType.contains('hls') ||
              lowerUrl.contains('.m3u8'),
          isDash: wireType.contains('dash') ||
              wireType.contains('mpd') ||
              lowerUrl.contains('.mpd'),
          extractorName: readString(link['source']),
          requiresProxy: headers.isNotEmpty,
          isDrmProtected: link['drm'] is Map,
        ),
      );
    }

    final subtitles = readMapList(raw['subtitles'])
        .map(
          (subtitle) => SubtitleTrack(
            url: readString(subtitle['url']) ?? '',
            language: readString(subtitle['lang']) ?? 'und',
            headers: readStringMap(subtitle['headers']),
            format: _subtitleFormat(readString(subtitle['url'])),
          ),
        )
        .where((subtitle) => subtitle.url.isNotEmpty)
        .toList(growable: false);
    final diagnostics = <String>[
      if (!readBool(raw['completed']))
        'CloudStream link extraction ended before the extension completed.',
      if (readString(raw['error']) case final error?) error,
      if (readBool(raw['fullScreen']))
        'The extension completed playback through its own full-screen UI.',
    ];
    return StreamResult(
      sources: List<StreamSource>.unmodifiable(sources),
      subtitles: subtitles,
      diagnostics: diagnostics,
    );
  }

  MediaItem? _mediaItem(Map<String, Object?> raw, String provider) {
    final apiName = readString(raw['apiName']);
    final owner =
        apiName != null && providerNames.contains(apiName) ? apiName : provider;
    final normalized = <String, Object?>{
      ...raw,
      if (raw['backgroundPosterUrl'] != null)
        'backdropUrl': raw['backgroundPosterUrl'],
      if (raw['posterHeaders'] != null) 'headers': raw['posterHeaders'],
    };
    final item = AdapterSupport.mediaItem(
      normalized,
      pluginId: info.id,
      baseUrl: _baseUrlFor(owner),
    );
    if (item == null) return null;
    return item.copyWith(
      id: AdapterSupport.itemId(
        '${info.id}:$owner',
        url: item.url,
        title: item.title,
      ),
      extras: <String, Object?>{...item.extras, _providerKey: owner},
    );
  }

  MediaItem _merge(MediaItem parsed, MediaItem fallback) => parsed.copyWith(
        id: fallback.id,
        url: parsed.url ?? fallback.url,
        posterUrl: parsed.posterUrl ?? fallback.posterUrl,
        backdropUrl: parsed.backdropUrl ?? fallback.backdropUrl,
        year: parsed.year ?? fallback.year,
        rating: parsed.rating ?? fallback.rating,
        description: parsed.description ?? fallback.description,
        extras: <String, Object?>{...fallback.extras, ...parsed.extras},
      );

  String? _providerFor(MediaItem item) {
    final named = readString(item.extras[_providerKey]);
    if (named != null && providerNames.contains(named)) return named;
    return providerNames.length == 1 ? providerNames.first : null;
  }

  String? _baseUrlFor(String providerName) {
    for (final provider in _providers) {
      if (readString(provider['name']) == providerName) {
        return readString(provider['mainUrl']);
      }
    }
    return null;
  }

  DateTime? _epochDate(Object? raw) {
    final millis = readInt(raw);
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  String _subtitleFormat(String? url) {
    final path = Uri.tryParse(url ?? '')?.path.toLowerCase() ?? '';
    if (path.endsWith('.srt')) return 'srt';
    if (path.endsWith('.ass') || path.endsWith('.ssa')) return 'ass';
    return 'vtt';
  }

  Future<Result<Map<String, Object?>>> _call(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final response = await _bridge.invoke(method, arguments);
    return switch (response) {
      Ok<Map<String, Object?>>(:final value) => Ok<Map<String, Object?>>(value),
      Err<Map<String, Object?>>(:final error) => Err<Map<String, Object?>>(
          error.copyWithPlugin(info.id),
        ),
    };
  }

  Result<T> _unsupported<T>(String operation) => Err<T>(
        PluginUnsupportedError(
          'CloudStream provider does not support $operation',
          pluginId: info.id,
          operation: operation,
        ),
      );

  Result<T> _noProviders<T>() => Err<T>(
        PluginParseError(
          'The CloudStream extension registered no providers',
          pluginId: info.id,
          field: 'providers',
        ),
      );

  @override
  Future<void> dispose() async {
    // The bridge owns the shared engine; this adapter owns only its loaded DEX.
    await _bridge.invoke('unloadPlugin', <String, Object?>{
      'path': artifactPath,
    });
  }
}
