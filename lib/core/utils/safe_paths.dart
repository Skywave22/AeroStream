import 'package:path/path.dart' as p;

/// A plugin id that is safe to use as a single directory name.
///
/// Reverse-DNS-ish, no separators, never leading dot, so `.`, `..` and hidden
/// paths are impossible. Length is deliberately unbounded: containment is what
/// keeps us safe, and a length cap only breaks a legitimate plugin later.
final RegExp _safeSegment = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

bool isSafeSegment(String value) =>
    _safeSegment.hasMatch(value) && value != '.' && value != '..';

/// Resolves [relative] under [root], returning the absolute path only when it
/// stays strictly inside [root].
///
/// This is the load-bearing check for extraction and deletion: it rejects
/// absolute segments (`/etc/passwd` has no `..`), backslash-authored archives,
/// and symlink-free `..` escapes.
String? resolveWithin(String root, String relative) {
  if (relative.isEmpty) return null;
  final normalizedRelative = relative.replaceAll(r'\', '/');
  if (p.isAbsolute(normalizedRelative)) return null;
  final normalizedRoot = p.normalize(p.absolute(root));
  final resolved = p.normalize(p.join(normalizedRoot, normalizedRelative));
  if (resolved == normalizedRoot) return null;
  if (!p.isWithin(normalizedRoot, resolved)) return null;
  return resolved;
}

/// Whether [relative] is a plain, contained relative path.
///
/// Rejects absolute paths (which discard the root when joined), Windows
/// separators, drive letters, and any `..` segment. Used on archive entries
/// before they are written.
bool isSafeRelativePath(String relative) {
  if (relative.isEmpty) return false;
  final normalized = relative.replaceAll(r'\', '/');
  if (p.isAbsolute(normalized)) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return false;
  final segments = normalized.split('/');
  for (final segment in segments) {
    if (segment == '..') return false;
  }
  return true;
}

/// Whether [candidate] is a strict child of [root].
bool isWithin(String root, String candidate) => p.isWithin(
    p.normalize(p.absolute(root)), p.normalize(p.absolute(candidate)));
