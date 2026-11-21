import 'package:aerostream/app/providers.dart';
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
import 'package:aerostream/features/home/home_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  test('Home uses all providers until the user customizes it', () async {
    final store = InMemorySettingsStore();
    final first = _HomeProvider('first');
    final second = _HomeProvider('second');
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        mediaProvidersProvider.overrideWith((ref) async => [first, second]),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(homeProviderSelectionProvider).isAll, isTrue);
    final sections = await container.read(homeFeedProvider.future);
    expect(sections.map((section) => section.title), ['first', 'second']);
  });

  test('Home only calls explicitly selected providers', () async {
    final store = InMemorySettingsStore()
      ..values[HomeProviderSelectionController.settingsKey] =
          '["skystream:second"]';
    final first = _HomeProvider('first');
    final second = _HomeProvider('second');
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        mediaProvidersProvider.overrideWith((ref) async => [first, second]),
      ],
    );
    addTearDown(container.dispose);

    final sections = await container.read(homeFeedProvider.future);
    expect(sections.single.title, 'second');
    expect(first.homeCalls, 0);
    expect(second.homeCalls, 1);
  });

  test('an explicit empty selection does not start provider runtimes',
      () async {
    final store = InMemorySettingsStore()
      ..values[HomeProviderSelectionController.settingsKey] = '[]';
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        mediaProvidersProvider.overrideWith(
          (ref) => throw StateError('must not be read'),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(homeFeedProvider.future), isEmpty);
  });

  test('leaving All snapshots other available providers and persists',
      () async {
    final store = InMemorySettingsStore();
    final container = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );

    await container.read(homeProviderSelectionProvider.notifier).setProvider(
      key: 'skystream:first',
      selected: false,
      availableKeys: const <String>[
        'skystream:first',
        'vega:second',
      ],
    );
    final selection = container.read(homeProviderSelectionProvider);
    expect(selection.isAll, isFalse);
    expect(selection.keys, <String>{'vega:second'});
    expect(
      store.values[HomeProviderSelectionController.settingsKey],
      '["vega:second"]',
    );
    container.dispose();

    final restored = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
    );
    addTearDown(restored.dispose);
    expect(
      restored.read(homeProviderSelectionProvider).keys,
      <String>{'vega:second'},
    );
  });
}

final class _HomeProvider implements MediaProvider {
  _HomeProvider(String id)
      : info = PluginInfo(
          id: id,
          name: id,
          ecosystem: PluginEcosystem.skystream,
          capabilities: const PluginCapabilities(home: true, search: true),
        );

  @override
  final PluginInfo info;

  int homeCalls = 0;

  @override
  PluginCapabilities get capabilities => info.capabilities;

  @override
  Future<Result<List<HomeSection>>> getHome() async {
    homeCalls++;
    return Ok<List<HomeSection>>(
      <HomeSection>[
        HomeSection(
          title: info.id,
          items: <MediaItem>[
            MediaItem(
              id: '${info.id}:item',
              pluginId: info.id,
              title: '${info.name} item',
              type: MediaType.movie,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<Result<SearchPage>> search(String query, {int page = 1}) async =>
      const Ok<SearchPage>(SearchPage(items: <MediaItem>[]));

  @override
  Future<Result<MediaDetails>> getDetails(MediaItem item) async =>
      Err<MediaDetails>(
        PluginUnsupportedError('details', pluginId: info.id),
      );

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
      const Ok<StreamResult>(StreamResult(sources: <StreamSource>[]));

  @override
  Future<void> dispose() async {}
}
