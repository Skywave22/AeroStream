/// One hop of a redirect, as a URL.
///
/// Kept in `core` because the HTTP layer and the repository resolver both need
/// it, and neither should have to import the other.
Uri? parseRedirectLocation(String? location, Uri base) {
  if (location == null || location.trim().isEmpty) return null;
  return _followable(location.trim(), base);
}

/// Where a shortener's *page* points, when it answers 200 instead of a 302.
///
/// `cutt.ly` and `py.md` do both: a link that exists usually redirects, but an
/// interstitial, a consent wall or a "you are leaving" page comes back as HTML
/// with the destination in a meta refresh or a `window.location` assignment.
/// Reading only the header made a working shortcode that had taken the page
/// route look like a dead code.
Uri? parseRedirectPage(String? body, Uri base) {
  if (body == null || body.isEmpty) return null;

  // Meta refreshes are written in every attribute order and quote style, so
  // the tag is scanned as a whole instead of matched by a fixed layout.
  final tags = RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(body);
  for (final tag in tags) {
    final text = tag.group(0)!;
    if (!text.toLowerCase().contains('refresh')) continue;
    final url = RegExp(
      r'''url\s*=\s*["']?([^"'>\s]+)''',
      caseSensitive: false,
    ).firstMatch(text);
    if (url == null) continue;
    final target = _followable(_unescapeHtml(url.group(1)!), base);
    if (target != null) return target;
  }

  for (final pattern in <RegExp>[
    RegExp(
      r'''(?:window\.)?location(?:\.href)?\s*=\s*["]([^"]+)["]''',
      caseSensitive: false,
    ),
    RegExp(
      r"(?:window\.)?location(?:\.href)?\s*=\s*'([^']+)'",
      caseSensitive: false,
    ),
    RegExp(
      r'''location\.(?:replace|assign)\(\s*["']([^"']+)["']\s*\)''',
      caseSensitive: false,
    ),
  ]) {
    final match = pattern.firstMatch(body);
    if (match == null) continue;
    final target = _followable(_unescapeHtml(match.group(1)!), base);
    if (target != null) return target;
  }
  return null;
}

/// True for a status that means "that short link is not there", as opposed to
/// "the shortener refused to answer".
bool isDeadShortLink(int? status) => status == 404 || status == 410;

Uri? _followable(String target, Uri base) {
  final parsed = Uri.tryParse(target);
  if (parsed == null) return null;
  final resolved = parsed.hasScheme ? parsed : base.resolveUri(parsed);
  if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
  // A shortener's own error page is still a redirect to somewhere; it is not
  // where the code leads. cutt.ly sends 404 pages to /404, and some send the
  // visitor back to the homepage.
  final path = resolved.path.toLowerCase();
  if (path.contains('/404') || path == '/' || path.isEmpty) return null;
  return resolved;
}

String _unescapeHtml(String text) => text
    .replaceAll('&amp;', '&')
    .replaceAll('&#38;', '&')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('\\/', '/');
