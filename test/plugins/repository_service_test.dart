import 'package:aerostream/core/errors/plugin_error.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/plugin_repository.dart';
import 'package:aerostream/plugins/manager/repository_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

const String _repoUrl = 'https://example.com/repo.json';
const String _listUrl = 'https://example.com/plugins.json';

const String _repoJson = '''
{"name":"Example Repo","description":"Demo","iconUrl":"https://example.com/i.png",
 "manifestVersion":1,"pluginLists":["https://example.com/plugins.json"]}
''';

const String _skyPlugins = '''
[{"packageName":"dev.example.one","name":"One","version":2,
  "url":"https://example.com/one.sky"}]
''';

const String _csPlugins = '''
[{"internalName":"Provider","name":"Provider","version":7,"status":1,
  "url":"https://example.com/Provider.cs3","tvTypes":["Movie"]}]
''';

const String _vegaManifest = '''
[{"display_name":"MovieBox","value":"moviebox","version":"1.0","hasSettings":false}]
''';

void main() {
  group('RepositoryService.addRepository', () {
    test('adds a SkyStream repository and detects its ecosystem', () async {
      final http = FakeHttpService(<String, Object>{
        _repoUrl: _repoJson,
        _listUrl: _skyPlugins,
      });
      final store = InMemoryExtensionStore();
      final service = RepositoryService(http: http, store: store);

      final result = await service.addRepository(_repoUrl);

      expect(result.isOk, isTrue);
      final repository = result.valueOrNull!;
      expect(repository.name, 'Example Repo');
      expect(repository.ecosystem, PluginEcosystem.skystream);
      expect(repository.pluginLists, <String>[_listUrl]);
      expect(await store.repositories(), hasLength(1));
    });

    test('refuses a manifest version this build cannot read', () async {
      const future = 'https://example.com/future.json';
      final http = FakeHttpService(<String, Object>{
        future: '{"name":"Future","manifestVersion":2,'
            '"pluginLists":["https://example.com/plugins.json"]}',
        _listUrl: _skyPlugins,
      });
      final store = InMemoryExtensionStore();
      final service = RepositoryService(http: http, store: store);

      final result = await service.addRepository(future);

      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.message, contains('manifest version 2'));
      expect(
        await store.repositories(),
        isEmpty,
        reason: 'a repository it cannot read must not be stored',
      );
    });

    test('detects a CloudStream repository from .cs3 entries', () async {
      final http = FakeHttpService(<String, Object>{
        _repoUrl: _repoJson,
        _listUrl: _csPlugins,
      });
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );

      final repository = (await service.addRepository(_repoUrl)).valueOrNull!;
      expect(repository.ecosystem, PluginEcosystem.cloudstream);
    });

    test('treats a bare provider array as a Vega repository', () async {
      final http = FakeHttpService(<String, Object>{
        _repoUrl: _vegaManifest,
      });
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );

      final repository = (await service.addRepository(_repoUrl)).valueOrNull!;
      expect(repository.ecosystem, PluginEcosystem.vega);
      expect(repository.pluginLists, <String>[_repoUrl]);
    });

    test('files a CloudStream plugin list that is pasted directly', () async {
      // People share the list, not the manifest. Reading every bare array as
      // Vega is what made CloudStream "not work": its entries then had nothing
      // the Vega parser could use.
      const listUrl = 'https://example.com/builds/plugins.json';
      final http = FakeHttpService(<String, Object>{listUrl: _csPlugins});
      final store = InMemoryExtensionStore();
      final service = RepositoryService(http: http, store: store);

      final repository = (await service.addRepository(listUrl)).valueOrNull!;

      expect(repository.ecosystem, PluginEcosystem.cloudstream);
      expect(repository.pluginLists, <String>[listUrl]);
      expect(repository.name, 'builds');
      expect(await store.repositories(), hasLength(1));
      final browsing = await service.browse(repository);
      expect(browsing.valueOrNull!.single.id, 'Provider');
    });

    test('files a SkyStream plugin list that is pasted directly', () async {
      const listUrl = 'https://example.com/sky/plugins.json';
      final http = FakeHttpService(<String, Object>{listUrl: _skyPlugins});
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );

      final repository = (await service.addRepository(listUrl)).valueOrNull!;

      expect(repository.ecosystem, PluginEcosystem.skystream);
      final browsing = await service.browse(repository);
      expect(browsing.valueOrNull!.single.downloadUrl, endsWith('one.sky'));
    });

    test('the section a repository was added from loses to its entries',
        () async {
      // A CloudStream repo added through the SkyStream box is filed under
      // CloudStream: the entries decide, and the section is only a tie-break.
      final http = FakeHttpService(<String, Object>{
        _repoUrl: _repoJson,
        _listUrl: _csPlugins,
      });
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );

      final repository = (await service.addRepository(
        _repoUrl,
        expect: PluginEcosystem.skystream,
      ))
          .valueOrNull!;

      expect(repository.ecosystem, PluginEcosystem.cloudstream);
      final browsing = await service.browse(repository);
      expect(browsing.valueOrNull!.single.id, 'Provider');
    });

    test('a file URL offers the other ecosystems manifest names', () async {
      final http = FakeHttpService(<String, Object>{
        'https://example.com/repos/vega/manifest.json': 'not found',
        'https://example.com/repos/vega/repo.json': _repoJson,
        _listUrl: _skyPlugins,
      });
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );

      final result = await service.addRepository(
        'https://example.com/repos/vega',
      );

      expect(result.isOk, isTrue);
      expect(result.valueOrNull!.name, 'Example Repo');
    });

    test('normalises a scheme-less URL', () async {
      final http = FakeHttpService(<String, Object>{
        _repoUrl: _repoJson,
        _listUrl: _skyPlugins,
      });
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );

      final result = await service.addRepository('example.com/repo.json');
      expect(result.isOk, isTrue);
      expect(result.valueOrNull!.url, _repoUrl);
    });

    test('rejects input that is not a URL', () async {
      final service = RepositoryService(
        http: FakeHttpService(),
        store: InMemoryExtensionStore(),
      );
      for (final input in <String>['', '   ', 'not a url', 'ftp://x/y']) {
        final result = await service.addRepository(input);
        expect(result.isErr, isTrue, reason: 'input: "$input"');
      }
    });

    test('surfaces a network failure as a typed error', () async {
      final http = FakeHttpService(<String, Object>{
        _repoUrl: const PluginTimeoutError('slow'),
      });
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );
      final result = await service.addRepository(_repoUrl);
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'timeout');
    });

    test('re-adding the same repository refreshes it in place', () async {
      final store = InMemoryExtensionStore();
      final service = RepositoryService(
        http: FakeHttpService(<String, Object>{
          _repoUrl: _repoJson,
          _listUrl: _skyPlugins,
        }),
        store: store,
      );

      final first = (await service.addRepository(_repoUrl)).valueOrNull!;
      final second = (await service.addRepository(_repoUrl)).valueOrNull!;

      expect(await store.repositories(), hasLength(1));
      expect(second.id, first.id);
      expect(second.addedAt, first.addedAt);
    });
  });

  group('RepositoryService.browse', () {
    test('lists every plugin of the repository', () async {
      final http = FakeHttpService(<String, Object>{
        _repoUrl: _repoJson,
        _listUrl: _skyPlugins,
      });
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );
      final repository = (await service.addRepository(_repoUrl)).valueOrNull!;

      final browsing = await service.browse(repository);
      expect(browsing.isOk, isTrue);
      expect(browsing.valueOrNull!.single.id, 'dev.example.one');
      expect(browsing.valueOrNull!.single.repositoryId, repository.id);
    });

    test('pulls in included repositories one level deep', () async {
      const megaUrl = 'https://mega.example/repo.json';
      const innerUrl = 'https://inner.example/repo.json';
      const innerList = 'https://inner.example/plugins.json';

      final http = FakeHttpService(<String, Object>{
        megaUrl: '{"name":"Mega","pluginLists":[],"repos":["$innerUrl"]}',
        innerUrl: '{"name":"Inner","pluginLists":["$innerList"]}',
        innerList: _csPlugins,
      });
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );

      final repository = (await service.addRepository(megaUrl)).valueOrNull!;
      final browsing = await service.browse(
        repository,
        hint: PluginEcosystem.cloudstream,
      );

      expect(browsing.valueOrNull!.map((plugin) => plugin.id), isNot(isEmpty));
    });

    test('reads a list that was stored with the wrong ecosystem hint',
        () async {
      // A repository added before the list was readable carries the wrong
      // ecosystem. Browsing must still find its plugins.
      const repository = PluginRepository(
        id: 'r',
        name: 'R',
        url: _repoUrl,
        ecosystem: PluginEcosystem.vega,
        pluginLists: <String>[_listUrl],
      );
      final service = RepositoryService(
        http: FakeHttpService(<String, Object>{_listUrl: _csPlugins}),
        store: InMemoryExtensionStore(),
      );

      final browsing = await service.browse(repository);

      expect(browsing.isOk, isTrue);
      expect(
        browsing.valueOrNull!.single.ecosystem,
        PluginEcosystem.cloudstream,
      );
    });

    test('a SkyStream mega-repository keeps its children SkyStream', () async {
      // `cutt.ly/sky-universe` is exactly this shape: a manifest with `repos`
      // and no lists of its own, whose children publish `.sky` plugins. The
      // children used to be read with a CloudStream hint, which parses fine —
      // a SkyStream entry has a name and a url — and then hands the installer a
      // `.sky` file it would only accept as a DEX.
      const megaUrl = 'https://mega.example/mega_repo.json';
      const innerUrl = 'https://inner.example/repo.json';
      const innerList = 'https://inner.example/dist/plugins.json';

      final http = FakeHttpService(<String, Object>{
        megaUrl: '{"name":"Universe","manifestVersion":1,'
            '"repos":["$innerUrl"]}',
        innerUrl: '{"name":"Inner","pluginLists":["$innerList"]}',
        innerList: _skyPlugins,
      });
      final service = RepositoryService(
        http: http,
        store: InMemoryExtensionStore(),
      );

      final repository = (await service.addRepository(megaUrl)).valueOrNull!;
      expect(repository.ecosystem, PluginEcosystem.skystream);

      final browsing = await service.browse(repository);
      expect(browsing.isOk, isTrue, reason: browsing.errorOrNull?.toString());
      final plugin = browsing.valueOrNull!.single;
      expect(plugin.ecosystem, PluginEcosystem.skystream);
      expect(plugin.id, 'dev.example.one');
      expect(plugin.downloadUrl, 'https://example.com/one.sky');
    });

    test('a list is read as what its entries are, not what was hinted',
        () async {
      final service = RepositoryService(
        http: FakeHttpService(<String, Object>{_listUrl: _skyPlugins}),
        store: InMemoryExtensionStore(),
      );
      final listing = await service.fetchPluginList(
        _listUrl,
        repositoryId: 'r',
        hint: PluginEcosystem.cloudstream,
      );
      expect(listing.valueOrNull!.ecosystem, PluginEcosystem.skystream);
    });

    test('reports an error when nothing could be read', () async {
      final service = RepositoryService(
        http: FakeHttpService(),
        store: InMemoryExtensionStore(),
      );
      const repository = PluginRepository(
        id: 'r',
        name: 'R',
        url: _repoUrl,
        ecosystem: PluginEcosystem.skystream,
        pluginLists: <String>[_listUrl],
      );
      final browsing = await service.browse(repository);
      expect(browsing.isErr, isTrue);
    });
  });

  group('RepositoryService.refresh', () {
    test('updates the manifest details', () async {
      final store = InMemoryExtensionStore();
      final http = FakeHttpService(<String, Object>{
        _repoUrl: _repoJson,
        _listUrl: _skyPlugins,
      });
      final service = RepositoryService(http: http, store: store);
      final repository = (await service.addRepository(_repoUrl)).valueOrNull!;

      http.routes[_repoUrl] = '''
{"name":"Renamed Repo","pluginLists":["https://example.com/plugins.json"]}
''';
      final refreshed = (await service.refresh(repository)).valueOrNull!;
      expect(refreshed.name, 'Renamed Repo');
      expect(refreshed.lastCheckedAt, isNotNull);
    });

    test('propagates a network failure without touching the record', () async {
      final store = InMemoryExtensionStore();
      final http = FakeHttpService(<String, Object>{
        _repoUrl: _repoJson,
        _listUrl: _skyPlugins,
      });
      final service = RepositoryService(http: http, store: store);
      final repository = (await service.addRepository(_repoUrl)).valueOrNull!;

      http.routes[_repoUrl] = const PluginNetworkError('down', statusCode: 502);
      final refreshed = await service.refresh(repository);
      expect(refreshed, isA<Err<PluginRepository>>());
      expect((await store.repositories()).single.name, 'Example Repo');
    });
  });
}
