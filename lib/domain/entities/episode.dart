import '../../core/json/json_read.dart';

/// One season of an episodic item.
final class Season {
  const Season({
    required this.number,
    this.id,
    this.title,
    this.episodeCount,
    this.posterUrl,
  });

  /// 1-based season number. Specials use 0 where a plugin says so.
  final int number;

  /// Plugin-side handle when seasons are addressed separately.
  final String? id;

  final String? title;
  final int? episodeCount;
  final String? posterUrl;

  String get displayName => title ?? 'Season $number';

  Map<String, Object?> toJson() => <String, Object?>{
    'number': number,
    if (id != null) 'id': id,
    if (title != null) 'title': title,
    if (episodeCount != null) 'episodeCount': episodeCount,
    if (posterUrl != null) 'posterUrl': posterUrl,
  };

  factory Season.fromJson(Map<String, Object?> json) => Season(
    number: readInt(json['number']) ?? 1,
    id: readString(json['id']),
    title: readString(json['title']),
    episodeCount: readInt(json['episodeCount']),
    posterUrl: readString(json['posterUrl']),
  );

  @override
  bool operator ==(Object other) =>
      other is Season &&
      other.number == number &&
      other.id == id &&
      other.title == title;

  @override
  int get hashCode => Object.hash(number, id, title);
}

/// One episode, addressable by the plugin that produced it.
final class Episode {
  const Episode({
    required this.id,
    required this.url,
    required this.number,
    this.seasonNumber = 1,
    this.title,
    this.description,
    this.thumbnailUrl,
    this.airDate,
    this.runtimeMinutes,
    this.headers = const <String, String>{},
    this.extras = const <String, Object?>{},
  });

  final String id;
  final String url;
  final int number;
  final int seasonNumber;
  final String? title;
  final String? description;
  final String? thumbnailUrl;
  final DateTime? airDate;
  final int? runtimeMinutes;
  final Map<String, String> headers;
  final Map<String, Object?> extras;

  String get displayName {
    final name = title?.trim();
    if (name == null || name.isEmpty) return 'Episode $number';
    if (name.toLowerCase() == 'episode $number') return name;
    return '$number. $name';
  }

  String get label => 'S${_two(seasonNumber)}E${_two(number)}';

  static String _two(int value) => value.toString().padLeft(2, '0');

  Episode copyWith({
    String? id,
    String? url,
    int? number,
    int? seasonNumber,
    String? title,
    String? description,
    String? thumbnailUrl,
    DateTime? airDate,
    int? runtimeMinutes,
    Map<String, String>? headers,
    Map<String, Object?>? extras,
  }) =>
      Episode(
        id: id ?? this.id,
        url: url ?? this.url,
        number: number ?? this.number,
        seasonNumber: seasonNumber ?? this.seasonNumber,
        title: title ?? this.title,
        description: description ?? this.description,
        thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
        airDate: airDate ?? this.airDate,
        runtimeMinutes: runtimeMinutes ?? this.runtimeMinutes,
        headers: headers ?? this.headers,
        extras: extras ?? this.extras,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'url': url,
    'number': number,
    'seasonNumber': seasonNumber,
    if (title != null) 'title': title,
    if (description != null) 'description': description,
    if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
    if (airDate != null) 'airDate': airDate!.toIso8601String(),
    if (runtimeMinutes != null) 'runtimeMinutes': runtimeMinutes,
    if (headers.isNotEmpty) 'headers': headers,
    if (extras.isNotEmpty) 'extras': extras,
  };

  factory Episode.fromJson(Map<String, Object?> json) => Episode(
    id: readString(json['id']) ?? readString(json['url']) ?? '',
    url: readString(json['url']) ?? '',
    number: readInt(json['number']) ?? readInt(json['episode']) ?? 1,
    seasonNumber: readInt(json['seasonNumber']) ?? readInt(json['season']) ?? 1,
    title: readString(json['title']) ?? readString(json['name']),
    description: readString(json['description']),
    thumbnailUrl: readString(json['thumbnailUrl']),
    airDate: readDate(json['airDate']),
    runtimeMinutes: readInt(json['runtimeMinutes']),
    headers: readStringMap(json['headers']),
    extras: readMap(json['extras']),
  );

  @override
  bool operator ==(Object other) =>
      other is Episode &&
      other.id == id &&
      other.url == url &&
      other.number == number &&
      other.seasonNumber == seasonNumber &&
      other.title == title;

  @override
  int get hashCode => Object.hash(id, url, number, seasonNumber, title);

  @override
  String toString() => 'Episode($label, $url)';
}
