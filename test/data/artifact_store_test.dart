import 'dart:convert';
import 'dart:io';

import 'package:aerostream/core/archive/zip_utils.dart';
import 'package:aerostream/data/storage/file_artifact_store.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a zip the way a plugin repository would.
List<int> buildZip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive)!;
}

void main() {
  late Directory root;
  late FileArtifactStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('aerostream-artifacts');
    store = FileArtifactStore('${root.path}/plugins');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('ZipUtils', () {
    test('extracts a well-formed package', () {
      final bytes = buildZip(<String, String>{
        'plugin.json': '{"packageName":"a.b"}',
        'plugin.js': 'globalThis.getHome = () => {};',
        'lib/helper.js': '// helper',
      });
      final extracted = ZipUtils.extract(bytes);
      expect(extracted.isOk, isTrue);
      expect(
        extracted.valueOrNull!.keys,
        containsAll(<String>['plugin.json', 'plugin.js', 'lib/helper.js']),
      );
    });

    test('rejects a zip-slip entry instead of writing outside the root', () {
      final bytes = buildZip(<String, String>{
        '../../evil.txt': 'pwned',
        'plugin.json': '{}',
      });
      final extracted = ZipUtils.extract(bytes);
      expect(extracted.isErr, isTrue);
      expect(extracted.errorOrNull!.kind, 'sandbox');
      expect(
        (extracted.errorOrNull! as dynamic).violation,
        'path-traversal',
      );
    });

    test('rejects an empty archive', () {
      final bytes = ZipEncoder().encode(Archive())!;
      expect(ZipUtils.extract(bytes).isErr, isTrue);
    });

    test('decodes a manifest and tolerates junk', () {
      expect(
        ZipUtils.decodeManifest(utf8.encode('{"name":"x"}')),
        <String, Object?>{'name': 'x'},
      );
      expect(ZipUtils.decodeManifest(utf8.encode('not json')), isNull);
      expect(ZipUtils.decodeManifest(utf8.encode('[1,2]')), isNull);
    });
  });

  group('FileArtifactStore', () {
    test('installs files and reports the artifact path', () async {
      final result = await store.install(
        ecosystem: PluginEcosystem.skystream,
        id: 'dev.example.plugin',
        version: '3',
        files: <String, List<int>>{
          'plugin.json': utf8.encode('{"packageName":"dev.example.plugin"}'),
          'plugin.js': utf8.encode('// code'),
        },
      );

      expect(result.isOk, isTrue);
      final path = result.valueOrNull!;
      expect(File('$path/plugin.json').existsSync(), isTrue);
      expect(await store.readEntry(path, 'plugin.json'), contains('packageName'));
      expect(await store.exists(path), isTrue);
      expect(await store.listEntries(path), containsAll(<String>[
        'plugin.json',
        'plugin.js',
      ]));
      expect(await store.totalSize(), greaterThan(0));
    });

    test('keeps the previous version when an update is staged elsewhere',
        () async {
      final first = await store.install(
        ecosystem: PluginEcosystem.skystream,
        id: 'dev.example.plugin',
        version: '1',
        files: <String, List<int>>{'plugin.js': utf8.encode('// v1')},
      );
      final second = await store.install(
        ecosystem: PluginEcosystem.skystream,
        id: 'dev.example.plugin',
        version: '2',
        files: <String, List<int>>{'plugin.js': utf8.encode('// v2')},
      );

      expect(second.isOk, isTrue);
      expect(
        await store.readEntry(first.valueOrNull!, 'plugin.js'),
        '// v1',
        reason: 'versions live in separate directories, so rollback works',
      );
      expect(await store.readEntry(second.valueOrNull!, 'plugin.js'), '// v2');
    });

    test('replacing the same version is atomic and leaves no staging dir',
        () async {
      await store.install(
        ecosystem: PluginEcosystem.skystream,
        id: 'p',
        version: '1',
        files: <String, List<int>>{'plugin.js': utf8.encode('// one')},
      );
      final again = await store.install(
        ecosystem: PluginEcosystem.skystream,
        id: 'p',
        version: '1',
        files: <String, List<int>>{'plugin.js': utf8.encode('// two')},
      );
      expect(await store.readEntry(again.valueOrNull!, 'plugin.js'), '// two');

      final leftovers = Directory('${root.path}/plugins/skystream/p')
          .listSync()
          .where((entity) => entity.path.contains('.staging-'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('refuses an unsafe plugin id', () async {
      final result = await store.install(
        ecosystem: PluginEcosystem.skystream,
        id: '../../etc',
        version: '1',
        files: <String, List<int>>{'plugin.js': utf8.encode('')},
      );
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'sandbox');
    });

    test('refuses an artifact whose hash does not match', () async {
      final bytes = utf8.encode('payload');
      final wrong = 'sha256-${List<String>.filled(64, '0').join()}';
      final result = await store.install(
        ecosystem: PluginEcosystem.cloudstream,
        id: 'provider',
        version: '1',
        files: <String, List<int>>{'plugin.cs3': bytes},
        originalArchive: bytes,
        expectedSha256: wrong,
      );
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'sandbox');
    });

    test('accepts an artifact whose hash matches', () async {
      final bytes = utf8.encode('payload');
      final digest = sha256.convert(bytes).toString();
      final result = await store.install(
        ecosystem: PluginEcosystem.cloudstream,
        id: 'provider',
        version: '1',
        files: <String, List<int>>{'plugin.cs3': bytes},
        originalArchive: bytes,
        expectedSha256: 'sha256-$digest',
      );
      expect(result.isOk, isTrue);
    });

    test('never deletes outside the plugin root', () async {
      final outside = File('${root.path}/keep-me.txt')
        ..writeAsStringSync('important');
      await store.remove(outside.path);
      expect(outside.existsSync(), isTrue);
    });

    test('reports a missing artifact as not existing', () async {
      expect(await store.exists('${root.path}/plugins/skystream/nope/1'),
          isFalse);
      expect(
        await store.readEntry('${root.path}/plugins/skystream/nope/1',
            'plugin.json'),
        isNull,
      );
    });
  });

  group('FileArtifactStore isolation', () {
    test('a failed install leaves no partial version behind', () async {
      final result = await store.install(
        ecosystem: PluginEcosystem.skystream,
        id: 'p',
        version: '1',
        files: <String, List<int>>{
          'ok.js': utf8.encode('// fine'),
          '../escape.js': utf8.encode('// nope'),
        },
      );

      expect(result.isErr, isTrue);
      final versionDir = Directory('${root.path}/plugins/skystream/p/1');
      expect(versionDir.existsSync(), isFalse);
      expect(
        Directory('${root.path}/plugins/skystream/p')
            .listSync()
            .where((entity) => entity.path.contains('.staging-')),
        isEmpty,
      );
    });
  });
}
