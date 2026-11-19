import 'package:aerostream/core/errors/plugin_error.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/media_item.dart';
import 'package:aerostream/domain/entities/plugin_info.dart';
import 'package:aerostream/plugins/adapters/vega/vega_adapter.dart';
import 'package:aerostream/plugins/runtime/js_host_api.dart';
import 'package:aerostream/plugins/runtime/js_plugin_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_js_runtime.dart';
import '../support/fakes.dart';

const PluginInfo _info = PluginInfo(
  id: 'example',
  name: 'Example',
  ecosystem: PluginEcosystem.vega,
  capabilities: PluginCapabilities.all,
);

VegaAdapter _adapter({Future<String?> Function(String script)? onEvaluate}) {
  final host = JsPluginHost(
    runtime: ScriptedJsRuntime(
      onEvaluate: onEvaluate ?? FakePlugin(value: null).onEvaluate,
    ),
    api: JsHostApi(
      http: FakeHttpService(),
      settings: InMemorySettingsStore(),
      pluginId: _info.id,
    ),
    pluginId: _info.id,
    bootstrap: '/* bootstrap */',
    pluginSource: '// plugin',
  );
  return VegaAdapter(info: _info, host: host, providerValue: 'example');
}

MediaItem _item({String? url}) => MediaItem(
  id: 'example:item',
  pluginId: _info.id,
  title: 'Dune',
  type: MediaType.movie,
  url: url,
);

void main() {
  group('VegaAdapter.getHome', () {
    test('maps a posts array onto one home row', () async {
      final adapter = _adapter(
        onEvaluate: (script) async {
          if (script.contains('__vegaHas')) return 'true';
          return FakePlugin(
            value: <Object?>[
              <String, Object?>{
                'title': 'Dune',
                'link': 'https://example.com/dune',
                'image': 'https://example.com/dune.jpg',
                'year': '2021',
              },
              <String, Object?>{'title': '', 'link': ''},
            ],
          ).onEvaluate(script);
        },
      );

      final result = await adapter.getHome();

      expect(result.isOk, isTrue);
      final items = result.valueOrNull!.single.items;
      expect(items, hasLength(1), reason: 'the blank entry is not an item');
      expect(items.single.title, 'Dune');
      expect(items.single.pluginId, 'example');
      expect(items.single.year, 2021);
    });

    test('reports an unsupported function instead of calling it', () async {
      final adapter = _adapter(onEvaluate: (script) async => 'false');

      final result = await adapter.getHome();

      expect(result.isErr, isTrue);
      expect(result.errorOrNull, isA<PluginUnsupportedError>());
    });
  });

  group('VegaAdapter mapping', () {
    test('details gain seasons, episodes and metadata from getMeta', () {
      final adapter = _adapter();

      final details = adapter.mapDetails(
        <String, Object?>{
          'title': 'Dune',
          'description': 'Spice.',
          'genres': <Object?>['Sci-Fi', 'Adventure'],
          'status': 'Released',
          'runtime': 155,
          'episodes': <Object?>[
            <String, Object?>{
              'link': 'https://example.com/s1e1',
              'season': 1,
              'episode': 1,
              'title': 'Pilot',
            },
            <String, Object?>{
              'link': 'https://example.com/s2e1',
              'season': 2,
              'episode': 1,
            },
            <String, Object?>{'title': 'no link, dropped'},
          ],
        },
        fallback: _item(url: 'https://example.com/dune'),
      );

      expect(details.description, 'Spice.');
      expect(details.genres, <String>['Sci-Fi', 'Adventure']);
      expect(details.runtimeMinutes, 155);
      expect(details.episodes, hasLength(2));
      expect(details.seasons.map((season) => season.number), <int>[1, 2]);
      expect(details.seasons.first.displayName, 'Season 1');
      expect(details.item.type, MediaType.series);
      expect(details.item.id, 'example:item', reason: 'identity is preserved');
    });

    test('streams are typed from the entry, the label and the URL', () {
      final adapter = _adapter();

      final sources = adapter.mapStreams(<String, Object?>{
        'sources': <Object?>[
          <String, Object?>{
            'server': 'Main',
            'link': 'https://cdn.example.com/a.m3u8',
            'type': 'm3u8',
            'quality': '1080p',
          },
          <String, Object?>{
            'server': 'Backup',
            'link': 'https://cdn.example.com/b.mpd',
            'type': 'mpd',
          },
          <String, Object?>{
            'server': 'Odd',
            'link': 'https://cdn.example.com/c.mp4',
            'type': 'mp4',
            'headers': <String, Object?>{'Referer': 'https://example.com'},
          },
          <String, Object?>{'server': 'Broken', 'link': 'not-a-url'},
        ],
      });

      expect(sources, hasLength(3), reason: 'a scheme-less link is not playable');
      expect(sources.first.isHls, isTrue);
      expect(sources.first.quality, '1080p');
      expect(sources[1].isDash, isTrue);
      expect(sources[2].isHls, isFalse);
      expect(sources[2].headers['Referer'], 'https://example.com');
    });

    test('subtitles keep only tracks that can be fetched', () {
      final adapter = _adapter();

      final tracks = adapter.mapSubtitles(<String, Object?>{
        'subtitles': <Object?>[
          <String, Object?>{
            'url': 'https://example.com/en.srt',
            'language': 'en',
            'label': 'English',
          },
          <String, Object?>{'url': 'https://example.com/und.srt'},
          <String, Object?>{'language': 'fr'},
        ],
      });

      expect(tracks, hasLength(2));
      expect(tracks.first.displayName, 'English');
      expect(tracks[1].language, 'und');
    });

    test('an empty payload yields no sections, not an exception', () async {
      final adapter = _adapter(
        onEvaluate: (script) async => script.contains('__vegaHas')
            ? 'true'
            : FakePlugin(value: <Object?>[]).onEvaluate(script),
      );

      final result = await adapter.getHome();

      expect(result.isOk, isTrue);
      expect(result.valueOrNull, isEmpty);
    });
  });
}
