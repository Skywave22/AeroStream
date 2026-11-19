import 'package:aerostream/core/errors/plugin_error.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/episode.dart';
import 'package:aerostream/domain/entities/home_section.dart';
import 'package:aerostream/domain/entities/media_details.dart';
import 'package:aerostream/domain/entities/media_item.dart';
import 'package:aerostream/domain/entities/plugin_info.dart';
import 'package:aerostream/domain/entities/stream_source.dart';
import 'package:aerostream/domain/media_provider.dart';
import 'package:aerostream/domain/services/catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CatalogService.home', () {
    test('merges rows from every provider in priority order', () async {
      final first = _FakeProvider(
        id: 'a',
        priority: 0,
        homeHandler: () async => Ok([
          _section('Trending', ['Dune'])
        ]),
      );
      final second = _FakeProvider(
        id: 'b',
        priority: 1,
        homeHandler: () async => Ok([
          _section('New releases', ['Arrival'])
        ]),
      );

      final sections = await CatalogService.home([first, second]);

      expect(sections.map((section) => section.title), [
        'Trending',
        'New releases',
      ]);
      expect(sections.first.items.single.pluginId, 'a');
    });

    test('drops a provider that fails, keeping the rest', () async {
      final broken = _FakeProvider(
        id: 'broken',
        homeHandler: () async => const Err(PluginCrashError('boom')),
      );
      final healthy = _FakeProvider(
        id: 'healthy',
        homeHandler: () async => Ok([
          _section('Trending', ['Dune'])
        ]),
      );

      final sections = await CatalogService.home([broken, healthy]);

      expect(sections, hasLength(1));
      expect(sections.single.title, 'Trending');
    });

    test('drops a provider that throws instead of returning Err', () async {
      final thrower = _FakeProvider(
        id: 'thrower',
        homeHandler: () async => throw StateError('boom'),
      );
      final healthy = _FakeProvider(
        id: 'healthy',
        homeHandler: () async => Ok([
          _section('Trending', ['Dune'])
        ]),
      );

      final sections = await CatalogService.home([thrower, healthy]);

      expect(sections.single.title, 'Trending');
    });

    test('drops a provider that hangs past the timeout', () async {
      final slow = _FakeProvider(
        id: 'slow',
        homeHandler: () async {
          await Future<void>.delayed(const Duration(seconds: 5));
          return Ok([
            _section('Slow', ['Nope'])
          ]);
        },
      );

      final sections = await CatalogService.home(
        [slow],
        timeout: const Duration(milliseconds: 50),
      );

      expect(sections, isEmpty);
    });

    test('collapses duplicate titles within a row', () async {
      final provider = _FakeProvider(
        id: 'a',
        homeHandler: () async => Ok([
          _section('Trending', ['Dune', 'dune', 'Arrival'])
        ]),
      );

      final sections = await CatalogService.home([provider]);

      expect(sections.single.items.map((item) => item.title), [
        'Dune',
        'Arrival',
      ]);
    });

    test('never emits an empty row', () async {
      final provider = _FakeProvider(
        id: 'a',
        homeHandler: () async => Ok([_section('Empty', const [])]),
      );

      final sections = await CatalogService.home([provider]);

      expect(sections, isEmpty);
    });

    test('returns nothing when no providers exist', () async {
      expect(await CatalogService.home([]), isEmpty);
    });
  });

  group('CatalogService.search', () {
    test('groups results and sorts plugin failures last', () async {
      final ok = _FakeProvider(
        id: 'ok',
        priority: 5,
        searchHandler: (query, page) async =>
            Ok(SearchPage(items: [_item('Dune', 'ok')], hasMore: true)),
      );
      final failed = _FakeProvider(
        id: 'failed',
        priority: 0,
        searchHandler: (query, page) async => const Err(PluginNetworkError('offline')),
      );

      final groups = await CatalogService.search([failed, ok], 'dune');

      expect(groups.map((group) => group.plugin.id), ['ok', 'failed']);
      expect(groups.first.items.single.title, 'Dune');
      expect(groups.first.hasMore, isTrue);
      expect(groups.last.error, isA<PluginNetworkError>());
    });

    test('skips plugins that returned nothing at all', () async {
      final empty = _FakeProvider(
        id: 'empty',
        searchHandler: (query, page) async => const Ok(SearchPage(items: [])),
      );

      expect(await CatalogService.search([empty], 'dune'), isEmpty);
    });

    test('ignores a blank query', () async {
      final provider = _FakeProvider(
        id: 'p',
        searchHandler: (q, p) async => fail('called'),
      );

      expect(await CatalogService.search([provider], '   '), isEmpty);
    });
  });

  test('providerFor resolves the owning plugin', () {
    final provider = _FakeProvider(id: 'a');
    expect(
        CatalogService.providerFor([provider], _item('Dune', 'a')), provider);
    expect(CatalogService.providerFor([provider], _item('Dune', 'b')), isNull);
  });
}

HomeSection _section(String title, List<String> titles) => HomeSection(
      title: title,
      items: titles.map((name) => _item(name, 'a')).toList(growable: false),
    );

MediaItem _item(String title, String pluginId) => MediaItem(
      id: '$pluginId:$title',
      pluginId: pluginId,
      title: title,
      type: MediaType.movie,
    );

/// A provider whose behaviour each test supplies, so the aggregator's contract
/// is exercised without any JavaScript.
final class _FakeProvider implements MediaProvider {
  _FakeProvider({
    required String id,
    int priority = 0,
    this.homeHandler,
    this.searchHandler,
  }) : info = PluginInfo(
          id: id,
          name: 'Plugin $id',
          ecosystem: PluginEcosystem.skystream,
          priority: priority,
        );

  @override
  final PluginInfo info;

  final Future<Result<List<HomeSection>>> Function()? homeHandler;
  final Future<Result<SearchPage>> Function(String query, int page)?
  searchHandler;

  @override
  PluginCapabilities get capabilities => PluginCapabilities.all;

  @override
  Future<Result<List<HomeSection>>> getHome() async =>
      homeHandler == null ? const Ok(<HomeSection>[]) : homeHandler!();

  @override
  Future<Result<SearchPage>> search(String query, {int page = 1}) async =>
      searchHandler == null
          ? const Ok(SearchPage(items: []))
          : searchHandler!(query, page);

  @override
  Future<Result<MediaDetails>> getDetails(MediaItem item) async =>
      Err(PluginUnsupportedError('details', pluginId: info.id));

  @override
  Future<Result<List<Episode>>> getEpisodes(MediaItem item,
          {Season? season}) async =>
      const Ok(<Episode>[]);

  @override
  Future<Result<StreamResult>> getStreams(MediaItem item,
          {Episode? episode}) async =>
      const Ok(StreamResult(sources: []));

  @override
  Future<void> dispose() async {}
}
