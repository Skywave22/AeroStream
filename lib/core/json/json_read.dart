/// Lenient readers for untrusted JSON.
///
/// Plugin payloads are attacker-controlled. Every read here is total: it never
/// throws, it coerces where the value is unambiguous, and it returns `null`
/// (or the supplied fallback) otherwise. Adapters layer their own validation on
/// top of these.
library;

String? readString(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (value is num || value is bool) return value.toString();
  return null;
}

int? readInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.isFinite ? value.round() : null;
  if (value is String) return int.tryParse(value.trim());
  if (value is bool) return value ? 1 : 0;
  return null;
}

double? readDouble(Object? value) {
  if (value == null) return null;
  if (value is double) return value.isFinite ? value : null;
  if (value is int) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

bool readBool(Object? value, {bool fallback = false}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' ||
        normalized == '1' ||
        normalized == 'yes' ||
        normalized == 'on') {
      return true;
    }
    if (normalized == 'false' ||
        normalized == '0' ||
        normalized == 'no' ||
        normalized == 'off') {
      return false;
    }
  }
  return fallback;
}

/// Reads a list of strings, dropping entries that are not strings.
List<String> readStringList(Object? value) {
  if (value is List) {
    return value.map(readString).whereType<String>().toList(growable: false);
  }
  final single = readString(value);
  return single == null ? const <String>[] : <String>[single];
}

/// Reads a `{String: String}` map, dropping non-string entries.
Map<String, String> readStringMap(Object? value) {
  final result = <String, String>{};
  if (value is Map) {
    for (final entry in value.entries) {
      final key = readString(entry.key);
      final val = readString(entry.value);
      if (key != null && val != null) result[key] = val;
    }
  }
  return result;
}

/// Reads a JSON object as a `Map<String, Object?>`, or an empty map.
Map<String, Object?> readMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = readString(entry.key);
      if (key != null) result[key] = entry.value;
    }
    return result;
  }
  return const <String, Object?>{};
}

/// Reads a list of JSON objects, dropping entries that are not objects.
List<Map<String, Object?>> readMapList(Object? value) {
  if (value is List) {
    return value
        .whereType<Map<Object?, Object?>>()
        .map(readMap)
        .toList(growable: false);
  }
  return const <Map<String, Object?>>[];
}

/// Reads a list, returning an empty list for anything else.
List<Object?> readList(Object? value) =>
    value is List ? value.toList(growable: false) : const <Object?>[];

/// Parses an ISO-8601 date or a `YYYY-MM-DD` prefix, returning `null` if
/// neither works. Plugin dates are frequently malformed; that is not an error.
DateTime? readDate(Object? value) {
  final raw = readString(value);
  if (raw == null) {
    if (value is DateTime) return value;
    return null;
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed != null) return parsed;
  if (raw.length >= 10) return DateTime.tryParse(raw.substring(0, 10));
  return null;
}
