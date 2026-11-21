import 'package:aerostream/domain/entities/enums.dart';
import 'package:aerostream/domain/entities/plugin_info.dart';
import 'package:aerostream/plugins/adapters/skystream/skystream_adapter.dart';
import 'package:aerostream/plugins/runtime/js_host_api.dart';
import 'package:aerostream/plugins/runtime/js_plugin_host.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_js_runtime.dart';
import '../support/fakes.dart';

const PluginInfo _info = PluginInfo(
  id: 'example',
  name: 'Example',
  ecosystem: PluginEcosystem.skystream,
  capabilities: PluginCapabilities.all,
);

SkyStreamAdapter _adapter() {
  final host = JsPluginHost(
    runtime: ScriptedJsRuntime(onEvaluate: FakePlugin(value: null).onEvaluate),
    api: JsHostApi(
      http: FakeHttpService(),
      settings: InMemorySettingsStore(),
      pluginId: _info.id,
    ),
    pluginId: _info.id,
    bootstrap: '/* bootstrap */',
    pluginSource: '// plugin',
  );
  return SkyStreamAdapter(
      info: _info, host: host, baseUrl: 'https://example.com');
}

void main() {
  group('SkyStreamAdapter streams', () {
    test('a numeric quality survives as a label', () {
      final sources = _adapter().mapStreams(<Object?>[
        <String, Object?>{
          'url': 'https://cdn.example.com/a.mp4',
          'source': 'Server 1',
          'quality': 1080,
        },
        <String, Object?>{
          'url': 'https://cdn.example.com/b.mp4',
          'quality': '720p',
        },
        <String, Object?>{
          'url': 'https://cdn.example.com/c.m3u8',
          'quality': 0,
        },
        <String, Object?>{
          'url': 'https://cdn.example.com/d.mp4',
          'quality': ' '
        },
      ]);

      expect(sources, hasLength(4));
      expect(sources[0].quality, '1080');
      expect(sources[0].label, 'Server 1');
      expect(sources[1].quality, '720p');
      expect(
        sources[2].quality,
        isNull,
        reason: '0 marks an HLS master, not a height',
      );
      expect(sources[2].isHls, isTrue);
      expect(sources[3].quality, isNull);
    });

    test('a DRM stream is flagged instead of silently attempted', () {
      final sources = _adapter().mapStreams(<Object?>[
        <String, Object?>{
          'url': 'https://cdn.example.com/drm.mpd',
          'drmKid': 'abc-123',
          'licenseUrl': 'https://widevine.example.com/licence',
        },
        <String, Object?>{'url': 'https://cdn.example.com/plain.mp4'},
      ]);

      expect(sources.first.isDrmProtected, isTrue);
      expect(sources.last.isDrmProtected, isFalse);
    });

    test('subtitles attached to a stream are merged with the envelope', () {
      final tracks = _adapter().mapSubtitles(<Object?>[
        <String, Object?>{
          'url': 'https://cdn.example.com/a.mp4',
          'subtitles': <Object?>[
            <String, Object?>{
              'url': 'https://example.com/en.srt',
              'label': 'English',
              'lang': 'en',
            },
          ],
        },
        <String, Object?>{
          'url': 'https://cdn.example.com/b.mp4',
          'subtitles': <Object?>[
            <String, Object?>{'url': 'https://example.com/en.srt'},
            <String, Object?>{
              'url': 'https://example.com/hi.srt',
              'lang': 'hi'
            },
          ],
        },
      ]);

      expect(tracks, hasLength(2), reason: 'the same URL is one track');
      expect(tracks.first.language, 'en',
          reason: '`lang` is the documented key');
      expect(tracks.first.displayName, 'English');
      expect(tracks.last.language, 'hi');
      expect(tracks.last.displayName, 'HI');
    });

    test('proxy-only links are reported, not dropped in silence', () {
      final diagnostics = _adapter().mapDiagnostics(<Object?>[
        <String, Object?>{'url': 'MAGIC_PROXY_v1aHR0cHM6Ly8'},
        <String, Object?>{'url': 'magic_m3u8:I0VYVE1VVA=='},
        <String, Object?>{
          'url': 'https://cdn.example.com/drm.mp4',
          'drmKid': 'kid',
        },
        <String, Object?>{'url': 'https://cdn.example.com/ok.mp4'},
      ]);

      expect(diagnostics, hasLength(2));
      expect(diagnostics.first, contains('2 links'));
      expect(diagnostics.first, contains('proxy'));
      expect(diagnostics.last, contains('DRM'));
    });

    test('no diagnostics means no noise', () {
      expect(
        _adapter().mapDiagnostics(<Object?>[
          <String, Object?>{'url': 'https://cdn.example.com/ok.mp4'},
        ]),
        isEmpty,
      );
    });
  });

  group('SkyStreamAdapter home', () {
    test('an envelope with a category map keeps Trending as the carousel', () {
      final sections = _adapter().mapHome(<String, Object?>{
        'Trending': <Object?>[
          <String, Object?>{'title': 'Dune', 'url': 'a', 'type': 'movie'},
        ],
        'Latest': <Object?>[
          <String, Object?>{'title': 'Arrival', 'url': 'b', 'type': 'movie'},
        ],
      });

      expect(sections.first.title, 'Trending');
      expect(sections.first.layout, HomeSectionLayout.carousel);
      expect(sections.last.layout, HomeSectionLayout.posterRow);
    });
  });

  group('SkyStreamAdapter search', () {
    // `search(query, cb)` takes one argument plus the callback. An earlier
    // adapter sent `[query, page]`, which put the page number in the callback
    // slot, so every callback-style plugin threw instead of answering.
    test('passes the query and no page', () async {
      final runtime = ScriptedJsRuntime(
        onEvaluate: FakePlugin(value: <Object?>[
          <String, Object?>{'title': 'Dune', 'url': 'dune-1', 'type': 'movie'},
        ]).onEvaluate,
      );
      final host = JsPluginHost(
        runtime: runtime,
        api: JsHostApi(
          http: FakeHttpService(),
          settings: InMemorySettingsStore(),
          pluginId: _info.id,
        ),
        pluginId: _info.id,
        bootstrap: '/* bootstrap */',
        pluginSource: '// plugin',
      );
      final adapter = SkyStreamAdapter(
        info: _info,
        host: host,
        baseUrl: 'https://example.com',
      );

      final result = await adapter.search('dune', page: 3);

      expect(result.isOk, isTrue, reason: result.errorOrNull?.toString());
      final invoke = runtime.scriptsStartingWith('__aeroInvoke').single;
      // The query arrives as a JSON string: single argument, no page.
      expect(invoke, contains(r'[\"dune\"]'));
      expect(invoke, isNot(contains('page')));
      expect(result.valueOrNull!.items.single.title, 'Dune');
      // Nothing to page with: SkyStream's SDK has no page parameter and hands
      // back a bare array, so the plugin decides how much it returns.
      expect(result.valueOrNull!.hasMore, isFalse);
      expect(result.valueOrNull!.nextPage, isNull);
    });
  });
}
