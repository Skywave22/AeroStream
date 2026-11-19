/// Version handling for plugin and repository manifests.
///
/// Manifests in the wild use three shapes for the same idea:
///   * CloudStream: an integer build number (`version: 25`);
///   * SkyStream: an integer too (`version: 1`), but repositories may publish
///     `1.2.3` strings;
///   * Vega: a semantic string (`version: "1.0"`).
///
/// [PluginVersion] normalises all of them into a comparable list of integer
/// components, so "is this an update?" has exactly one answer per ecosystem.
library;

final class PluginVersion implements Comparable<PluginVersion> {
  const PluginVersion._(this.parts, this.raw);

  /// Numeric components, most significant first. `1.2.3` -> `[1, 2, 3]`.
  final List<int> parts;

  /// The value exactly as the manifest spelled it, for display and for
  /// round-tripping an install record.
  final String raw;

  /// A version that is always older than everything else.
  static const PluginVersion none = PluginVersion._(<int>[], '0');

  factory PluginVersion.parse(Object? value) {
    if (value == null) return none;
    if (value is int) return PluginVersion._(<int>[value], value.toString());
    if (value is double) {
      return PluginVersion.parse(value.toString());
    }
    final text = value.toString().trim();
    if (text.isEmpty) return none;

    // Take the leading numeric run of each dot/slash separated chunk so that
    // `1.2.3-beta4` and `v1.2.3` both compare as 1.2.3.
    final parts = <int>[];
    for (final chunk in text.split(RegExp(r'[./_+\- ]'))) {
      final match = RegExp(r'^\D*?(\d+)').firstMatch(chunk);
      if (match == null) continue;
      final parsed = int.tryParse(match.group(1) ?? '');
      if (parsed == null) continue;
      parts.add(parsed);
    }
    if (parts.isEmpty) return PluginVersion._(<int>[], text);
    return PluginVersion._(List<int>.unmodifiable(parts), text);
  }

  bool get isNone => parts.isEmpty;

  /// Compares numeric components, missing ones as zero (`1.2 == 1.2.0`).
  @override
  int compareTo(PluginVersion other) {
    final length = parts.length > other.parts.length
        ? parts.length
        : other.parts.length;
    for (var i = 0; i < length; i++) {
      final a = i < parts.length ? parts[i] : 0;
      final b = i < other.parts.length ? other.parts[i] : 0;
      if (a != b) return a < b ? -1 : 1;
    }
    return 0;
  }

  bool operator >(PluginVersion other) => compareTo(other) > 0;

  bool operator <(PluginVersion other) => compareTo(other) < 0;

  bool operator >=(PluginVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is PluginVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hashAll(parts);

  @override
  String toString() => raw;
}

/// True when [candidate] is a strictly newer build than [installed].
bool isUpdate({
  required Object? installed,
  required Object? candidate,
}) =>
    PluginVersion.parse(candidate) > PluginVersion.parse(installed);
