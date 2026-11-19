import 'package:aerostream/core/utils/version.dart';
import 'package:aerostream/domain/entities/entities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MediaItem', () {
    const item = MediaItem(
      id: 'skystream:demo:1',
      pluginId: 'skystream:demo',
      title: 'Dune',
      type: MediaType.movie,
      url: 'https://example.com/dune',
      posterUrl: 'https://example.com/dune.jpg',
      backdropUrl: 'https://example.com/dune-wide.jpg',
      year: 2021,
      rating: 8.1,
      description: 'Spice.',
      genres: <String>['Sci-Fi'],
      headers: <String, String>{'Referer': 'https://example.com'},
    );

    test('round-trips through JSON', () {
      final decoded = MediaItem.fromJson(item.toJson());
      expect(decoded.id, item.id);
      expect(decoded.title, item.title);
      expect(decoded.type, MediaType.movie);
      expect(decoded.year, 2021);
      expect(decoded.rating, 8.1);
      expect(decoded.headers['Referer'], 'https://example.com');
      expect(decoded, item);
    });

    test('survives a payload with the wrong types', () {
      final decoded = MediaItem.fromJson(<String, Object?>{
        'id': 7,
        'title': '',
        'year': '2024',
        'rating': '7.5',
        'genres': 'Action',
      });
      expect(decoded.id, '7');
      expect(decoded.title, 'Untitled');
      expect(decoded.year, 2024);
      expect(decoded.rating, 7.5);
      expect(decoded.genres, <String>['Action']);
    });

    test('copyWith keeps identity fields', () {
      final copy = item.copyWith(title: 'Dune: Part Two');
      expect(copy.title, 'Dune: Part Two');
      expect(copy.id, item.id);
      expect(copy.pluginId, item.pluginId);
      expect(copy == item, isFalse);
    });
  });

  group('Episode and Season', () {
    const episode = Episode(
      id: 'e1',
      url: 'https://example.com/ep1',
      number: 3,
      seasonNumber: 2,
      title: 'The One',
      runtimeMinutes: 42,
    );

    test('formats its label for the UI', () {
      expect(episode.label, 'S02E03');
      expect(episode.displayName, '3. The One');
      expect(
        episode.copyWith(title: null).displayName,
        '3. The One',
        reason: 'copyWith cannot clear a title; null means "unchanged"',
      );
    });

    test('falls back to "Episode n" for untitled episodes', () {
      const untitled = Episode(id: 'e2', url: '', number: 2);
      expect(untitled.displayName, 'Episode 2');
    });

    test('round-trips', () {
      final decoded = Episode.fromJson(episode.toJson());
      expect(decoded.number, 3);
      expect(decoded.seasonNumber, 2);
      expect(decoded.runtimeMinutes, 42);
      expect(decoded, episode);
    });

    test('Season display name', () {
      expect(const Season(number: 1).displayName, 'Season 1');
      expect(
        const Season(number: 1, title: 'Specials').displayName,
        'Specials',
      );
    });
  });

  group('MediaDetails', () {
    test('derives seasons from a flat episode list', () {
      const details = MediaDetails(
        item: MediaItem(id: 'x', pluginId: 'p', title: 'Show'),
        episodes: <Episode>[
          Episode(id: 'a', url: '', number: 1, seasonNumber: 1),
          Episode(id: 'b', url: '', number: 2, seasonNumber: 1),
          Episode(id: 'c', url: '', number: 1, seasonNumber: 2),
        ],
      );
      final seasons = details.effectiveSeasons;
      expect(seasons.map((season) => season.number), <int>[1, 2]);
      expect(seasons.first.episodeCount, 2);
      expect(details.episodesOf(2).single.number, 1);
      expect(details.isEpisodic, isTrue);
    });
  });

  group('StreamResult', () {
    test('orders sources by quality, then by playability', () {
      const result = StreamResult(
        sources: <StreamSource>[
          StreamSource(url: 'https://a/360.m3u8', quality: '360p', isHls: true),
          StreamSource(
              url: 'https://a/1080.m3u8', quality: '1080p', isHls: true),
          StreamSource(url: 'https://a/720.mp4', quality: '720p'),
          StreamSource(
            url: 'https://a/proxy.mp4',
            quality: '720p',
            requiresProxy: true,
          ),
        ],
      );

      final ordered = result.orderedSources;
      expect(ordered.first.quality, '1080p');
      expect(ordered[1].quality, '720p');
      expect(ordered[1].requiresProxy, isFalse);
      expect(ordered[2].requiresProxy, isTrue);
      expect(ordered.last.quality, '360p');
    });

    test('a quality preference caps rather than filters', () {
      const result = StreamResult(
        sources: <StreamSource>[
          StreamSource(url: 'https://a/1080.mp4', quality: '1080p'),
          StreamSource(url: 'https://a/720.mp4', quality: '720p'),
          StreamSource(url: 'https://a/480.mp4', quality: '480p'),
        ],
      );

      final capped = result.preferredSources(preferredQuality: '720p');
      expect(capped.map((source) => source.quality), <String>['720p', '480p']);

      // Nothing at or below the cap: the full list comes back rather than an
      // empty screen.
      final none = result.preferredSources(preferredQuality: '240p');
      expect(none, hasLength(3));
    });

    test('HLS is preferred when the user asks for it', () {
      const result = StreamResult(
        sources: <StreamSource>[
          StreamSource(url: 'https://a/best.mp4', quality: '1080p'),
          StreamSource(url: 'https://a/ok.m3u8', quality: '720p', isHls: true),
        ],
      );

      expect(result.preferredSources().first.isHls, isTrue);
      expect(
        result.preferredSources(preferHls: false).first.quality,
        '1080p',
      );
    });

    test('no preference keeps the natural ranking', () {
      const result = StreamResult(
        sources: <StreamSource>[
          StreamSource(url: 'https://a/360.mp4', quality: '360p'),
          StreamSource(url: 'https://a/1080.mp4', quality: '1080p'),
        ],
      );

      expect(result.preferredSources(preferHls: false).first.quality, '1080p');
      expect(result.preferredSources().length, 2);
    });

    test('detects HLS and DASH from the URL when the plugin does not say', () {
      final hls = StreamSource.fromJson(<String, Object?>{
        'url': 'https://cdn/x/index.m3u8',
      });
      final dash = StreamSource.fromJson(<String, Object?>{
        'url': 'https://cdn/x/manifest.mpd',
      });
      expect(hls.isHls, isTrue);
      expect(dash.isDash, isTrue);
      expect(hls.label, 'Default');
    });
  });

  group('PluginInfo', () {
    test('round-trips capabilities, types and settings', () {
      final info = PluginInfo(
        id: 'dev.example.plugin',
        name: 'Example',
        ecosystem: PluginEcosystem.skystream,
        version: PluginVersion.parse(3),
        supportedTypes: <MediaType>{MediaType.movie, MediaType.series},
        capabilities: PluginCapabilities.all,
        settings: const <PluginSetting>[
          PluginSetting(
            key: 'baseUrl',
            title: 'Base URL',
            type: PluginSettingType.text,
          ),
        ],
      );

      final decoded = PluginInfo.fromJson(info.toJson());
      expect(decoded.id, info.id);
      expect(decoded.ecosystem, PluginEcosystem.skystream);
      expect(decoded.version, PluginVersion.parse(3));
      expect(decoded.supportedTypes, contains(MediaType.series));
      expect(decoded.capabilities.streams, isTrue);
      expect(decoded.settings.single.key, 'baseUrl');
      expect(decoded.isJavaScript, isTrue);
    });

    test('platform gating for CloudStream', () {
      const info = PluginInfo(
        id: 'cs',
        name: 'CS',
        ecosystem: PluginEcosystem.cloudstream,
      );
      expect(info.runsOnCurrentPlatform(false), isFalse);
      expect(info.runsOnCurrentPlatform(true), isTrue);
      expect(info.isJavaScript, isFalse);
    });
  });

  group('AvailablePlugin', () {
    const listing = AvailablePlugin(
      id: 'dev.example.plugin',
      name: 'Example',
      downloadUrl: 'https://example.com/plugin.sky',
      ecosystem: PluginEcosystem.skystream,
      repositoryId: 'repo',
      version: PluginVersion.none,
      status: 1,
    );

    test('is installable everywhere a JS runtime exists', () {
      expect(listing.isInstallable(isAndroid: true), isTrue);
      expect(listing.isInstallable(isAndroid: false), isTrue);
    });

    test('blocks CloudStream outside Android', () {
      const cs = AvailablePlugin(
        id: 'cs',
        name: 'CS',
        downloadUrl: 'https://example.com/a.cs3',
        ecosystem: PluginEcosystem.cloudstream,
        repositoryId: 'repo',
      );
      expect(cs.isInstallable(isAndroid: false), isFalse);
      expect(cs.isInstallable(isAndroid: true), isTrue);
    });

    test('blocks broken or unfetchable listings', () {
      expect(
        listing.copyWith(status: 0).isInstallable(isAndroid: true),
        isFalse,
      );
      expect(
        listing.copyWith(downloadUrl: '').isInstallable(isAndroid: true),
        isFalse,
      );
    });
  });
}
