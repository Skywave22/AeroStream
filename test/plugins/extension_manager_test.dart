import 'dart:convert';

import 'package:aerostream/core/errors/plugin_error.dart';
import 'package:aerostream/core/platform/platform_profile.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/core/utils/version.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/episode.dart';
import 'package:aerostream/domain/entities/home_section.dart';
import 'package:aerostream/domain/entities/installed_plugin.dart';
import 'package:aerostream/domain/entities/media_details.dart';
import 'package:aerostream/domain/entities/media_item.dart';
import 'package:aerostream/domain/entities/plugin_info.dart';
import 'package:aerostream/domain/entities/plugin_repository.dart';
import 'package:aerostream/domain/entities/stream_source.dart';
import 'package:aerostream/domain/media_provider.dart';
import 'package:aerostream/plugins/manager/extension_manager.dart';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

const PlatformProfile _android = PlatformProfile(
  target: TargetPlatform.android,
  operatingSystem: 'android',
);
const PlatformProfile _linux = PlatformProfile(
  target: TargetPlatform.linux,
  operatingSystem: 'linux',
);

List<int> buildSkyPackage({
  String packageName = 'dev.example.plugin',
  int version = 2,
  String code = 'globalThis.getHome = () => {};',
}) {
  final manifest = jsonEncode(<String, Object?>{
    'packageName': packageName,
    'name': 'Example',
    'version': version,
    'description': 'A plugin',
    'authors': <String>['Tester'],
    'languages': <String>['en'],
    'settings': <Object?>[
      <String, Object?>{'key': 'baseUrl', 'title': 'Base URL'},
    ],
  });
  final archive = Archive()
    ..addFile(
        ArchiveFile('plugin.json', manifest.length, utf8.encode(manifest)))
    ..addFile(ArchiveFile('plugin.js', code.length, utf8.encode(code)));
  return ZipEncoder().encode(archive)!;
}

AvailablePlugin listing({
  String id = 'dev.example.plugin',
  PluginEcosystem ecosystem = PluginEcosystem.skystream,
  int version = 2,
  String? downloadUrl,
}) =>
    AvailablePlugin(
      id: id,
      name: 'Example',
      ecosystem: ecosystem,
      repositoryId: 'repo',
      version: PluginVersion.parse(version),
      downloadUrl: downloadUrl ??
          (ecosystem == PluginEcosystem.vega
              ? 'https://example.com/dist/example/'
              : 'https://example.com/$id.bin'),
    );

void main() {
  late InMemoryExtensionStore store;
  late InMemoryArtifactStore artifacts;
  late FakeHttpService http;

  ExtensionManager manager({
    PlatformProfile platform = _android,
    ProviderFactory? factory,
  }) =>
      ExtensionManager(
        store: store,
        artifacts: artifacts,
        http: http,
        platform: platform,
        providerFactory: factory,
      );

  setUp(() {
    store = InMemoryExtensionStore();
    artifacts = InMemoryArtifactStore();
    http = FakeHttpService();
  });

  group('SkyStream install', () {
    test('installs a .sky package and records the manifest', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage();

      final result = await manager().install(listing());
      expect(result.isOk, isTrue, reason: result.errorOrNull?.toString());

      final installed = result.valueOrNull!;
      expect(installed.info.id, 'dev.example.plugin');
      expect(installed.info.ecosystem, PluginEcosystem.skystream);
      expect(installed.info.version, PluginVersion.parse(2));
      expect(installed.info.authors, <String>['Tester']);
      expect(installed.info.settings.single.key, 'baseUrl');
      expect(installed.info.capabilities.streams, isTrue);
      expect(await store.installedPlugins(), hasLength(1));
    });

    test('refuses a package whose id does not match the listing', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage(packageName: 'dev.evil.plugin');

      final result = await manager().install(listing());
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'parse');
      expect(result.errorOrNull!.message, contains('dev.evil.plugin'));
      expect(await store.installedPlugins(), isEmpty);
    });

    test('refuses a package with no plugin.json', () async {
      final archive = Archive()
        ..addFile(ArchiveFile('plugin.js', 4, utf8.encode('//js')));
      http.routes['https://example.com/dev.example.plugin.bin'] =
          ZipEncoder().encode(archive)!;

      final result = await manager().install(listing());
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.message, contains('plugin.json'));
    });
  });

  group('CloudStream install', () {
    List<int> dexBytes() => <int>[0x64, 0x65, 0x78, 0x0A, 0x30, 0x33, 0x35];

    test('installs a .cs3 DEX', () async {
      http.routes['https://example.com/Provider.bin'] = dexBytes();
      final result = await manager().install(
        listing(id: 'Provider', ecosystem: PluginEcosystem.cloudstream),
      );

      expect(result.isOk, isTrue, reason: result.errorOrNull?.toString());
      expect(result.valueOrNull!.info.capabilities.home, isTrue);
      expect(
        artifacts.installed.values.single.keys,
        contains('plugin.cs3'),
      );
    });

    test('rejects a file that is not DEX', () async {
      http.routes['https://example.com/Provider.bin'] = utf8.encode('<html>');
      final result = await manager().install(
        listing(id: 'Provider', ecosystem: PluginEcosystem.cloudstream),
      );
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.message, contains('DEX'));
    });

    test('is refused on a platform without the Kotlin host', () async {
      final result = await manager(platform: _linux).install(
        listing(id: 'Provider', ecosystem: PluginEcosystem.cloudstream),
      );
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'unsupported');
      expect(http.requested, isEmpty, reason: 'nothing should be downloaded');
    });
  });

  group('Vega install', () {
    /// The four modules Vega's own loader requires before it will run anything.
    void publishRequiredBundle() {
      for (final module in ExtensionManager.requiredVegaModules) {
        http.routes['https://example.com/dist/example/$module'] =
            'exports.x = () => [];';
      }
    }

    test('installs the required modules plus any optional ones', () async {
      publishRequiredBundle();
      http.routes['https://example.com/dist/example/episodes.js'] =
          'exports.getEpisodes = () => [];';

      final result = await manager().install(
        listing(ecosystem: PluginEcosystem.vega, id: 'example'),
      );

      expect(result.isOk, isTrue, reason: result.errorOrNull?.toString());
      expect(
        artifacts.installed.values.single.keys,
        containsAll(<String>[
          'posts.js',
          'meta.js',
          'stream.js',
          'catalog.js',
          'episodes.js',
        ]),
      );
      expect(result.valueOrNull!.info.capabilities.catalogs, isTrue);
    });

    test('busts the CDN cache the way Vega does', () async {
      publishRequiredBundle();

      await manager().install(
        listing(ecosystem: PluginEcosystem.vega, id: 'example'),
      );

      final first = http.requested.first.toString();
      expect(first, contains('?v=2&t='));
    });

    test('only asks the provider folder for modules it has', () async {
      // `headers.js` and `providerContext.js` are published once at
      // `<source>/dist/`, never inside a provider's folder, so requesting them
      // per provider was two guaranteed 404s per install.
      publishRequiredBundle();

      final result = await manager().install(
        listing(ecosystem: PluginEcosystem.vega, id: 'example'),
      );

      expect(result.isOk, isTrue, reason: result.errorOrNull?.toString());
      expect(
        http.requested.where((url) => url.contains('headers.js')),
        isEmpty,
      );
      expect(
        http.requested.where((url) => url.contains('providerContext.js')),
        isEmpty,
      );
    });

    test('refuses a bundle that is missing a required module', () async {
      // posts.js alone: enough to look installed, not enough to work.
      http.routes['https://example.com/dist/example/posts.js'] =
          'exports.getPosts = () => [];';

      final result = await manager().install(
        listing(ecosystem: PluginEcosystem.vega, id: 'example'),
      );

      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.message, contains('meta.js'));
      expect(result.errorOrNull!.message, contains('stream.js'));
      expect(artifacts.installed, isEmpty);
    });
  });

  group('lifecycle', () {
    test('update replaces the artifact and keeps the old one for rollback',
        () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage(version: 2);
      final first = (await manager().install(listing(version: 2))).valueOrNull!;

      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage(version: 3);
      final updated = (await manager().update(
        first,
        listing(version: 3),
      ))
          .valueOrNull!;

      expect(updated.info.version, PluginVersion.parse(3));
      expect(updated.previousArtifactPath, first.artifactPath);
    });

    test('refuses a "update" that is not newer', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage(version: 5);
      final installed =
          (await manager().install(listing(version: 5))).valueOrNull!;
      final result = await manager().update(installed, listing(version: 5));
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'unsupported');
    });

    test('uninstall removes both the record and the files', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage();
      final installed = (await manager().install(listing())).valueOrNull!;

      await manager().uninstall(installed);
      expect(await store.installedPlugins(), isEmpty);
      expect(artifacts.removed, contains(installed.artifactPath));
    });

    test('finds updates for installed plugins only', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage(version: 2);
      await manager().install(listing(version: 2));

      final updates = await manager().findUpdates(<AvailablePlugin>[
        listing(version: 3),
        listing(id: 'other.plugin', version: 9),
        listing(version: 1),
      ]);

      expect(updates, hasLength(1));
      expect(updates.single.installed.info.id, 'dev.example.plugin');
      expect(updates.single.upgrade.version, PluginVersion.parse(3));
    });
  });

  group('activeProviders', () {
    test('skips disabled plugins, unsupported plugins and failures', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage();
      final installed = (await manager().install(listing())).valueOrNull!;
      await store.setEnabled(installed.key, enabled: false);

      var built = 0;
      final providers = await manager(
        factory: (plugin) async {
          built++;
          return Ok<MediaProvider>(_FakeProvider(plugin.info));
        },
      ).activeProviders();

      expect(providers, isEmpty);
      expect(built, 0);
    });

    test('builds a provider per enabled plugin', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage();
      http.routes['https://example.com/second.plugin.bin'] = buildSkyPackage(
        packageName: 'second.plugin',
      );
      await manager().install(listing());
      await manager().install(listing(id: 'second.plugin'));

      final providers = await manager(
        factory: (plugin) async =>
            Ok<MediaProvider>(_FakeProvider(plugin.info)),
      ).activeProviders();

      expect(providers, hasLength(2));
    });

    test('a provider that fails to start does not abort the others', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage();
      await manager().install(listing());

      final providers = await manager(
        factory: (plugin) async => const Err<MediaProvider>(
          PluginCrashError('runtime unavailable'),
        ),
      ).activeProviders();

      expect(providers, isEmpty);
    });
  });

  group('rollback', () {
    test('restores the recorded previous artifact', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage(version: 2);
      final first = (await manager().install(listing(version: 2))).valueOrNull!;

      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage(version: 3);
      final updated =
          (await manager().update(first, listing(version: 3))).valueOrNull!;

      final restored = (await manager().rollback(updated)).valueOrNull!;
      expect(restored.artifactPath, first.artifactPath);
      expect(restored.info.version, PluginVersion.parse(2));
    });

    test('refuses when there is nothing to roll back to', () async {
      http.routes['https://example.com/dev.example.plugin.bin'] =
          buildSkyPackage();
      final installed = (await manager().install(listing())).valueOrNull!;
      final fresh = InstalledPlugin(
        info: installed.info,
        artifactPath: installed.artifactPath,
      );

      final result = await manager().rollback(fresh);
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'not-found');
    });
  });
}

/// A provider that satisfies the interface without a runtime.
final class _FakeProvider implements MediaProvider {
  _FakeProvider(this.info);

  @override
  final PluginInfo info;

  @override
  PluginCapabilities get capabilities => info.capabilities;

  @override
  Future<Result<List<HomeSection>>> getHome() async =>
      const Ok<List<HomeSection>>(<HomeSection>[]);

  @override
  Future<Result<SearchPage>> search(String query, {int page = 1}) async =>
      const Ok<SearchPage>(SearchPage.empty);

  @override
  Future<Result<MediaDetails>> getDetails(MediaItem item) async =>
      Err<MediaDetails>(PluginUnsupportedError('not used', pluginId: info.id));

  @override
  Future<Result<List<Episode>>> getEpisodes(
    MediaItem item, {
    Season? season,
  }) async =>
      const Ok<List<Episode>>(<Episode>[]);

  @override
  Future<Result<StreamResult>> getStreams(
    MediaItem item, {
    Episode? episode,
  }) async =>
      Err<StreamResult>(PluginUnsupportedError('not used', pluginId: info.id));

  @override
  Future<void> dispose() async {}
}
