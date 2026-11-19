import '../../core/json/json_read.dart';
import 'enums.dart';
import 'episode.dart';
import 'media_item.dart';
import 'stream_source.dart';

/// A person credited on an item.
final class Actor {
  const Actor({required this.name, this.role, this.imageUrl});

  final String name;
  final String? role;
  final String? imageUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    if (role != null) 'role': role,
    if (imageUrl != null) 'imageUrl': imageUrl,
  };

  factory Actor.fromJson(Map<String, Object?> json) => Actor(
    name: readString(json['name']) ?? 'Unknown',
    role: readString(json['role']),
    imageUrl: readString(json['imageUrl']) ?? readString(json['image']),
  );

  @override
  bool operator ==(Object other) =>
      other is Actor && other.name == name && other.role == role;

  @override
  int get hashCode => Object.hash(name, role);
}

/// A trailer link supplied by a plugin.
final class Trailer {
  const Trailer({required this.url, this.name});

  final String url;
  final String? name;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    if (name != null) 'name': name,
  };

  factory Trailer.fromJson(Map<String, Object?> json) => Trailer(
    url: readString(json['url']) ?? '',
    name: readString(json['name']),
  );
}

/// Everything a details screen needs for one item.
final class MediaDetails {
  const MediaDetails({
    required this.item,
    this.description,
    this.genres = const <String>[],
    this.cast = const <Actor>[],
    this.trailers = const <Trailer>[],
    this.seasons = const <Season>[],
    this.episodes = const <Episode>[],
    this.recommendations = const <MediaItem>[],
    this.status,
    this.runtimeMinutes,
    this.logoUrl,
    this.contentRating,
    this.playbackPolicy = PlaybackPolicy.none,
    this.instantSources = const <StreamSource>[],
    this.headers = const <String, String>{},
    this.syncData = const <String, Object?>{},
  });

  final MediaItem item;
  final String? description;
  final List<String> genres;
  final List<Actor> cast;
  final List<Trailer> trailers;
  final List<Season> seasons;

  /// All episodes across all seasons; the UI groups them by [Episode.seasonNumber].
  final List<Episode> episodes;

  final List<MediaItem> recommendations;
  final String? status;
  final int? runtimeMinutes;
  final String? logoUrl;
  final String? contentRating;
  final PlaybackPolicy playbackPolicy;

  /// Sources the plugin resolved up front ("instant load"), so the player can
  /// skip a round-trip when the user presses play.
  final List<StreamSource> instantSources;

  final Map<String, String> headers;

  /// External-metadata ids a plugin volunteers (Trakt, AniList, …).
  final Map<String, Object?> syncData;

  bool get isEpisodic => episodes.isNotEmpty || seasons.isNotEmpty;

  /// Seasons derived from episodes when the plugin only listed episodes.
  List<Season> get effectiveSeasons {
    if (seasons.isNotEmpty) return seasons;
    final byNumber = <int, int>{};
    for (final episode in episodes) {
      byNumber.update(
        episode.seasonNumber,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final numbers = byNumber.keys.toList()..sort();
    return numbers
        .map(
          (number) =>
              Season(number: number, episodeCount: byNumber[number] ?? 0),
        )
        .toList(growable: false);
  }

  List<Episode> episodesOf(int seasonNumber) => episodes
      .where((episode) => episode.seasonNumber == seasonNumber)
      .toList(growable: false)
    ..sort((a, b) => a.number.compareTo(b.number));

  Map<String, Object?> toJson() => <String, Object?>{
    'item': item.toJson(),
    if (description != null) 'description': description,
    if (genres.isNotEmpty) 'genres': genres,
    'cast': cast.map((actor) => actor.toJson()).toList(growable: false),
    'trailers': trailers.map((trailer) => trailer.toJson()).toList(
      growable: false,
    ),
    'seasons': seasons.map((season) => season.toJson()).toList(growable: false),
    'episodes': episodes.map((episode) => episode.toJson()).toList(
      growable: false,
    ),
    'recommendations': recommendations
        .map((item) => item.toJson())
        .toList(growable: false),
    if (status != null) 'status': status,
    if (runtimeMinutes != null) 'runtimeMinutes': runtimeMinutes,
    if (logoUrl != null) 'logoUrl': logoUrl,
    if (contentRating != null) 'contentRating': contentRating,
    'playbackPolicy': playbackPolicy.name,
    'instantSources': instantSources
        .map((source) => source.toJson())
        .toList(growable: false),
    if (headers.isNotEmpty) 'headers': headers,
    if (syncData.isNotEmpty) 'syncData': syncData,
  };

  factory MediaDetails.fromJson(Map<String, Object?> json) => MediaDetails(
    item: MediaItem.fromJson(readMap(json['item'])),
    description: readString(json['description']),
    genres: readStringList(json['genres']),
    cast: readMapList(json['cast']).map(Actor.fromJson).toList(growable: false),
    trailers: readMapList(json['trailers'])
        .map(Trailer.fromJson)
        .toList(growable: false),
    seasons: readMapList(json['seasons'])
        .map(Season.fromJson)
        .toList(growable: false),
    episodes: readMapList(json['episodes'])
        .map(Episode.fromJson)
        .toList(growable: false),
    recommendations: readMapList(
      json['recommendations'],
    ).map(MediaItem.fromJson).toList(growable: false),
    status: readString(json['status']),
    runtimeMinutes: readInt(json['runtimeMinutes']),
    logoUrl: readString(json['logoUrl']),
    contentRating: readString(json['contentRating']),
    playbackPolicy: PlaybackPolicy.fromWire(json['playbackPolicy']),
    instantSources: readMapList(
      json['instantSources'],
    ).map(StreamSource.fromJson).toList(growable: false),
    headers: readStringMap(json['headers']),
    syncData: readMap(json['syncData']),
  );

  @override
  String toString() =>
      'MediaDetails(${item.title}, ${episodes.length} episodes)';
}
