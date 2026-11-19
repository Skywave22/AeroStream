import '../../core/json/json_read.dart';
import 'enums.dart';

/// One catalogue entry, as the rest of the app sees it.
///
/// A [MediaItem] is deliberately *thin*: it carries what a grid needs plus the
/// plugin-specific `url` handle used to ask for more. Full metadata arrives
/// later as `MediaDetails` from the same plugin.
final class MediaItem {
  const MediaItem({
    required this.id,
    required this.pluginId,
    required this.title,
    this.type = MediaType.other,
    this.url,
    this.originalTitle,
    this.posterUrl,
    this.backdropUrl,
    this.year,
    this.rating,
    this.description,
    this.genres = const <String>[],
    this.status,
    this.headers = const <String, String>{},
    this.extras = const <String, Object?>{},
  });

  /// Stable identity: `<pluginId>:<url|title>`. Used for keys, library rows
  /// and resume state, so it must not change between refreshes.
  final String id;

  /// Which plugin produced this item.
  final String pluginId;

  final String title;
  final String? originalTitle;
  final MediaType type;

  /// The plugin's own handle for this item (a URL, a slug, a JSON blob).
  final String? url;

  final String? posterUrl;
  final String? backdropUrl;
  final int? year;

  /// 0..10 when the plugin reports a score.
  final double? rating;

  final String? description;
  final List<String> genres;

  /// `ongoing`, `completed`, `upcoming`, … as the plugin spells it.
  final String? status;

  /// Headers the plugin wants sent when fetching this item's artwork or
  /// streams (typically a `Referer`).
  final Map<String, String> headers;

  /// Ecosystem-specific leftovers. Never interpreted by the UI.
  final Map<String, Object?> extras;

  bool get hasPoster => posterUrl != null && posterUrl!.isNotEmpty;

  /// Where a details screen should ask this item's plugin for its artwork.
  Map<String, String> get imageHeaders => headers;

  MediaItem copyWith({
    String? id,
    String? pluginId,
    String? title,
    String? originalTitle,
    MediaType? type,
    String? url,
    String? posterUrl,
    String? backdropUrl,
    int? year,
    double? rating,
    String? description,
    List<String>? genres,
    String? status,
    Map<String, String>? headers,
    Map<String, Object?>? extras,
  }) =>
      MediaItem(
        id: id ?? this.id,
        pluginId: pluginId ?? this.pluginId,
        title: title ?? this.title,
        originalTitle: originalTitle ?? this.originalTitle,
        type: type ?? this.type,
        url: url ?? this.url,
        posterUrl: posterUrl ?? this.posterUrl,
        backdropUrl: backdropUrl ?? this.backdropUrl,
        year: year ?? this.year,
        rating: rating ?? this.rating,
        description: description ?? this.description,
        genres: genres ?? this.genres,
        status: status ?? this.status,
        headers: headers ?? this.headers,
        extras: extras ?? this.extras,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'pluginId': pluginId,
    'title': title,
    if (originalTitle != null) 'originalTitle': originalTitle,
    'type': type.wire,
    if (url != null) 'url': url,
    if (posterUrl != null) 'posterUrl': posterUrl,
    if (backdropUrl != null) 'backdropUrl': backdropUrl,
    if (year != null) 'year': year,
    if (rating != null) 'rating': rating,
    if (description != null) 'description': description,
    if (genres.isNotEmpty) 'genres': genres,
    if (status != null) 'status': status,
    if (headers.isNotEmpty) 'headers': headers,
    if (extras.isNotEmpty) 'extras': extras,
  };

  factory MediaItem.fromJson(Map<String, Object?> json) => MediaItem(
    id: readString(json['id']) ?? '',
    pluginId: readString(json['pluginId']) ?? '',
    title: readString(json['title']) ?? 'Untitled',
    originalTitle: readString(json['originalTitle']),
    type: MediaType.fromWire(json['type']),
    url: readString(json['url']),
    posterUrl: readString(json['posterUrl']),
    backdropUrl: readString(json['backdropUrl']),
    year: readInt(json['year']),
    rating: readDouble(json['rating']),
    description: readString(json['description']),
    genres: readStringList(json['genres']),
    status: readString(json['status']),
    headers: readStringMap(json['headers']),
    extras: readMap(json['extras']),
  );

  @override
  bool operator ==(Object other) =>
      other is MediaItem &&
      other.id == id &&
      other.pluginId == pluginId &&
      other.title == title &&
      other.type == type &&
      other.url == url &&
      other.posterUrl == posterUrl &&
      other.backdropUrl == backdropUrl &&
      other.year == year &&
      other.rating == rating;

  @override
  int get hashCode => Object.hash(
    id,
    pluginId,
    title,
    type,
    url,
    posterUrl,
    backdropUrl,
    year,
    rating,
  );

  @override
  String toString() => 'MediaItem($id, $title, ${type.wire})';
}
