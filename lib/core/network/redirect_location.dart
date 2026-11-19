/// One hop of a redirect, as a URL.
///
/// Kept in `core` because the HTTP layer and the repository resolver both need
/// it, and neither should have to import the other.
Uri? parseRedirectLocation(String? location, Uri base) {
  if (location == null || location.trim().isEmpty) return null;
  final target = Uri.tryParse(location.trim());
  if (target == null) return null;
  final resolved = target.hasScheme ? target : base.resolveUri(target);
  if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
  // cutt.ly answers 404 pages with a redirect of their own.
  final path = resolved.path.toLowerCase();
  if (path.contains('/404') || path == '/' || path.isEmpty) return null;
  return resolved;
}
