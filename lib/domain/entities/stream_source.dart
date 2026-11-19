import '../../core/json/json_read.dart';

/// A playable link.
///
/// [url] is what the engine hands the player; [headers] are what the plugin
/// says the origin requires (usually `Referer` and `User-Agent`), and the
/// player must forward them or the CDN will refuse the stream.
final class StreamSource {
  const StreamSource({
    required this.url,
    this.label = 'Default',
    this.quality,
    this.headers = const <String, String>{},
    this.isHls = false,
    this.isDash = false,
    this.extractorName,
    this.audioLanguage,
    this.sizeBytes,
    this.requiresProxy = false,
  });

  final String url;
  final String label;

  /// `1080p`, `720`, `Auto`, … exactly as the plugin labelled it.
  final String? quality;

  final Map<String, String> headers;
  final bool isHls;
  final bool isDash;

  /// Which extractor resolved this link, when the plugin says.
  final String? extractorName;
  final String? audioLanguage;
  final int? sizeBytes;

  /// True when the link only works through AeroStream's own proxy (e.g. the
  /// origin rejects unknown IPs or needs playlists rewritten).
  final bool requiresProxy;

  /// Whether the player can seek — live HLS usually cannot.
  bool get isLive => isHls && label.toLowerCase().contains('live');

  /// A stable key for the source picker.
  String get key => '$label|${quality ?? ''}|$url';

  StreamSource copyWith({
    String? url,
    String? label,
    String? quality,
    Map<String, String>? headers,
    bool? isHls,
    bool? isDash,
    String? extractorName,
    String? audioLanguage,
    int? sizeBytes,
    bool? requiresProxy,
  }) =>
      StreamSource(
        url: url ?? this.url,
        label: label ?? this.label,
        quality: quality ?? this.quality,
        headers: headers ?? this.headers,
        isHls: isHls ?? this.isHls,
        isDash: isDash ?? this.isDash,
        extractorName: extractorName ?? this.extractorName,
        audioLanguage: audioLanguage ?? this.audioLanguage,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        requiresProxy: requiresProxy ?? this.requiresProxy,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'label': label,
        if (quality != null) 'quality': quality,
        if (headers.isNotEmpty) 'headers': headers,
        if (isHls) 'isHls': true,
        if (isDash) 'isDash': true,
        if (extractorName != null) 'extractorName': extractorName,
        if (audioLanguage != null) 'audioLanguage': audioLanguage,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        if (requiresProxy) 'requiresProxy': true,
      };

  factory StreamSource.fromJson(Map<String, Object?> json) {
    final url = readString(json['url']) ?? '';
    final explicitType = readString(json['type'])?.toLowerCase();
    final lowerUrl = url.toLowerCase();
    return StreamSource(
      url: url,
      label:
          readString(json['label']) ?? readString(json['server']) ?? 'Default',
      quality: readString(json['quality']),
      headers: readStringMap(json['headers']),
      isHls: readBool(json['isHls']) ||
          explicitType == 'm3u8' ||
          explicitType == 'hls' ||
          lowerUrl.contains('.m3u8'),
      isDash: readBool(json['isDash']) ||
          explicitType == 'mpd' ||
          explicitType == 'dash' ||
          lowerUrl.contains('.mpd'),
      extractorName: readString(json['extractorName']),
      audioLanguage: readString(json['audioLanguage']),
      sizeBytes: readInt(json['sizeBytes']),
      requiresProxy: readBool(json['requiresProxy']),
    );
  }

  @override
  bool operator ==(Object other) => other is StreamSource && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() =>
      'StreamSource($label${quality == null ? '' : ' $quality'})';
}

/// A subtitle file the player can load alongside a stream.
final class SubtitleTrack {
  const SubtitleTrack({
    required this.url,
    required this.language,
    this.label,
    this.format = 'vtt',
    this.headers = const <String, String>{},
    this.isDefault = false,
  });

  final String url;

  /// ISO-639-1 where known (`en`, `hi`).
  final String language;
  final String? label;

  /// `vtt`, `srt`, `ass`.
  final String format;

  final Map<String, String> headers;
  final bool isDefault;

  String get displayName {
    final name = label?.trim();
    if (name != null && name.isNotEmpty) return name;
    return language.toUpperCase();
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'url': url,
        'language': language,
        if (label != null) 'label': label,
        'format': format,
        if (headers.isNotEmpty) 'headers': headers,
        if (isDefault) 'isDefault': true,
      };

  factory SubtitleTrack.fromJson(Map<String, Object?> json) => SubtitleTrack(
        url: readString(json['url']) ?? '',
        language: readString(json['language']) ?? 'und',
        label: readString(json['label']),
        format: readString(json['format']) ?? 'vtt',
        headers: readStringMap(json['headers']),
        isDefault: readBool(json['isDefault']),
      );

  @override
  bool operator ==(Object other) =>
      other is SubtitleTrack && other.url == url && other.language == language;

  @override
  int get hashCode => Object.hash(url, language);
}

/// What a plugin returns when asked to resolve playback.
final class StreamResult {
  const StreamResult({
    this.sources = const <StreamSource>[],
    this.subtitles = const <SubtitleTrack>[],
    this.diagnostics = const <String>[],
  });

  final List<StreamSource> sources;
  final List<SubtitleTrack> subtitles;

  /// Non-fatal notes a plugin volunteered (e.g. "source 3 needed a captcha").
  final List<String> diagnostics;

  bool get isEmpty => sources.isEmpty;

  /// Best source first: higher quality, then non-proxy, then HLS.
  List<StreamSource> get orderedSources {
    final ranked = sources.toList(growable: false);
    final withIndex = <(int, StreamSource)>[];
    for (var i = 0; i < ranked.length; i++) {
      withIndex.add((i, ranked[i]));
    }
    withIndex.sort((a, b) {
      final scoreA = _score(a.$2);
      final scoreB = _score(b.$2);
      if (scoreA != scoreB) return scoreB.compareTo(scoreA);
      return a.$1.compareTo(b.$1);
    });
    return withIndex.map((entry) => entry.$2).toList(growable: false);
  }

  /// Sources re-ordered for a user who expressed a quality preference.
  ///
  /// The preference is a *filter the user chose*, not a hard requirement: if
  /// nothing matches, the full list comes back in its natural order rather
  /// than an empty screen. A cap (`720p` prefers at most that height) is more
  /// useful than an exact match, because plugins label the same stream `720`,
  /// `720p` and `HD` in the same repository.
  List<StreamSource> preferredSources({
    String? preferredQuality,
    bool preferHls = true,
  }) {
    final ordered = List<StreamSource>.of(orderedSources);
    if (preferHls && ordered.length > 1) {
      // A stable partition: HLS first, everything else after, within each
      // group keeping the quality ranking.
      final hls = ordered.where((source) => source.isHls).toList(growable: false);
      final rest = ordered
          .where((source) => !source.isHls)
          .toList(growable: false);
      ordered
        ..clear()
        ..addAll(hls)
        ..addAll(rest);
    }

    final target = _heightOf(preferredQuality ?? '');
    if (target == null) return ordered;

    final matching = ordered
        .where((source) {
          final height = _heightOf(source.quality ?? '');
          return height != null && height <= target;
        })
        .toList(growable: false);
    return matching.isEmpty ? ordered : matching;
  }

  /// `720p` -> 720, `4k` -> 2160, `auto`/empty -> null.
  static int? _heightOf(String quality) {
    final normalized = quality.toLowerCase().trim();
    if (normalized.isEmpty || normalized == 'auto') return null;
    final digits = RegExp(r'(\d{3,4})').firstMatch(normalized)?.group(1);
    final height = int.tryParse(digits ?? '');
    if (height != null) return height;
    if (normalized.contains('4k') || normalized.contains('2160')) return 2160;
    if (normalized == 'hd') return 1080;
    if (normalized == 'sd') return 480;
    return null;
  }

  static int _score(StreamSource source) {
    var score = 0;
    final quality = source.quality?.toLowerCase() ?? '';
    final digits = RegExp(r'(\d{3,4})').firstMatch(quality)?.group(1);
    final height = int.tryParse(digits ?? '');
    if (height != null) {
      score += height ~/ 100;
    } else if (quality.contains('4k')) {
      score += 21;
    } else if (quality.contains('auto')) {
      score += 5;
    }
    if (!source.requiresProxy) score += 2;
    if (source.isHls) score += 1;
    return score;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'sources':
            sources.map((source) => source.toJson()).toList(growable: false),
        'subtitles':
            subtitles.map((track) => track.toJson()).toList(growable: false),
        if (diagnostics.isNotEmpty) 'diagnostics': diagnostics,
      };

  factory StreamResult.fromJson(Map<String, Object?> json) => StreamResult(
        sources: readMapList(
          json['sources'],
        ).map(StreamSource.fromJson).toList(growable: false),
        subtitles: readMapList(
          json['subtitles'],
        ).map(SubtitleTrack.fromJson).toList(growable: false),
        diagnostics: readStringList(json['diagnostics']),
      );

  static const StreamResult empty = StreamResult();

  @override
  String toString() => 'StreamResult(${sources.length} sources)';
}
