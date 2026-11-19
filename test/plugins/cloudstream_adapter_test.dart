import 'package:aerostream/core/errors/plugin_error.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/domain/entities/enums.dart';
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

/// A host that answers from a script instead of a DEX file.
final class _ScriptedBridge implements CloudStreamBridge {
  _ScriptedBridge({
    Map<String, Map<String, Object?>>? replies,
    this.available = true,
  }) : replies = replies ?? const <String, Map<String, Object?>>{};

  final Map<String, Map<String, Object?>> replies;
  final bool available;
  final List<String> commands = <String>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<Result<Map<String, Object?>>> invoke(
    String command,
    Map<String, Object?> arguments, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    commands.add(command);
    final reply = replies[command];
    if (reply == null) return const Err<Map<String, Object?>>(
      PluginNetworkError('no such command'),
    );
    return Ok<Map<String, Object?>>(reply);
  }
}

CloudStreamAdapter _adapter(CloudStreamBridge bridge) => CloudStreamAdapter(
  info: _info,
  bridge: bridge,
  artifactPath: '/plugins/cloudstream/com.example/1/plugin.cs3',
);

MediaItem _item() => MediaItem(
  id: 'com.example:item',
  pluginId: _info.id,
  title: 'Dune',
  type: MediaType.movie,
  url: 'https://example.com/dune',
);

void main() {
  group('CloudStreamAdapter mapping', () {
    test('home keeps named sections and drops empty ones', () {
      final adapter = _adapter(_ScriptedBridge());

      final sections = adapter.mapHome(<String, Object?>{
        'sections': <Object?>[
          <String, Object?>{
            'name': 'Trending',
            'items': <Object?>[
              <String, Object?>{
                'title': 'Dune',
                'url': 'https://example.com/dune',
                'posterUrl': 'https://example.com/dune.jpg',
                'year': 2021,
              },
            ],
          },
          <String, Object?>{'name': 'Empty', 'items': <Object?>[]},
        ],
      });

      expect(sections, hasLength(1));
      expect(sections.single.title, 'Trending');
      expect(sections.single.items.single.title, 'Dune');
      expect(sections.single.items.single.pluginId, 'com.example');
    });

    test('a bare item list still becomes one row', () {
      final adapter = _adapter(_ScriptedBridge());

      final sections = adapter.mapHome(<String, Object?>{
        'items': <Object?>[
          <String, Object?>{'title': 'Arrival', 'url': 'https://example.com/a'},
        ],
      });

      expect(sections.single.title, 'Latest');
      expect(sections.single.items, hasLength(1));
    });

    test('details map episodes with their season and data', () {
      final adapter = _adapter(_ScriptedBridge());

      final details = adapter.mapDetails(
        <String, Object?>{
          'item': <String, Object?>{
            'title': 'Dune',
            'url': 'https://example.com/dune',
            'description': 'Spice.',
            'year': 2021,
          },
          'episodes': <Object?>[
            <String, Object?>{
              'name': 'Pilot',
              'url': 'https://example.com/s1e1',
              'season': 1,
              'episode': 1,
              'data': <String, Object?>{'token': 'opaque-token'},
            },
            <String, Object?>{'name': 'No URL'},
          ],
        },
        fallback: _item(),
      );

      expect(details.episodes, hasLength(1));
      final episode = details.episodes.single;
      expect(episode.title, 'Pilot');
      expect(episode.seasonNumber, 1);
      expect(episode.number, 1);
      expect(episode.extras['token'], 'opaque-token');
      expect(details.item.id, 'com.example:item');
    });

    test('links become typed sources, subtitles survive without a language',
        () {
      final adapter = _adapter(_ScriptedBridge());

      final raw = <String, Object?>{
        'links': <Object?>[
          <String, Object?>{
            'url': 'https://cdn.example.com/a.m3u8',
            'name': 'Server 1',
            'quality': '1080p',
            'isM3u8': true,
            'headers': <String, Object?>{'User-Agent': 'AeroStream'},
          },
          <String, Object?>{
            'url': 'https://cdn.example.com/b.mp4',
            'name': 'Server 2',
            'isM3u8': false,
          },
          <String, Object?>{'name': 'Broken'},
        ],
        'subtitles': <Object?>[
          <String, Object?>{'url': 'https://example.com/en.vtt'},
        ],
      };

      final sources = adapter.mapStreams(raw);
      expect(sources, hasLength(2));
      expect(sources.first.isHls, isTrue);
      expect(sources.first.headers['User-Agent'], 'AeroStream');
      expect(sources[1].isHls, isFalse);

      final subtitles = adapter.mapSubtitles(raw);
      expect(subtitles.single.language, 'und');
    });
  });

  group('CloudStreamAdapter host calls', () {
    test('getHome asks the host and maps the answer', () async {
      final bridge = _ScriptedBridge(
        replies: <String, Map<String, Object?>>{
          'getMainPage': <String, Object?>{
            'sections': <Object?>[
              <String, Object?>{
                'name': 'Trending',
                'items': <Object?>[
                  <String, Object?>{
                    'title': 'Dune',
                    'url': 'https://example.com/dune',
                  },
                ],
              },
            ],
          },
        },
      );

      final result = await _adapter(bridge).getHome();

      expect(result.valueOrNull, hasLength(1));
      expect(bridge.commands, contains('getMainPage'));
    });

    test('a host failure becomes a typed error, not an exception', () async {
      final result = await _adapter(_ScriptedBridge()).getStreams(_item());

      expect(result.isErr, isTrue);
      expect(result.errorOrNull, isA<PluginNetworkError>());
    });

    test('unload tells the host to release the extension', () async {
      final bridge = _ScriptedBridge(
        replies: <String, Map<String, Object?>>{
          'unloadPlugin': <String, Object?>{},
        },
      );

      await _adapter(bridge).unload();

      expect(bridge.commands, contains('unloadPlugin'));
    });
  });
}
