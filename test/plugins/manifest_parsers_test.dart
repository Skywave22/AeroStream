import 'package:aerostream/core/result.dart';
import 'package:aerostream/core/utils/version.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/plugin_repository.dart';
import 'package:aerostream/plugins/manifest/plugin_list_parser.dart';
import 'package:aerostream/plugins/manifest/repository_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixtures below are copied from live repositories (structure preserved,
/// values trimmed) so the parser is tested against what is actually served.
const String _cloudStreamRepo = '''
{
  "name": "Phisher Repo",
  "iconUrl": "https://example.com/RepoIcon.png",
  "description": "Phisher Repository",
  "manifestVersion": 1,
  "pluginLists": [
    "https://example.com/builds/plugins.json"
  ]
}
''';

const String _cloudStreamPlugins = '''
[
  {
    "url": "https://example.com/builds/AllMovieLandProvider.cs3",
    "status": 1,
    "version": 25,
    "name": "AllMovieLandProvider",
    "internalName": "AllMovieLandProvider",
    "authors": ["Phisher98"],
    "description": "Indian MultiLanguage Provider",
    "fileSize": 110297,
    "repositoryUrl": "https://github.com/phisher98/cloudstream-extensions-phisher",
    "language": "hi",
    "tvTypes": ["Movie", "TvSeries", "Cartoon"],
    "iconUrl": "https://example.com/icon.png",
    "apiVersion": 1,
    "fileHash": "sha256-42c9c80e"
  },
  {
    "url": "https://example.com/builds/Broken.cs3",
    "status": 0,
    "version": 2,
    "name": "Broken",
    "internalName": "Broken"
  }
]
''';

const String _skyStreamRepo = '''
{
  "name": "Sky Repo",
  "description": "SkyStream plugins",
  "manifestVersion": 1,
  "pluginLists": ["plugins.json"]
}
''';

const String _skyStreamPlugins = '''
[
  {
    "packageName": "dev.example.stars",
    "name": "Stars",
    "version": 3,
    "description": "Movies",
    "authors": ["Dev"],
    "languages": ["en", "hi"],
    "baseUrl": "https://example.com",
    "url": "https://example.com/packages/dev.example.stars.sky",
    "settings": [{"key": "baseUrl", "title": "Base URL"}]
  },
  {
    "name": "Missing package name",
    "url": "https://example.com/packages/broken.sky"
  }
]
''';

const String _vegaManifest = '''
[
  {
    "display_name": "MovieBox",
    "value": "moviebox",
    "version": "1.2",
    "icon": "https://example.com/moviebox.png",
    "type": "global",
    "hasSettings": true,
    "disabled": false
  },
  {
    "display_name": "Old Provider",
    "value": "old",
    "version": "0.9",
    "disabled": true
  }
]
''';

void main() {
  group('RepositoryManifest', () {
    test('parses a live CloudStream repo.json', () {
      final result = RepositoryManifest.parse(
        _cloudStreamRepo,
        sourceUrl: 'https://example.com/repo.json',
      );
      expect(result.isOk, isTrue);
      final manifest = result.valueOrNull!;
      expect(manifest.name, 'Phisher Repo');
      expect(manifest.pluginLists, hasLength(1));
      expect(manifest.manifestVersion, 1);
      expect(manifest.isUsable, isTrue);
    });

    test('resolves relative plugin list URLs against the manifest URL', () {
      final manifest = RepositoryManifest.parse(
        _skyStreamRepo,
        sourceUrl: 'https://example.com/repos/main/repo.json',
      ).valueOrNull!;
      expect(
        manifest.pluginLists.single,
        'https://example.com/repos/main/plugins.json',
      );
    });

    test('reads included repositories', () {
      final manifest = RepositoryManifest.parse(
        '{"name":"Mega","pluginLists":[],"repos":["https://b.example/r.json"]}',
        sourceUrl: 'https://a.example/repo.json',
      ).valueOrNull!;
      expect(manifest.includedRepos, <String>['https://b.example/r.json']);
      expect(manifest.isUsable, isTrue, reason: 'included repos count');
    });

    test('rejects non-JSON and empty manifests with typed errors', () {
      final notJson = RepositoryManifest.parse(
        '<html>404</html>',
        sourceUrl: 'https://example.com/repo.json',
      );
      expect(notJson, isA<Err<RepositoryManifest>>());
      expect(notJson.errorOrNull!.kind, 'parse');

      final notARepo = RepositoryManifest.parse(
        '{"hello":"world"}',
        sourceUrl: 'https://example.com/repo.json',
      );
      expect(notARepo.isErr, isTrue);
    });
  });

  group('PluginListParser', () {
    test('parses a live CloudStream plugins.json', () {
      final result = PluginListParser.parse(
        _cloudStreamPlugins,
        sourceUrl: 'https://example.com/builds/plugins.json',
        repositoryId: 'repo',
      ).valueOrNull!;

      expect(result.ecosystem, PluginEcosystem.cloudstream);
      expect(result.plugins, hasLength(2));

      final provider = result.plugins.first;
      expect(provider.id, 'AllMovieLandProvider');
      expect(provider.version, PluginVersion.parse(25));
      expect(provider.ecosystem, PluginEcosystem.cloudstream);
      expect(provider.downloadUrl, endsWith('.cs3'));
      expect(provider.authors, <String>['Phisher98']);
      expect(provider.fileHash, 'sha256-42c9c80e');
      expect(provider.supportedTypes, contains(MediaType.series));
      expect(provider.supportedTypes, contains(MediaType.anime));
      expect(provider.apiVersion, 1);
      expect(provider.isWorking, isTrue);

      // status: 0 means the repository itself says it is broken.
      expect(result.plugins.last.isWorking, isFalse);
    });

    test('parses a SkyStream plugin list and drops unusable entries', () {
      final result = PluginListParser.parse(
        _skyStreamPlugins,
        sourceUrl: 'https://example.com/plugins.json',
        repositoryId: 'sky',
      ).valueOrNull!;

      expect(result.ecosystem, PluginEcosystem.skystream);
      expect(
        result.plugins,
        hasLength(1),
        reason: 'an entry with no packageName cannot be installed',
      );
      final plugin = result.plugins.single;
      expect(plugin.id, 'dev.example.stars');
      expect(plugin.downloadUrl, endsWith('.sky'));
      expect(plugin.language, 'en', reason: 'first declared language wins');
      expect(plugin.settings, <String>['baseUrl']);
    });

    test('parses a Vega provider manifest and points at its dist folder', () {
      final result = PluginListParser.parse(
        _vegaManifest,
        sourceUrl: 'https://example.com/manifest.json',
        repositoryId: 'vega',
      ).valueOrNull!;

      expect(result.ecosystem, PluginEcosystem.vega);
      expect(result.plugins, hasLength(2));
      final provider = result.plugins.first;
      expect(provider.id, 'moviebox');
      expect(provider.name, 'MovieBox');
      expect(
        provider.downloadUrl,
        'https://example.com/dist/moviebox/',
        reason: 'providers are a folder of modules, not one file',
      );
      expect(provider.settings, contains('settings'));
      expect(result.plugins.last.isWorking, isFalse);
    });

    test('a Vega provider path replaces dist/<value>', () {
      final result = PluginListParser.parse(
        '''[
          {"value": "nested", "display_name": "Nested", "version": "1.0",
           "path": "providers/nested"},
          {"value": "escape", "display_name": "Escape", "path": "../outside"},
          {"value": "absolute", "display_name": "Absolute",
           "path": "https://evil.example/x"}
        ]''',
        sourceUrl: 'https://example.com/repo/manifest.json',
        repositoryId: 'vega',
      ).valueOrNull!;

      expect(
        result.plugins.first.downloadUrl,
        'https://example.com/repo/providers/nested/',
      );
      // A path that leaves the source folder is ignored, not followed.
      expect(
        result.plugins[1].downloadUrl,
        'https://example.com/repo/dist/escape/',
      );
      expect(
        result.plugins[2].downloadUrl,
        'https://example.com/repo/dist/absolute/',
      );
    });

    test('CloudStream status codes mean what CloudStream says they mean', () {
      AvailablePlugin status(int code) => PluginListParser.parse(
        '[{"url":"https://e.test/a.cs3","internalName":"A","name":"A",'
        '"status":$code,"version":1,"apiVersion":1,"tvTypes":["Movie"]}]',
        sourceUrl: 'https://e.test/plugins.json',
        repositoryId: 'cs',
      ).valueOrNull!.plugins.single;

      expect(status(1).isWorking, isTrue);
      expect(status(1).statusNote, isNull);

      expect(status(2).isWorking, isTrue, reason: 'slow is installable');
      expect(status(2).isSlow, isTrue);
      expect(status(2).statusNote, 'Reported slow');

      expect(status(3).isWorking, isTrue, reason: 'beta is installable');
      expect(status(3).isBeta, isTrue);
      expect(status(3).statusNote, 'Beta channel only');

      expect(status(0).isWorking, isFalse);
      expect(status(0).isInstallable(isAndroid: true), isFalse);
    });

    test('detects the ecosystem from entry shape', () {
      expect(
        PluginListParser.detectEcosystem(<Map<String, Object?>>[
          <String, Object?>{'value': 'x', 'display_name': 'X'},
        ]),
        PluginEcosystem.vega,
      );
      expect(
        PluginListParser.detectEcosystem(<Map<String, Object?>>[
          <String, Object?>{'internalName': 'X', 'url': 'a.cs3'},
        ]),
        PluginEcosystem.cloudstream,
      );
      expect(
        PluginListParser.detectEcosystem(<Map<String, Object?>>[
          <String, Object?>{'packageName': 'a.b', 'url': 'a.sky'},
        ]),
        PluginEcosystem.skystream,
      );
      expect(
        PluginListParser.detectEcosystem(<Map<String, Object?>>[
          <String, Object?>{'name': 'mystery'},
        ]),
        isNull,
      );
    });

    test('an empty list is valid, not an error', () {
      final result = PluginListParser.parse(
        '[]',
        sourceUrl: 'https://example.com/plugins.json',
        repositoryId: 'repo',
      );
      expect(result.isOk, isTrue);
      expect(result.valueOrNull!.plugins, isEmpty);
    });

    test('rejects non-array payloads', () {
      final result = PluginListParser.parse(
        '{"plugins":[]}',
        sourceUrl: 'https://example.com/plugins.json',
        repositoryId: 'repo',
      );
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'parse');
    });

    test('keeps a hint even when entries look ambiguous', () {
      final result = PluginListParser.parse(
        '[{"name":"X","url":"https://e/x.bin","version":1,"packageName":"a.b"}]',
        sourceUrl: 'https://example.com/p.json',
        repositoryId: 'repo',
        hint: PluginEcosystem.skystream,
      ).valueOrNull!;
      expect(result.ecosystem, PluginEcosystem.skystream);
      expect(result.plugins.single.ecosystem, PluginEcosystem.skystream);
    });
  });
}
