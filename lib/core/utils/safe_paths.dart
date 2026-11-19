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

/// Whether [candidate] is a strict child of [root].
bool isWithin(String root, String candidate) =>
    p.isWithin(p.normalize(p.absolute(root)), p.normalize(p.absolute(candidate)));
