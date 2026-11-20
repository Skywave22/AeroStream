import 'package:aerostream/core/network/redirect_location.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/plugins/manager/repository_input.dart';
import 'package:flutter_test/flutter_test.dart';

/// The redirect table a test resolver uses: shortcode URL -> target.
final class _Redirects {
  _Redirects([Map<String, String>? table])
      : table = table ?? <String, String>{};

  final Map<String, String> table;
  final List<String> asked = <String>[];

  Future<Uri?> call(Uri url) async {
    asked.add(url.toString());
    final target = table[url.toString()];
    return target == null ? null : Uri.parse(target);
  }
}

Future<RepositoryInput> _resolve(String input, [_Redirects? redirects]) async {
  final result = await RepositoryInputResolver(
    followRedirect: (redirects ?? _Redirects()).call,
  ).resolve(input);
  if (result is Err<RepositoryInput>) {
    throw TestFailure('expected a repository input, got ${result.error}');
  }
  return (result as Ok<RepositoryInput>).value;
}

void main() {
  group('plain URLs', () {
    test('a manifest URL is used as typed', () async {
      final input = await _resolve('https://repo.example/repo.json');
      expect(input.primary.toString(), 'https://repo.example/repo.json');
      expect(input.fallbacks, isEmpty);
      expect(input.kind, RepositoryInputKind.url);
    });

    test('a folder URL offers every ecosystem\'s manifest name', () async {
      final input = await _resolve('https://repo.example/repos/vega');
      expect(input.primary.toString(), 'https://repo.example/repos/vega');
      expect(
        input.fallbacks.map((uri) => uri.toString()),
        <String>[
          'https://repo.example/repos/vega/manifest.json',
          'https://repo.example/repos/vega/repo.json',
          'https://repo.example/repos/vega/plugins.json',
        ],
      );
      expect(input.kind, RepositoryInputKind.vegaFolder);
    });

    test('a scheme-less host is assumed to be https', () async {
      final input = await _resolve('repo.example/repo.json');
      expect(input.primary.scheme, 'https');
    });

    test('whitespace and empty input are rejected, not guessed at', () async {
      for (final bad in <String>['', '   ', 'https://a.example/a b']) {
        final result = await RepositoryInputResolver(
          followRedirect: _Redirects().call,
        ).resolve(bad);
        expect(result, isA<Err<RepositoryInput>>(), reason: bad);
      }
    });
  });

  group('CloudStream', () {
    test('cloudstreamrepo:// links lose the scheme', () async {
      final input = await _resolve(
        'cloudstreamrepo://raw.githubusercontent.com/a/b/main/repo.json',
      );
      expect(
        input.primary.toString(),
        'https://raw.githubusercontent.com/a/b/main/repo.json',
      );
      expect(input.kind, RepositoryInputKind.cloudstreamDeepLink);
    });

    test('cs.repo links lose the prefix', () async {
      final input = await _resolve(
        'https://cs.repo/?raw.githubusercontent.com/a/b/main/repo.json',
      );
      expect(
        input.primary.toString(),
        'https://raw.githubusercontent.com/a/b/main/repo.json',
      );
    });

    test('a shortcode is resolved through the redirect service', () async {
      final redirects = _Redirects(<String, String>{
        'https://cutt.ly/abc123':
            'https://repo.example/user/repo/main/repo.json',
      });
      final input = await _resolve('abc123', redirects);
      expect(redirects.asked.single, 'https://cutt.ly/abc123');
      expect(
        input.primary.toString(),
        'https://repo.example/user/repo/main/repo.json',
      );
      expect(input.kind, RepositoryInputKind.shortcode);
    });

    test('a "!" shortcode goes through py.md', () async {
      final redirects = _Redirects(<String, String>{
        'https://py.md/xyz': 'https://repo.example/repo.json',
      });
      await _resolve('!xyz', redirects);
      expect(redirects.asked.single, 'https://py.md/xyz');
    });
  });

  group('Vega sources', () {
    test('a GitHub repo URL becomes a raw base', () async {
      final input = await _resolve('https://github.com/someone/vega-providers');
      expect(
        input.primary.toString(),
        'https://raw.githubusercontent.com/someone/vega-providers/refs/heads/'
        'main',
      );
      expect(
        input.fallbacks.first.toString(),
        endsWith('/manifest.json'),
      );
      expect(
        input.fallbacks.map((uri) => uri.pathSegments.last),
        <String>['manifest.json', 'repo.json', 'plugins.json'],
      );
    });

    test('a branch in the URL is kept', () async {
      final input = await _resolve(
        'https://github.com/someone/providers/tree/dev',
      );
      expect(input.primary.toString(), contains('/refs/heads/dev'));
    });

    test('a raw URL is canonicalised', () async {
      final input = await _resolve(
        'https://raw.githubusercontent.com/someone/providers/main/dist',
      );
      expect(
        input.primary.toString(),
        'https://raw.githubusercontent.com/someone/providers/refs/heads/main/'
        'dist',
      );
    });

    test('other hosts (GitLab, Codeberg, Bitbucket) map to their raw form',
        () async {
      expect(
        (await _resolve('https://codeberg.org/me/providers'))
            .primary
            .toString(),
        'https://codeberg.org/me/providers/raw/branch/main',
      );
      expect(
        (await _resolve('https://bitbucket.org/me/providers'))
            .primary
            .toString(),
        'https://bitbucket.org/me/providers/raw/main',
      );
      expect(
        (await _resolve('https://gitlab.com/group/providers'))
            .primary
            .toString(),
        'https://gitlab.com/group/providers/-/raw/main',
      );
    });

    test('an author short name points at the default provider repo', () async {
      final input = await _resolve('someone_s_author');
      expect(
        input.primary.toString(),
        'https://raw.githubusercontent.com/someone_s_author/vega-providers/'
        'refs/heads/main/manifest.json',
      );
      expect(input.kind, RepositoryInputKind.vegaAuthor);
    });

    test('author@host short names pick the host', () async {
      final gitlab = await _resolve('someone@gl');
      expect(
        gitlab.primary.toString(),
        'https://gitlab.com/someone/vega-providers/-/raw/main/manifest.json',
      );
      final codeberg = await _resolve('someone@cb');
      expect(codeberg.primary.host, 'codeberg.org');
    });

    test('an unknown host suffix is refused', () async {
      final result = await RepositoryInputResolver(
        followRedirect: _Redirects().call,
      ).resolve('someone@xx');
      expect(result, isA<Err<RepositoryInput>>());
    });

    test('a shortcode that does not redirect falls back to the Vega author',
        () async {
      final input = await _resolve('someauthor');
      expect(input.kind, RepositoryInputKind.vegaAuthor);
      expect(input.primary.path, endsWith('/manifest.json'));
    });
  });

  group('redirect parsing', () {
    final base = Uri.parse('https://cutt.ly/code');

    test('accepts absolute and relative locations', () {
      expect(
        parseRedirectLocation('https://a.example/r.json', base).toString(),
        'https://a.example/r.json',
      );
      expect(
        parseRedirectLocation('/r.json', base).toString(),
        'https://cutt.ly/r.json',
      );
    });

    test('refuses non-http targets, 404 pages and empty locations', () {
      expect(parseRedirectLocation('javascript:alert(1)', base), isNull);
      expect(parseRedirectLocation('https://cutt.ly/404', base), isNull);
      expect(parseRedirectLocation('https://cutt.ly', base), isNull);
      expect(parseRedirectLocation(null, base), isNull);
      expect(parseRedirectLocation('   ', base), isNull);
    });
  });
}
