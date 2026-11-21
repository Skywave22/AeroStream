import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../core/logging/app_log.dart';
import '../../domain/entities/stream_source.dart';
import 'media_header_proxy.dart';
import 'playback_engine.dart';
import 'player_chrome.dart';

/// libVLC: the default engine.
///
/// It forgives the most about broken manifests, handles RTSP/RTP and odd
/// containers mpv trips on, and is what SkyStream drives. libVLC 3 only sends
/// User-Agent and Referer itself; the surface transparently proxies HTTP media
/// when a plugin requires Cookie, Authorization, Origin, or a custom header.
final class VlcPlaybackEngine implements PlaybackEngine {
  VlcPlaybackEngine();

  @override
  String get displayName => 'libVLC';

  @override
  bool supports(StreamSource source) {
    if (source.isDrmProtected) return false;
    final url = source.url;
    return url.startsWith('https://') ||
        url.startsWith('http://') ||
        url.startsWith('file://') ||
        url.startsWith('rtsp://') ||
        url.startsWith('rtp://');
  }

  @override
  Widget? buildSurface(
    BuildContext context,
    StreamSource source, {
    List<SubtitleTrack> subtitles = const <SubtitleTrack>[],
    Duration? startAt,
    ProgressCallback? onProgress,
    bool fullscreen = false,
    ValueChanged<bool>? onFullscreenChanged,
  }) {
    if (!supports(source)) return null;
    return VlcSurface(
      key: ValueKey<String>(source.key),
      source: source,
      subtitles: subtitles,
      startAt: startAt,
      onProgress: onProgress,
      fullscreen: fullscreen,
      onFullscreenChanged: onFullscreenChanged,
    );
  }

  @override
  Future<void> dispose() async {}
}

/// One player, one source. Same lifetime rules as the mpv surface.
class VlcSurface extends StatefulWidget {
  const VlcSurface({
    required this.source,
    this.subtitles = const <SubtitleTrack>[],
    this.startAt,
    this.onProgress,
    this.fullscreen = false,
    this.onFullscreenChanged,
    super.key,
  });

  final StreamSource source;
  final List<SubtitleTrack> subtitles;

  /// Where to resume from, when the user has been here before.
  final Duration? startAt;

  /// Called every few seconds, and once more when the surface goes away.
  final ProgressCallback? onProgress;

  /// Lets the watch screen remove its app bar and source list in full screen.
  final bool fullscreen;
  final ValueChanged<bool>? onFullscreenChanged;

  @override
  State<VlcSurface> createState() => _VlcSurfaceState();
}

class _VlcSurfaceState extends State<VlcSurface> {
  static const Duration _reportEvery = Duration(seconds: 5);

  VlcPlayerController? _controller;
  MediaHeaderProxy? _proxy;
  Object? _setupError;
  Timer? _reportTimer;
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;

  /// The plugin subtitle the user picked, as opposed to an embedded track.
  String? _externalSubtitleUrl;

  /// Track lists, refetched when the engine says the set changed.
  List<VlcTrackDescription> _audioTracks = const <VlcTrackDescription>[];
  List<VlcTrackDescription> _subtitleTracks = const <VlcTrackDescription>[];
  int _trackRevision = -1;
  bool _tracksLoading = false;
  VlcVideoFit _fit = VlcVideoFit.contain;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final source = widget.source;
    final sourceUri = Uri.parse(source.url);
    final dropped = unsupportedVlcHeaders(source.headers);
    var mediaUri = sourceUri;
    var mediaHeaders = source.headers;
    MediaHeaderProxy? proxy;
    try {
      final canProxy =
          sourceUri.scheme == 'http' || sourceUri.scheme == 'https';
      if (canProxy && (dropped.isNotEmpty || source.requiresProxy)) {
        proxy = await MediaHeaderProxy.start(
          upstream: sourceUri,
          headers: source.headers,
        );
        mediaUri = proxy.playbackUri;
        // The loopback proxy, rather than libVLC, sends the source identity.
        mediaHeaders = const <String, String>{};
        AppLog.info(
          'Routing libVLC through the local media proxy for: '
          '${dropped.isEmpty ? 'playlist rewriting' : dropped.join(', ')}',
        );
      } else if (dropped.isNotEmpty) {
        AppLog.warn(
          'libVLC cannot send these headers for ${sourceUri.scheme}: '
          '${dropped.join(', ')}',
        );
      }

      if (!mounted) {
        await proxy?.close();
        return;
      }
      final controller = VlcPlayerController(
        mediaSource: VlcMediaSource(
          uri: mediaUri,
          httpHeaders: mediaHeaders,
          startPosition: widget.startAt ?? Duration.zero,
          isLive: source.isLive,
        ),
        autoPlay: true,
      );
      _proxy = proxy;
      _controller = controller;
      controller.addListener(_onValue);
      _reportTimer = Timer.periodic(_reportEvery, (_) => _report());
      setState(() {});
      // Track lists arrive after the media is known; the revision counter is
      // the signal that they exist.
      unawaited(_refreshTracks());
    } on Object catch (error) {
      await proxy?.close();
      if (!mounted) return;
      setState(() => _setupError = error);
    }
  }

  void _onValue() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    if (value.trackRevision != _trackRevision && !_tracksLoading) {
      unawaited(_refreshTracks());
    }
    if (value.hasError) {
      AppLog.warn('libVLC error: ${value.errorDescription ?? value.error}');
    }
  }

  Future<void> _refreshTracks() async {
    final controller = _controller;
    if (controller == null || _tracksLoading) return;
    _tracksLoading = true;
    try {
      final audio = await controller.getAudioTracks();
      final subtitles = await controller.getSubtitleTracks();
      if (!mounted || controller != _controller) return;
      setState(() {
        _audioTracks = audio;
        _subtitleTracks = subtitles;
        _trackRevision = controller.value.trackRevision;
      });
    } on Object catch (error) {
      // Track enumeration failing is not a reason to stop the film; the
      // pickers just stay empty.
      AppLog.debug('Could not list tracks: $error');
    } finally {
      _tracksLoading = false;
    }
  }

  void _report() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    _lastPosition = value.position;
    _lastDuration = value.duration;
    final callback = widget.onProgress;
    if (callback == null) return;
    if (_lastPosition <= Duration.zero || _lastDuration <= Duration.zero) {
      return;
    }
    callback(_lastPosition, _lastDuration);
  }

  List<PlayerTrack> get _subtitleItems {
    final items = <PlayerTrack>[
      for (final track in widget.subtitles)
        PlayerTrack(id: 'file:${track.url}', label: track.displayName),
      for (final track in _subtitleTracks)
        PlayerTrack(
          id: 'vlc:${track.id}',
          label: track.name.isNotEmpty
              ? track.name
              : (track.language ?? 'Subtitle ${track.id}'),
          language: track.language,
        ),
    ];
    return items;
  }

  String? get _currentSubtitleId {
    final controller = _controller;
    if (_externalSubtitleUrl != null) return 'file:$_externalSubtitleUrl';
    final active = controller?.value.activeSubtitleTrackId;
    return active == null ? null : 'vlc:$active';
  }

  Future<void> _onSubtitleChanged(String? id) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      if (id == null) {
        _externalSubtitleUrl = null;
        await controller.disableSubtitle();
        if (mounted) setState(() {});
        return;
      }
      if (id.startsWith('file:')) {
        final url = id.substring('file:'.length);
        _externalSubtitleUrl = url;
        await controller.addSubtitle(Uri.parse(url));
        if (mounted) setState(() {});
        return;
      }
      final nativeId = int.tryParse(id.substring('vlc:'.length));
      if (nativeId == null) return;
      _externalSubtitleUrl = null;
      await controller.setSubtitleTrack(nativeId);
      if (mounted) setState(() {});
    } on Object catch (error) {
      AppLog.warn('Could not set subtitles: $error');
    }
  }

  Future<void> _onAudioChanged(String id) async {
    final controller = _controller;
    if (controller == null) return;
    final nativeId = int.tryParse(id.substring('vlc:'.length));
    if (nativeId == null) return;
    try {
      await controller.setAudioTrack(nativeId);
    } on Object catch (error) {
      AppLog.warn('Could not set audio track: $error');
    }
  }

  Future<void> _cycleFit() async {
    setState(() {
      _fit = switch (_fit) {
        VlcVideoFit.contain => VlcVideoFit.cover,
        VlcVideoFit.cover => VlcVideoFit.fill,
        VlcVideoFit.fill => VlcVideoFit.contain,
        VlcVideoFit.none => VlcVideoFit.contain,
      };
    });
  }

  Future<void> _togglePlay() async {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    try {
      if (value.isPlaying) {
        await controller.pause();
      } else {
        await controller.play();
      }
    } on Object catch (error) {
      AppLog.warn('libVLC command failed: $error');
    }
  }

  Future<void> _seek(Duration position) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.seekTo(position);
    } on Object catch (error) {
      AppLog.debug('Seek failed: $error');
    }
  }

  Future<void> _setVolume(double volume) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      // libVLC goes to 200 (amplification); the slider stays on 0..100.
      await controller.setVolume(volume.round().clamp(0, 100));
    } on Object catch (error) {
      AppLog.debug('Volume failed: $error');
    }
  }

  Future<void> _setSpeed(double speed) async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.setPlaybackSpeed(speed);
    } on Object catch (error) {
      AppLog.debug('Speed failed: $error');
    }
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _report();
    final controller = _controller;
    controller?.removeListener(_onValue);
    controller?.dispose();
    unawaited(_proxy?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final setupError = _setupError;
    if (setupError != null) {
      return _VlcPlaybackFailure(message: '$setupError');
    }
    final controller = _controller;
    if (controller == null) return const _VlcPreparing();
    return ValueListenableBuilder<VlcPlayerValue>(
      valueListenable: controller,
      builder: (context, value, child) {
        if (value.hasError) {
          return _VlcPlaybackFailure(
            message: value.errorDescription ??
                value.error?.message ??
                'libVLC could not play this link.',
          );
        }
        final buffering = value.isBuffering ||
            value.isStalled ||
            value.state == VlcPlaybackState.opening;
        final fitLabel = switch (_fit) {
          VlcVideoFit.contain => 'Contain',
          VlcVideoFit.cover => 'Cover',
          VlcVideoFit.fill => 'Fill',
          VlcVideoFit.none => 'None',
        };
        return PlayerChrome(
          engineLabel: 'libVLC',
          playing: value.isPlaying,
          buffering: buffering,
          position: value.position,
          duration: value.duration,
          bufferedFraction: value.bufferingProgress,
          volume: value.volume.toDouble(),
          speed: value.playbackSpeed,
          subtitleTracks: _subtitleItems,
          currentSubtitleId: _currentSubtitleId,
          audioTracks: [
            for (final track in _audioTracks)
              PlayerTrack(
                id: 'vlc:${track.id}',
                label: track.name.isNotEmpty
                    ? track.name
                    : (track.language ?? 'Track ${track.id}'),
                language: track.language,
              ),
          ],
          currentAudioId: value.activeAudioTrackId == null
              ? null
              : 'vlc:${value.activeAudioTrackId}',
          onTogglePlay: () => unawaited(_togglePlay()),
          onSeek: (target) => unawaited(_seek(target)),
          onVolumeChanged: (volume) => unawaited(_setVolume(volume)),
          onSpeedChanged: (speed) => unawaited(_setSpeed(speed)),
          onSubtitleChanged: (id) => unawaited(_onSubtitleChanged(id)),
          onAudioChanged: (id) => unawaited(_onAudioChanged(id)),
          onFitChanged: () => unawaited(_cycleFit()),
          fitLabel: fitLabel,
          onFullscreenChanged: widget.onFullscreenChanged,
          fullscreen: widget.fullscreen,
          isLive: value.isLive,
          child: VlcPlayer(controller: controller, fit: _fit),
        );
      },
    );
  }
}

class _VlcPreparing extends StatelessWidget {
  const _VlcPreparing();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.white70),
            SizedBox(height: 12),
            Text(
              'Preparing libVLC…',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class _VlcPlaybackFailure extends StatelessWidget {
  const _VlcPlaybackFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white38, size: 40),
              const SizedBox(height: 12),
              const Text(
                'Playback failed',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
