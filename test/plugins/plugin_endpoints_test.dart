import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/plugin_info.dart';
import 'package:aerostream/plugins/manager/plugin_endpoint_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

PluginInfo _info({
  List<PluginEndpoint> endpoints = const <PluginEndpoint>[],
}) =>
    PluginInfo(
      id: 'dev.example.stars',
      name: 'Stars',
      ecosystem: PluginEcosystem.skystream,
      endpoints: endpoints,
    );

void main() {
  group('PluginEndpoint.parseAll', () {
    test('domains accept both the string and the object form', () {
      final endpoints = PluginEndpoint.parseAll(<String, Object?>{
        'domains': <Object?>[
          'https://primary.example',
          <String, Object?>{
            'name': 'mirror1.com',
            'url': 'https://mirror1.example',
          },
          <String, Object?>{'name': 'no url, dropped'},
        ],
      });

      expect(endpoints, hasLength(2));
      expect(endpoints.first.name, 'primary.example');
      expect(endpoints.first.baseUrl, 'https://primary.example');
      expect(endpoints.first.isSubProvider, isFalse);
      expect(endpoints.last.name, 'mirror1.com');
    });

    test('providers keep their id and optional static URL', () {
      final endpoints = PluginEndpoint.parseAll(<String, Object?>{
        'providers': <Object?>[
          <String, Object?>{
            'id': 'feed1',
            'name': 'Feed One',
            'baseUrl': 'https://feed1.example/list.m3u',
          },
          <String, Object?>{'id': 'FeedTwo', 'name': 'Feed Two'},
          <String, Object?>{'name': 'no id, dropped'},
        ],
      });

      expect(endpoints, hasLength(2));
      expect(endpoints.first.isSubProvider, isTrue);
      expect(endpoints.first.manifestOverrides, <String, Object?>{
        'baseUrl': 'https://feed1.example/list.m3u',
        'providerId': 'feed1',
      });
      // A dynamic provider carries no URL: the plugin resolves it at runtime.
      expect(endpoints.last.manifestOverrides, <String, Object?>{
        'providerId': 'FeedTwo',
      });
    });

    test('a plugin with neither key has no endpoints', () {
      expect(PluginEndpoint.parseAll(const <String, Object?>{}), isEmpty);
    });

    test('survives a round trip through PluginInfo JSON', () {
      final info = _info(
        endpoints: PluginEndpoint.parseAll(<String, Object?>{
          'domains': <Object?>['https://a.example'],
          'providers': <Object?>[
            <String, Object?>{'id': 'p1', 'name': 'One'},
          ],
        }),
      );

      final copy = PluginInfo.fromJson(info.toJson());
      expect(copy.endpoints, hasLength(2));
      expect(copy.endpoints.first.baseUrl, 'https://a.example');
      expect(copy.endpoints.last.isSubProvider, isTrue);
    });
  });

  group('PluginEndpointStore', () {
    test('no selection leaves the manifest exactly as published', () {
      final store = PluginEndpointStore(InMemorySettingsStore());
      final manifest = <String, Object?>{'baseUrl': 'https://published'};
      final info = _info(
        endpoints: PluginEndpoint.parseAll(<String, Object?>{
          'domains': <Object?>['https://mirror'],
        }),
      );

      expect(store.selected(info), isNull);
      expect(store.manifestFor(info, manifest), manifest);
    });

    test('a chosen mirror overrides baseUrl and persists across reads', () async {
      final settings = InMemorySettingsStore();
      final store = PluginEndpointStore(settings);
      final info = _info(
        endpoints: PluginEndpoint.parseAll(<String, Object?>{
          'domains': <Object?>[
            'https://primary',
            'https://mirror',
          ],
        }),
      );

      await store.select(info.id, info.endpoints.last);

      expect(settings.getString(PluginEndpointStore.keyFor(info.id)),
          'https://mirror');
      final reopened = PluginEndpointStore(settings);
      expect(reopened.selected(info)?.baseUrl, 'https://mirror');
      expect(
        reopened.manifestFor(info, <String, Object?>{'baseUrl': 'https://primary'}),
        <String, Object?>{'baseUrl': 'https://mirror'},
      );
    });

    test('a chosen sub-provider injects its id', () async {
      final store = PluginEndpointStore(InMemorySettingsStore());
      final info = _info(
        endpoints: PluginEndpoint.parseAll(<String, Object?>{
          'providers': <Object?>[
            <String, Object?>{'id': 'one', 'name': 'One'},
            <String, Object?>{'id': 'two', 'name': 'Two'},
          ],
        }),
      );

      await store.select(info.id, info.endpoints[1]);
      final manifest = store.manifestFor(info, <String, Object?>{
        'baseUrl': 'https://api.example',
      });

      expect(manifest['providerId'], 'two');
      expect(manifest['baseUrl'], 'https://api.example');
    });

    test('a mirror that vanished in a new version falls back to the default',
        () async {
      final settings = InMemorySettingsStore()
        ..values[PluginEndpointStore.keyFor('dev.example.stars')] =
            'https://gone';
      final store = PluginEndpointStore(settings);
      final info = _info(
        endpoints: PluginEndpoint.parseAll(<String, Object?>{
          'domains': <Object?>['https://still-here'],
        }),
      );

      expect(store.selected(info), isNull);
    });

    test('choosing the default again forgets the setting', () async {
      final settings = InMemorySettingsStore();
      final store = PluginEndpointStore(settings);
      final info = _info(
        endpoints: PluginEndpoint.parseAll(<String, Object?>{
          'domains': <Object?>['https://mirror'],
        }),
      );

      await store.select(info.id, info.endpoints.single);
      await store.select(info.id, null);

      expect(settings.getString(PluginEndpointStore.keyFor(info.id)), isNull);
    });
  });
}
