import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../core/logging/app_log.dart';
import '../../domain/entities/stream_source.dart';
import 'playback_engine.dart';
import 'player_chrome.dart';

/// libVLC: the default engine.
///
/// It forgives the most about broken manifests, handles RTSP/RTP and odd
/// containers mpv trips on, and is what SkyStream drives — but it can only
/// send `User-Agent` and `Referer` per source. Sources requiring other headers
/// must be routed through AeroStream's header-injecting proxy before playback.
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

  late final VlcPlayerController _controller = _createController();
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

  VlcPlayerController _createController() {
    final source = widget.source;
    // libVLC only transmits User-Agent and Referer; everything else the
    // plugin asked for is silently dropped by the engine, so say so once
    // instead of letting a CDN answer 403 with no clue why.
    final dropped = unsupportedVlcHeaders(source.headers);
    if (dropped.isNotEmpty) {
      AppLog.info(
        'libVLC cannot send these headers; opening without them: '
        '${dropped.join(', ')}',
      );
    }
    return VlcPlayerController(
      mediaSource: VlcMediaSource(
        uri: Uri.parse(source.url),
        httpHeaders: source.headers,
        startPosition: widget.startAt ?? Duration.zero,
        isLive: source.isLive,
      ),
      autoPlay: true,
    );
  }

  @override
  void initState() {
    super.initState();
    _reportTimer = Timer.periodic(_reportEvery, (_) => _report());
    _controller.addListener(_onValue);
    // Track lists arrive after the media is known; the revision counter is
    // the signal that they exist.
    unawaited(_refreshTracks());
  }

  void _onValue() {
    final value = _controller.value;
    if (value.trackRevision != _trackRevision && !_tracksLoading) {
      unawaited(_refreshTracks());
    }
    if (value.hasError) {
      AppLog.warn('libVLC error: ${value.errorDescription ?? value.error}');
    }
  }

  Future<void> _refreshTracks() async {
    if (_tracksLoading) return;
    _tracksLoading = true;
    try {
      final audio = await _controller.getAudioTracks();
      final subtitles = await _controller.getSubtitleTracks();
      if (!mounted) return;
      setState(() {
        _audioTracks = audio;
        _subtitleTracks = subtitles;
        _trackRevision = _controller.value.trackRevision;
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
    final value = _controller.value;
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
    if (_externalSubtitleUrl != null) return 'file:$_externalSubtitleUrl';
    final active = _controller.value.activeSubtitleTrackId;
    return active == null ? null : 'vlc:$active';
  }

  Future<void> _onSubtitleChanged(String? id) async {
    try {
      if (id == null) {
        _externalSubtitleUrl = null;
        await _controller.disableSubtitle();
        if (mounted) setState(() {});
        return;
      }
      if (id.startsWith('file:')) {
        final url = id.substring('file:'.length);
        _externalSubtitleUrl = url;
        await _controller.addSubtitle(Uri.parse(url));
        if (mounted) setState(() {});
        return;
      }
      final nativeId = int.tryParse(id.substring('vlc:'.length));
      if (nativeId == null) return;
      _externalSubtitleUrl = null;
      await _controller.setSubtitleTrack(nativeId);
      if (mounted) setState(() {});
    } on Object catch (error) {
      AppLog.warn('Could not set subtitles: $error');
    }
  }

  Future<void> _onAudioChanged(String id) async {
    final nativeId = int.tryParse(id.substring('vlc:'.length));
    if (nativeId == null) return;
    try {
      await _controller.setAudioTrack(nativeId);
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
    final value = _controller.value;
    try {
      if (value.isPlaying) {
        await _controller.pause();
      } else {
        await _controller.play();
      }
    } on Object catch (error) {
      AppLog.warn('libVLC command failed: $error');
    }
  }

  Future<void> _seek(Duration position) async {
    try {
      await _controller.seekTo(position);
    } on Object catch (error) {
      AppLog.debug('Seek failed: $error');
    }
  }

  Future<void> _setVolume(double volume) async {
    try {
      // libVLC goes to 200 (amplification); the slider stays on 0..100.
      await _controller.setVolume(volume.round().clamp(0, 100));
    } on Object catch (error) {
      AppLog.debug('Volume failed: $error');
    }
  }

  Future<void> _setSpeed(double speed) async {
    try {
      await _controller.setPlaybackSpeed(speed);
    } on Object catch (error) {
      AppLog.debug('Speed failed: $error');
    }
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _report();
    _controller.removeListener(_onValue);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VlcPlayerValue>(
      valueListenable: _controller,
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
          child: VlcPlayer(controller: _controller, fit: _fit),
        );
      },
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
