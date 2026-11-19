import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/json/json_read.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/media_item.dart';

/// Helpers shared by every ecosystem adapter.
///
/// Adapters are pure mapping: they take untrusted JSON from the runtime and
/// produce domain objects, or nothing. Nothing here throws, and nothing here
/// trusts a field's declared type.
abstract final class AdapterSupport {
  /// A stable identity for an item.
  ///
  /// Plugins identify items by URL, by title, or by an id buried in an extra
  /// field — and the same item must keep the same id across refreshes so that
  /// library rows and resume positions survive. A short hash of the plugin's
  /// own handle gives that without trusting the handle's length.
  static String itemId(String pluginId, {String? url, String? title}) {
    final handle = url ?? title ?? '';
    final digest = sha1.convert(utf8.encode(handle)).toString();
    return '$pluginId:${digest.substring(0, 16)}';
  }

  /// Reads a poster/backdrop URL, tolerating protocol-relative and relative
  /// forms against [baseUrl].
  static String? imageUrl(Object? raw, {String? baseUrl}) {
    final value = readString(raw);
    if (value == null) return null;
    if (value.startsWith('//')) return 'https:$value';
    if (value.startsWith('/') && baseUrl != null) {
      final base = Uri.tryParse(baseUrl);
      if (base != null) return base.resolve(value).toString();
    }
    if (!value.contains('://') && baseUrl != null) {
      final base = Uri.tryParse(baseUrl);
      if (base != null) return base.resolve(value).toString();
    }
    return value;
  }

  /// Normalises the many shapes a "list of items" arrives in.
  static List<Map<String, Object?>> items(Object? raw) {
    if (raw is List) return readMapList(raw);
    if (raw is Map) {
      // Some plugins wrap: `{items: [...]}`, `{results: [...]}`.
      for (final key in const <String>['items', 'results', 'data', 'list']) {
        final nested = raw[key];
        if (nested is List) return readMapList(nested);
      }
    }
    return const <Map<String, Object?>>[];
  }

  /// A rating in 0..10, from `score`, `rating` or `voteAverage`.
  static double? rating(Object? raw) {
    final value = readDouble(raw);
    if (value == null) return null;
    if (value < 0) return null;
    if (value > 10 && value <= 100) return value / 10;
    return value > 10 ? 10 : value;
  }

  /// Releases years like `2024`, `2024-05-01` and `"2024"`.
  static int? year(Object? raw) {
    final direct = readInt(raw);
    if (direct != null && direct > 1800 && direct < 2200) return direct;
    final text = readString(raw);
    if (text == null || text.length < 4) return null;
    final candidate = int.tryParse(text.substring(0, 4));
    if (candidate == null || candidate < 1800 || candidate > 2200) return null;
    return candidate;
  }

  /// Builds a [MediaItem] from the fields every ecosystem shares.
  static MediaItem? mediaItem(
    Map<String, Object?> raw, {
    required String pluginId,
    String? baseUrl,
    MediaType? defaultType,
  }) {
    final title = readString(raw['title']) ??
        readString(raw['name']) ??
        readString(raw['display_name']);
    if (title == null) return null;

    final url = readString(raw['url']) ??
        readString(raw['link']) ??
        readString(raw['href']);
    final type = defaultType ??
        MediaType.fromWire(
          raw['type'] ?? raw['tvType'] ?? raw['mediaType'],
        );

    return MediaItem(
      id: itemId(pluginId, url: url, title: title),
      pluginId: pluginId,
      title: title,
      originalTitle: readString(raw['originalTitle']) ??
          readString(raw['original_title']),
      type: type,
      url: url,
      posterUrl: imageUrl(
        raw['posterUrl'] ?? raw['poster'] ?? raw['image'] ?? raw['thumbnail'],
        baseUrl: baseUrl,
      ),
      backdropUrl: imageUrl(
        raw['bannerUrl'] ?? raw['backdropUrl'] ?? raw['backdrop'] ?? raw['cover'],
        baseUrl: baseUrl,
      ),
      year: year(raw['year'] ?? raw['releaseDate'] ?? raw['release_date']),
      rating: rating(raw['score'] ?? raw['rating'] ?? raw['voteAverage']),
      description: readString(raw['description']) ?? readString(raw['plot']),
      genres: readStringList(raw['tags'] ?? raw['genres']),
      status: readString(raw['status']),
      headers: readStringMap(raw['headers']),
      extras: <String, Object?>{
        'isAdult': readBool(raw['isAdult']),
        if (raw['syncData'] != null) 'syncData': raw['syncData'],
        if (raw['logoUrl'] != null) 'logoUrl': raw['logoUrl'],
      },
    );
  }

  /// Reads a subtitle list from the shapes plugins use.
  static List<Map<String, Object?>> subtitles(Object? raw) {
    if (raw is List) return readMapList(raw);
    if (raw is Map) {
      final out = <Map<String, Object?>>[];
      for (final entry in raw.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is String) {
          out.add(<String, Object?>{'url': value, 'language': key});
        } else if (value is Map) {
          out.add(<String, Object?>{
            'url': value['url'] ?? value['link'],
            'language': value['language'] ?? key,
            'label': value['label'] ?? value['name'],
          });
        }
      }
      return out;
    }
    return const <Map<String, Object?>>[];
  }
}
