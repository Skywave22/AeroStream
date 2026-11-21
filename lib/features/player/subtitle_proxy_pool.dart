import '../../domain/entities/stream_source.dart';
import 'media_header_proxy.dart';

/// Gives native players header-aware loopback URLs for external subtitles.
///
/// Neither libVLC's `addSubtitle` nor media_kit's subtitle-track API accepts
/// request headers. CloudStream subtitle files can require the same Cookie,
/// Referer or Authorization as their video, so each protected subtitle gets a
/// small [MediaHeaderProxy]. Proxies are reused while the player surface lives
/// and closed with it.
final class SubtitleProxyPool {
  final Map<String, Future<MediaHeaderProxy>> _proxies =
      <String, Future<MediaHeaderProxy>>{};

  Future<Uri> playbackUri(SubtitleTrack track) async {
    final upstream = Uri.parse(track.url);
    if (track.headers.isEmpty ||
        (upstream.scheme != 'http' && upstream.scheme != 'https')) {
      return upstream;
    }

    final key = '${track.url}\n${track.headers.entries.join('\n')}';
    final pending = _proxies.putIfAbsent(
      key,
      () => MediaHeaderProxy.start(
        upstream: upstream,
        headers: track.headers,
      ),
    );
    try {
      return (await pending).playbackUri;
    } catch (_) {
      _proxies.remove(key)?.ignore();
      rethrow;
    }
  }

  Future<void> close() async {
    final pending = _proxies.values.toList(growable: false);
    _proxies.clear();
    for (final proxy in pending) {
      try {
        await (await proxy).close();
      } catch (_) {
        // A proxy that did not start owns nothing; the player is already going.
      }
    }
  }
}
