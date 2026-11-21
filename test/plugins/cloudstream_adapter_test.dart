import 'package:aerostream/core/errors/plugin_error.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/episode.dart';
import 'package:aerostream/domain/entities/media_item.dart';
import 'package:aerostream/domain/entities/plugin_info.dart';
import 'package:aerostream/plugins/adapters/cloudstream/cloudstream_adapter.dart';
import 'package:aerostream/plugins/adapters/cloudstream/cloudstream_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

const PluginInfo _info = PluginInfo(
  id: 'com.example',
  name: 'Example',
  ecosystem: PluginEcosystem.cloudstream,
  capabilities: PluginCapabilities.all,
);

typedef _Handler = Result<Map<String, Object?>> Function(
  String method,
  Map<String, Object?> arguments,
);

/// An engine protocol endpoint backed by a test callback instead of a JVM.
final class _ScriptedBridge implements CloudStreamBridge {
  _ScriptedBridge(this.handler);

  final _Handler handler;
  final List<({String method, Map<String, Object?> arguments})> calls = [];

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<Map<String, Object?>> get events =>
      const Stream<Map<String, Object?>>.empty();

  @override
  Future<Result<Map<String, Object?>>> invoke(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    calls.add((method: method, arguments: arguments));
    return handler(method, arguments);
  }

  @override
  Future<void> dispose() async {}
}

CloudStreamAdapter _adapter(
  CloudStreamBridge bridge, {
  List<Map<String, Object?>>? providers,
}) =>
    CloudStreamAdapter(
      info: _info,
      bridge: bridge,
      artifactPath: '/plugins/cloudstream/com.example/1/plugin.cs3',
      providers: providers ??
          const <Map<String, Object?>>[
            <String, Object?>{
              'name': 'MoviesApi',
              'mainUrl': 'https://example.com',
              'hasMainPage': true,
            },
          ],
    );

MediaItem _item({String provider = 'MoviesApi'}) => MediaItem(
      id: 'com.example:item',
      pluginId: _info.id,
      title: 'Dune',
      type: MediaType.movie,
      url: 'https://example.com/dune',
      extras: <String, Object?>{'cloudstreamProvider': provider},
    );

Err<Map<String, Object?>> _missing(String method) =>
    Err(PluginNetworkError('no scripted response for $method'));

void main() {
  test(
    'home uses mainPage and preserves the provider that owns every item',
    () async {
      final bridge = _ScriptedBridge((method, arguments) {
        if (method != 'mainPage') return _missing(method);
        return const Ok<Map<String, Object?>>(<String, Object?>{
          'sections': <Object?>[
            <String, Object?>{
              'name': 'Trending',
              'items': <Object?>[
                <String, Object?>{
                  'name': 'Dune',
                  'url': 'https://example.com/dune',
                  'posterUrl': '/dune.jpg',
                  'year': 2021,
                },
              ],
            },
            <String, Object?>{'name': 'Empty', 'items': <Object?>[]},
          ],
        });
      });

      final result = await _adapter(bridge).getHome();
      final sections = result.valueOrNull!;

      expect(sections, hasLength(1));
      expect(sections.single.title, 'Trending');
      expect(
        sections.single.items.single.posterUrl,
        'https://example.com/dune.jpg',
      );
      expect(
        sections.single.items.single.extras['cloudstreamProvider'],
        'MoviesApi',
      );
      expect(bridge.calls.single.method, 'mainPage');
      expect(
        bridge.calls.single.arguments,
        containsPair('plugin', contains('.cs3')),
      );
    },
  );

  test('one extension searches every registered provider', () async {
    final bridge = _ScriptedBridge((method, arguments) {
      if (method != 'search') return _missing(method);
      final provider = arguments['provider']! as String;
      return Ok<Map<String, Object?>>(<String, Object?>{
        'items': <Object?>[
          <String, Object?>{
            'name': '$provider result',
            'url': 'https://$provider.test/title',
          },
        ],
        'hasNext': provider == 'SeriesApi',
      });
    });
    final adapter = _adapter(
      bridge,
      providers: const <Map<String, Object?>>[
        <String, Object?>{'name': 'MoviesApi'},
        <String, Object?>{'name': 'SeriesApi'},
      ],
    );

    final page = (await adapter.search('dune', page: 2)).valueOrNull!;

    expect(page.items.map((item) => item.title), <String>[
      'MoviesApi result',
      'SeriesApi result',
    ]);
    expect(page.items[1].extras['cloudstreamProvider'], 'SeriesApi');
    expect(page.hasMore, isTrue);
    expect(page.nextPage, 3);
    expect(bridge.calls.map((call) => call.arguments['provider']), <Object?>[
      'MoviesApi',
      'SeriesApi',
    ]);
  });

  test(
    'load maps direct engine response and keeps episode data opaque',
    () async {
      final bridge = _ScriptedBridge((method, arguments) {
        if (method != 'load') return _missing(method);
        expect(arguments['provider'], 'MoviesApi');
        return const Ok<Map<String, Object?>>(<String, Object?>{
          'name': 'Dune',
          'url': 'https://example.com/dune',
          'type': 'TvSeries',
          'plot': 'Spice.',
          'posterUrl': '/poster.jpg',
          'duration': 48,
          'contentRating': 'TV-14',
          'syncIds': <String, Object?>{'imdb': 'tt123'},
          'seasonNames': <Object?>[
            <String, Object?>{'season': 1, 'name': 'Book One'},
          ],
          'episodes': <Object?>[
            <String, Object?>{
              'name': 'Pilot',
              'season': 1,
              'episode': 1,
              'data': 'opaque://token?not=a-url-contract',
              'runTime': 48,
              'date': 1736002800000,
            },
          ],
        });
      });

      final details = (await _adapter(bridge).getDetails(_item())).valueOrNull!;

      expect(details.item.id, 'com.example:item');
      expect(details.description, 'Spice.');
      expect(details.seasons.single.title, 'Book One');
      expect(details.syncData['imdb'], 'tt123');
      expect(details.episodes, hasLength(1));
      final episode = details.episodes.single;
      expect(episode.url, 'opaque://token?not=a-url-contract');
      expect(
        episode.extras['cloudstreamData'],
        'opaque://token?not=a-url-contract',
      );
      expect(episode.runtimeMinutes, 48);
      expect(episode.airDate, isNotNull);
    },
  );

  test('movie dataUrl is sent to loadLinks unchanged', () async {
    final bridge = _ScriptedBridge((method, arguments) {
      if (method == 'load') {
        return const Ok<Map<String, Object?>>(<String, Object?>{
          'name': 'Dune',
          'url': 'https://example.com/dune',
          'type': 'Movie',
          'dataUrl': 'opaque movie payload',
        });
      }
      if (method == 'loadLinks') {
        expect(arguments['data'], 'opaque movie payload');
        return const Ok<Map<String, Object?>>(<String, Object?>{
          'links': <Object?>[],
          'subtitles': <Object?>[],
          'completed': true,
        });
      }
      return _missing(method);
    });
    final adapter = _adapter(bridge);
    final details = (await adapter.getDetails(_item())).valueOrNull!;

    await adapter.getStreams(details.item);

    expect(bridge.calls.last.method, 'loadLinks');
  });

  test(
    'loadLinks maps headers, media type, subtitles and DRM information',
    () async {
      final bridge = _ScriptedBridge((method, arguments) {
        if (method != 'loadLinks') return _missing(method);
        expect(arguments['data'], 'episode-token');
        return const Ok<Map<String, Object?>>(<String, Object?>{
          'links': <Object?>[
            <String, Object?>{
              'source': 'VidCloud',
              'name': 'Server 1',
              'url': 'https://cdn.example.com/master.m3u8',
              'type': 'M3U8',
              'quality': 1080,
              'referer': 'https://example.com/',
              'headers': <String, Object?>{'Authorization': 'Bearer token'},
            },
            <String, Object?>{
              'source': 'WidevineHost',
              'name': 'Protected',
              'url': 'https://cdn.example.com/manifest.mpd',
              'type': 'DASH',
              'quality': 2160,
              'headers': <String, Object?>{},
              'drm': <String, Object?>{
                'kid': 'kid',
                'licenseUrl': 'https://licence.example.com',
              },
            },
          ],
          'subtitles': <Object?>[
            <String, Object?>{
              'lang': 'English',
              'url': 'https://cdn.example.com/en.srt',
              'headers': <String, Object?>{'Cookie': 'session=1'},
            },
          ],
          'completed': false,
          'error': 'one extractor failed',
        });
      });
      final result = await _adapter(bridge).getStreams(
        _item(),
        episode: const Episode(
          id: 'episode-1',
          url: 'episode-token',
          number: 1,
          extras: <String, Object?>{'cloudstreamData': 'episode-token'},
        ),
      );
      final streams = result.valueOrNull!;

      expect(streams.sources, hasLength(2));
      expect(streams.sources.first.isHls, isTrue);
      expect(streams.sources.first.quality, '1080p');
      expect(streams.sources.first.headers['Referer'], 'https://example.com/');
      expect(streams.sources.first.headers['Authorization'], 'Bearer token');
      expect(streams.sources[1].isDash, isTrue);
      expect(streams.sources[1].isDrmProtected, isTrue);
      expect(streams.subtitles.single.language, 'English');
      expect(streams.subtitles.single.format, 'srt');
      expect(streams.diagnostics, contains('one extractor failed'));
    },
  );

  test('engine failures stay typed and disposal unloads the DEX', () async {
    final bridge = _ScriptedBridge((method, arguments) {
      if (method == 'unloadPlugin') {
        return const Ok<Map<String, Object?>>(<String, Object?>{
          'unloaded': true,
        });
      }
      return const Err<Map<String, Object?>>(
        PluginNetworkError('engine unavailable'),
      );
    });
    final adapter = _adapter(bridge);

    final result = await adapter.getStreams(_item());
    await adapter.dispose();

    expect(result.errorOrNull, isA<PluginNetworkError>());
    expect(result.errorOrNull!.pluginId, _info.id);
    expect(bridge.calls.last.method, 'unloadPlugin');
    expect(bridge.calls.last.arguments['path'], endsWith('plugin.cs3'));
  });
}
