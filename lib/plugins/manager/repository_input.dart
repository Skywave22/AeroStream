import '../../core/errors/plugin_error.dart';
import '../../core/result.dart';

/// What the user typed into "Add repository", after resolution.
///
/// The three ecosystems accept different things in that box, and the differences
/// are documented upstream, not invented here:
///
/// | Ecosystem | Accepts |
/// | --- | --- |
/// | CloudStream | a URL; `cloudstreamrepo://…` / `https://cs.repo/?…`; a bare shortcode that redirects through `cutt.ly` (`!code` → `py.md`) |
/// | SkyStream | the `repo.json` URL, or a `cutt.ly` shortcode alias (`sky-name`) |
/// | Vega | a GitHub/GitLab/Codeberg/Bitbucket repo or raw URL, a folder or `manifest.json` URL, or a short name (`author`, `author@cb`, `author@bb`, `author@gl`) that means `author/vega-providers` on GitHub |
///
/// A bare word is genuinely ambiguous — `author` could be a Vega author or a
/// CloudStream shortcode — so resolution is a cascade: the redirect is tried
/// first, then the Vega author, and whichever answers wins.
final class RepositoryInput {
  const RepositoryInput({
    required this.primary,
    required this.display,
    this.fallbacks = const <Uri>[],
    this.kind = RepositoryInputKind.url,
  });

  /// The URL to fetch first.
  final Uri primary;

  /// Further URLs to try, in order, when [primary] is not a repository.
  ///
  /// A Vega source is a *folder*; the manifest lives at `<folder>/manifest.json`,
  /// so a pasted folder URL needs that fallback to become fetchable.
  final List<Uri> fallbacks;

  /// What to show the user: the URL they will actually be talking to.
  final String display;

  final RepositoryInputKind kind;

  /// Every URL worth trying, primary first.
  List<Uri> get attempts => <Uri>[primary, ...fallbacks];
}

/// How an input was understood. Used for messages and for logging, not logic.
enum RepositoryInputKind {
  /// A plain http(s) URL.
  url,

  /// A repository folder or `manifest.json` URL (Vega), plus its manifest.
  vegaFolder,

  /// A `cutt.ly` / `py.md` shortcode, already resolved to a redirect target.
  shortcode,

  /// A Vega short name (`author`, `author@cb`, …).
  vegaAuthor,

  /// A `cloudstreamrepo://` deep link.
  cloudstreamDeepLink,
}

/// Resolves raw user input into fetchable URLs.
///
/// `followRedirect` is injected so this stays a pure function of its inputs and
/// can be tested without a network. It should return the redirect target, or
/// null when the server does not redirect.
final class RepositoryInputResolver {
  const RepositoryInputResolver({required this.followRedirect});

  final Future<Uri?> Function(Uri url) followRedirect;

  /// Hosts that publish raw repository content, keyed by the short suffix Vega
  /// uses (`author@cb`).
  static const Map<String, String> vegaHostSuffixes = <String, String>{
    'gh': 'github',
    'cb': 'codeberg',
    'bb': 'bitbucket',
    'gl': 'gitlab',
  };

  /// The repository Vega looks in when the user only gives an author.
  static const String vegaDefaultRepo = 'vega-providers';
  static const String vegaDefaultBranch = 'main';

  Future<Result<RepositoryInput>> resolve(String raw) async {
    final input = raw.trim();
    if (input.isEmpty) {
      return const Err<RepositoryInput>(
        PluginParseError('Enter a repository URL', field: 'url'),
      );
    }
    if (input.contains(RegExp(r'\s'))) {
      return const Err<RepositoryInput>(
        PluginParseError('A repository URL cannot contain spaces',
            field: 'url'),
      );
    }

    final deepLink = _cloudStreamDeepLink(input);
    if (deepLink != null) {
      return Ok<RepositoryInput>(
        RepositoryInput(
          primary: deepLink,
          display: deepLink.toString(),
          kind: RepositoryInputKind.cloudstreamDeepLink,
        ),
      );
    }

    if (_looksLikeUrl(input)) {
      final uri = Uri.tryParse(_withScheme(input));
      if (uri == null || uri.host.isEmpty) {
        return const Err<RepositoryInput>(
          PluginParseError('That is not a valid URL', field: 'url'),
        );
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        return Err<RepositoryInput>(
          PluginParseError(
            'Repositories are fetched over http or https, not ${uri.scheme}',
            field: 'url',
          ),
        );
      }
      final canonical = _canonicalise(uri);
      if (canonical == null) return _unsupportedHost(uri.host);
      return _fromUrl(canonical, kind: RepositoryInputKind.url);
    }

    return _fromBareToken(input);
  }

  /// `cloudstreamrepo://host/path` and `https://cs.repo/?host/path` are how
  /// CloudStream shares a repository as one tappable link.
  static Uri? _cloudStreamDeepLink(String input) {
    final lower = input.toLowerCase();
    if (lower.startsWith('cloudstreamrepo://')) {
      final rest = input.substring('cloudstreamrepo://'.length);
      return rest.isEmpty ? null : Uri.tryParse(_withScheme(rest));
    }
    final csRepo = RegExp(r'^https?://cs\.repo/\??(.*)$', caseSensitive: false);
    final match = csRepo.firstMatch(input);
    if (match == null) return null;
    final rest = match.group(1) ?? '';
    if (rest.isEmpty) return null;
    return Uri.tryParse(_withScheme(rest));
  }

  static bool _looksLikeUrl(String input) =>
      input.contains('://') || input.startsWith('//') || input.contains('/');

  static String _withScheme(String input) {
    if (input.contains('://')) return input;
    if (input.startsWith('//')) return 'https:$input';
    return 'https://$input';
  }

  /// Normalises the URL forms Vega documents into the folder that holds
  /// `manifest.json` and `dist/`.
  static Uri? _canonicalise(Uri uri) {
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isNotEmpty && segments.last == 'manifest.json') {
      segments.removeLast();
    }

    switch (host) {
      case 'raw.githubusercontent.com':
        // <author>/<repo>/refs/heads/<branch>[/…] or <author>/<repo>/<branch>
        if (segments.length < 3) return null;
        final author = segments[0];
        final repo = segments[1];
        final branch = segments.length >= 5 && segments[2] == 'refs'
            ? segments.sublist(4).join('/')
            : segments.sublist(2).join('/');
        return Uri.parse(
          'https://raw.githubusercontent.com/$author/$repo/refs/heads/$branch',
        );
      case 'github.com':
        if (segments.length < 2) return null;
        final author = segments[0];
        final repo = segments[1];
        // A web link to a file (`/blob/<branch>/<path>`) is the file itself.
        if (segments.length > 4 && segments[2] == 'blob') {
          return Uri.parse(
            'https://raw.githubusercontent.com/$author/$repo/refs/heads/'
            '${segments.sublist(3).join('/')}',
          );
        }
        final branch = segments.length > 3 && segments[2] == 'tree'
            ? segments.sublist(3).join('/')
            : vegaDefaultBranch;
        return Uri.parse(
          'https://raw.githubusercontent.com/$author/$repo/refs/heads/$branch',
        );
      case 'codeberg.org':
        if (segments.length < 2) return null;
        final branch = segments.length > 3 && segments[2] == 'src'
            ? segments.sublist(3).join('/')
            : vegaDefaultBranch;
        return Uri.parse(
          'https://codeberg.org/${segments[0]}/${segments[1]}/raw/branch/$branch',
        );
      case 'bitbucket.org':
        if (segments.length < 2) return null;
        final branch = segments.length > 3 && segments[2] == 'src'
            ? segments.sublist(3).join('/')
            : vegaDefaultBranch;
        return Uri.parse(
          'https://bitbucket.org/${segments[0]}/${segments[1]}/raw/$branch',
        );
      case 'gitlab.com':
        final separator = segments.indexOf('-');
        final project =
            separator >= 0 ? segments.sublist(0, separator) : segments;
        if (project.length < 2) return null;
        final branch = separator >= 0 && segments.length > separator + 2
            ? segments.sublist(separator + 2).join('/')
            : vegaDefaultBranch;
        return Uri.parse(
          'https://gitlab.com/${project.join('/')}/-/raw/$branch',
        );
      default:
        // Any other host: a folder (or a manifest.json URL) is the source. The
        // query is dropped — a manifest URL with `?v=1` still names the same
        // repository folder.
        return Uri(
          scheme: uri.scheme,
          userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path,
        );
    }
  }

  Result<RepositoryInput> _unsupportedHost(String host) => Err<RepositoryInput>(
        PluginParseError(
          'That link points at $host, which is not a repository file. Paste the '
          'repository URL or its manifest instead.',
          field: 'url',
        ),
      );

  /// A folder needs `/manifest.json` appended; a `.json` URL is already a file.
  static Result<RepositoryInput> _fromUrl(
    Uri uri, {
    required RepositoryInputKind kind,
  }) {
    final lower = uri.path.toLowerCase();
    final isJson = lower.endsWith('.json');
    final base =
        uri.toString().endsWith('/') ? uri : Uri.parse('${uri.toString()}/');
    final display = _displayFor(uri);
    if (isJson) {
      return Ok<RepositoryInput>(
        RepositoryInput(primary: uri, display: display, kind: kind),
      );
    }
    return Ok<RepositoryInput>(
      RepositoryInput(
        primary: uri,
        fallbacks: _folderFiles(base),
        display: display,
        kind: RepositoryInputKind.vegaFolder,
      ),
    );
  }

  /// Shortcodes and Vega author names. Ambiguous by design, so: redirect first,
  /// then the Vega default repository.
  Future<Result<RepositoryInput>> _fromBareToken(String token) async {
    if (!RegExp(r'^!?[A-Za-z0-9_.@-]+$').hasMatch(token)) {
      return const Err<RepositoryInput>(
        PluginParseError(
          'That is neither a URL nor a repository code',
          field: 'url',
        ),
      );
    }

    // Vega's `author@cb` style short name is unambiguous: only Vega uses it.
    final at = token.lastIndexOf('@');
    if (at > 0) {
      final author = token.substring(0, at);
      final suffix = token.substring(at + 1).toLowerCase();
      final host = vegaHostSuffixes[suffix];
      if (host == null) {
        return Err<RepositoryInput>(
          PluginParseError(
            'Unknown source suffix "@$suffix" — Vega accepts @cb, @bb, @gl '
            'or @gh',
            field: 'url',
          ),
        );
      }
      return _vegaAuthor(author, host: host);
    }

    final redirectTarget = await followRedirect(_shortcodeUrl(token));
    if (redirectTarget != null &&
        (redirectTarget.scheme == 'http' || redirectTarget.scheme == 'https')) {
      final canonical = _canonicalise(redirectTarget) ?? redirectTarget;
      return _fromUrl(canonical, kind: RepositoryInputKind.shortcode);
    }

    // Not a shortcode the redirect service knows: try Vega's convention.
    return _vegaAuthor(token, host: 'github');
  }

  static Uri _shortcodeUrl(String token) => token.startsWith('!')
      ? Uri.parse('https://py.md/${token.substring(1)}')
      : Uri.parse('https://cutt.ly/$token');

  Result<RepositoryInput> _vegaAuthor(String author, {required String host}) {
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(author)) {
      return const Err<RepositoryInput>(
        PluginParseError('That is not a valid author name', field: 'url'),
      );
    }
    final base = switch (host) {
      'codeberg' => 'https://codeberg.org/$author/$vegaDefaultRepo/raw/branch/'
          '$vegaDefaultBranch',
      'bitbucket' => 'https://bitbucket.org/$author/$vegaDefaultRepo/raw/'
          '$vegaDefaultBranch',
      'gitlab' => 'https://gitlab.com/$author/$vegaDefaultRepo/-/raw/'
          '$vegaDefaultBranch',
      _ => 'https://raw.githubusercontent.com/$author/$vegaDefaultRepo/'
          'refs/heads/$vegaDefaultBranch',
    };
    final folder = Uri.parse(base.endsWith('/') ? base : '$base/');
    return Ok<RepositoryInput>(
      RepositoryInput(
        // A Vega source is a folder; every ecosystem names its manifest
        // differently, so all three names are tried from here.
        primary: folder.resolve('manifest.json'),
        fallbacks: _folderFiles(folder),
        display: folder.toString(),
        kind: RepositoryInputKind.vegaAuthor,
      ),
    );
  }

  /// The files a repository folder may publish, in the order they are tried.
  ///
  /// All three ecosystems put a *folder* behind a share link, but they disagree
  /// on the file name: Vega reads `manifest.json`, CloudStream reads
  /// `repo.json`, and plenty of SkyStream repositories publish the plugin array
  /// itself as `plugins.json`. Trying all three is what makes one URL box work
  /// for every ecosystem instead of only the one whose file we guessed.
  static List<Uri> _folderFiles(Uri base) => <Uri>[
        base.resolve('manifest.json'),
        base.resolve('repo.json'),
        base.resolve('plugins.json'),
      ];

  static String _displayFor(Uri uri) {
    final text = uri.toString();
    return text.endsWith('/') ? text.substring(0, text.length - 1) : text;
  }
}
