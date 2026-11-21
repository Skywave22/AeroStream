import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/logging/app_log.dart';
import '../../domain/entities/stream_source.dart';
import 'playback_engine.dart';
import 'player_chrome.dart';

/// libmpv through `media_kit`: HLS, DASH, progressive files and the codecs in
/// between, with the same code on every target.
///
/// The second engine, behind libVLC. It is faster on a fresh open and has the
/// better DASH support, which is why the picker exists.
final class MediaKitPlaybackEngine implements PlaybackEngine {
  MediaKitPlaybackEngine();

  @override
  String get displayName => 'mpv';

  @override
  bool supports(StreamSource source) {
    if (source.isDrmProtected) return false;
    final url = source.url;
    // `file://` is how a finished download is played: same player, no network.
    return url.startsWith('https://') ||
        url.startsWith('http://') ||
        url.startsWith('file://');
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
    return MediaKitSurface(
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
  Future<void> dispose() async {
    // Each surface owns its player and releases it in `dispose`; nothing is
    // shared between them, so there is nothing left to clean up here.
  }
}

/// One player, one source.
///
/// A widget rather than a state object on the engine: the player's lifetime is
/// exactly the surface's lifetime, so switching sources tears the old decoder
/// down instead of leaving it running behind the new one.
class MediaKitSurface extends StatefulWidget {
  const MediaKitSurface({
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
  State<MediaKitSurface> createState() => _MediaKitSurfaceState();
}

class _MediaKitSurfaceState extends State<MediaKitSurface> {
  /// How often progress is reported; frequent enough for a useful resume
  /// point, rare enough not to write settings every frame.
  static const Duration _reportEvery = Duration(seconds: 5);

  late final mk.Player _player = mk.Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<Duration>? _bufferSubscription;
  StreamSubscription<mk.Tracks>? _tracksSubscription;
  StreamSubscription<mk.Track>? _trackSubscription;
  StreamSubscription<String>? _errorSubscription;
  Timer? _reportTimer;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffer = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  double _volume = 100;
  double _speed = 1;
  BoxFit _fit = BoxFit.contain;
  mk.Tracks _tracks = const mk.Tracks();
  mk.Track _track = const mk.Track();
  String? _externalSubtitleUrl;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _positionSubscription = _player.stream.position.listen((position) {
      _position = position;
      if (mounted) setState(() {});
    });
    _durationSubscription = _player.stream.duration.listen((duration) {
      _duration = duration;
      if (mounted) setState(() {});
    });
    _playingSubscription = _player.stream.playing.listen((playing) {
      _playing = playing;
      if (mounted) setState(() {});
    });
    _bufferingSubscription = _player.stream.buffering.listen((buffering) {
      _buffering = buffering;
      if (mounted) setState(() {});
    });
    _bufferSubscription = _player.stream.buffer.listen((buffer) {
      _buffer = buffer;
      if (mounted) setState(() {});
    });
    _tracksSubscription = _player.stream.tracks.listen((tracks) {
      _tracks = tracks;
      if (mounted) setState(() {});
    });
    _trackSubscription = _player.stream.track.listen((track) {
      _track = track;
      if (!track.subtitle.uri) _externalSubtitleUrl = null;
      if (mounted) setState(() {});
    });
    _errorSubscription = _player.stream.error.listen((error) {
      if (error.isEmpty) return;
      _error = error;
      if (mounted) setState(() {});
    });
    _reportTimer = Timer.periodic(_reportEvery, (_) => _report());
    unawaited(_open());
  }

  void _report() {
    final callback = widget.onProgress;
    if (callback == null) return;
    if (_position <= Duration.zero || _duration <= Duration.zero) return;
    callback(_position, _duration);
  }

  Future<void> _open() async {
    try {
      // Headers are part of the stream contract: plenty of sources reject a
      // request without the referer the plugin told us to send.
      await _player.open(
        mk.Media(widget.source.url, httpHeaders: widget.source.headers),
      );
      final resume = widget.startAt;
      if (resume != null && resume > Duration.zero) {
        await _player.seek(resume);
      }
      await _player.play();
      await _loadSubtitle();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _loadSubtitle() async {
    if (widget.subtitles.isEmpty) return;
    final preferred = widget.subtitles.firstWhere(
      (track) => track.isDefault,
      orElse: () => widget.subtitles.first,
    );
    _externalSubtitleUrl = preferred.url;
    try {
      await _player.setSubtitleTrack(
        mk.SubtitleTrack.uri(
          preferred.url,
          title: preferred.displayName,
          language: preferred.language,
        ),
      );
    } on Object {
      // A subtitle that will not load is not a reason to stop the film; the
      // track picker inside the player still lists whatever is embedded.
    }
  }

  Future<void> _togglePlay() async {
    try {
      if (_playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
    } on Object catch (error) {
      AppLog.debug('mpv command failed: $error');
    }
  }

  Future<void> _seek(Duration position) async {
    try {
      await _player.seek(position);
    } on Object catch (error) {
      AppLog.debug('Seek failed: $error');
    }
  }

  Future<void> _setVolume(double volume) async {
    setState(() => _volume = volume);
    try {
      await _player.setVolume(volume);
    } on Object catch (error) {
      AppLog.debug('Volume failed: $error');
    }
  }

  Future<void> _setSpeed(double speed) async {
    setState(() => _speed = speed);
    try {
      await _player.setRate(speed);
    } on Object catch (error) {
      AppLog.debug('Speed failed: $error');
    }
  }

  Future<void> _onSubtitleChanged(String? id) async {
    try {
      if (id == null) {
        _externalSubtitleUrl = null;
        await _player.setSubtitleTrack(mk.SubtitleTrack.no());
        if (mounted) setState(() {});
        return;
      }
      if (id.startsWith('mpv:')) {
        final nativeId = id.substring('mpv:'.length);
        for (final track in _tracks.subtitle) {
          if (track.id != nativeId) continue;
          _externalSubtitleUrl = null;
          await _player.setSubtitleTrack(track);
          if (mounted) setState(() {});
          return;
        }
        return;
      }
      final url = id.startsWith('file:') ? id.substring('file:'.length) : id;
      SubtitleTrack? pluginTrack;
      for (final track in widget.subtitles) {
        if (track.url == url) {
          pluginTrack = track;
          break;
        }
      }
      _externalSubtitleUrl = url;
      await _player.setSubtitleTrack(
        mk.SubtitleTrack.uri(
          url,
          title: pluginTrack?.displayName,
          language: pluginTrack?.language,
        ),
      );
      if (mounted) setState(() {});
    } on Object catch (error) {
      AppLog.warn('Could not set subtitles: $error');
    }
  }

  Future<void> _onAudioChanged(String id) async {
    if (!id.startsWith('mpv:')) return;
    final nativeId = id.substring('mpv:'.length);
    for (final track in _tracks.audio) {
      if (track.id != nativeId) continue;
      try {
        await _player.setAudioTrack(track);
      } on Object catch (error) {
        AppLog.warn('Could not set audio track: $error');
      }
      return;
    }
  }

  static bool _isRealTrack(String id) => id != 'auto' && id != 'no';

  static String _trackLabel(
    String id,
    String? title,
    String? language,
    String fallback,
  ) {
    if (title != null && title.trim().isNotEmpty) return title;
    if (language != null && language.trim().isNotEmpty) return language;
    return '$fallback $id';
  }

  List<PlayerTrack> get _subtitleItems => <PlayerTrack>[
        for (final track in widget.subtitles)
          PlayerTrack(id: 'file:${track.url}', label: track.displayName),
        for (final track in _tracks.subtitle)
          if (_isRealTrack(track.id) && !track.uri)
            PlayerTrack(
              id: 'mpv:${track.id}',
              label: _trackLabel(
                track.id,
                track.title,
                track.language,
                'Subtitle',
              ),
              language: track.language,
            ),
      ];

  List<PlayerTrack> get _audioItems => <PlayerTrack>[
        for (final track in _tracks.audio)
          if (_isRealTrack(track.id))
            PlayerTrack(
              id: 'mpv:${track.id}',
              label: _trackLabel(
                track.id,
                track.title,
                track.language,
                'Audio',
              ),
              language: track.language,
            ),
      ];

  String? get _currentSubtitleId {
    final external = _externalSubtitleUrl;
    if (external != null) return 'file:$external';
    final selected = _track.subtitle;
    if (!_isRealTrack(selected.id)) return null;
    return selected.uri ? 'file:${selected.id}' : 'mpv:${selected.id}';
  }

  String? get _currentAudioId {
    final selected = _track.audio;
    return _isRealTrack(selected.id) ? 'mpv:${selected.id}' : null;
  }

  void _cycleFit() {
    setState(() {
      _fit = switch (_fit) {
        BoxFit.contain => BoxFit.cover,
        BoxFit.cover => BoxFit.fill,
        _ => BoxFit.contain,
      };
    });
  }

  @override
  void dispose() {
    // One last report before the decoder goes away, so leaving mid-episode
    // still records where the user was.
    _report();
    _reportTimer?.cancel();
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_playingSubscription?.cancel());
    unawaited(_bufferingSubscription?.cancel());
    unawaited(_bufferSubscription?.cancel());
    unawaited(_tracksSubscription?.cancel());
    unawaited(_trackSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return _PlaybackFailure(message: '$error');
    }
    final fitLabel = switch (_fit) {
      BoxFit.contain => 'Contain',
      BoxFit.cover => 'Cover',
      BoxFit.fill => 'Fill',
      _ => 'Contain',
    };
    final bufferedFraction = _duration > Duration.zero
        ? _buffer.inMilliseconds / _duration.inMilliseconds
        : null;
    return PlayerChrome(
      engineLabel: 'mpv',
      playing: _playing,
      buffering: _buffering,
      position: _position,
      duration: _duration,
      bufferedFraction: bufferedFraction,
      volume: _volume,
      speed: _speed,
      subtitleTracks: _subtitleItems,
      currentSubtitleId: _currentSubtitleId,
      audioTracks: _audioItems,
      currentAudioId: _currentAudioId,
      onTogglePlay: () => unawaited(_togglePlay()),
      onSeek: (target) => unawaited(_seek(target)),
      onVolumeChanged: (volume) => unawaited(_setVolume(volume)),
      onSpeedChanged: (speed) => unawaited(_setSpeed(speed)),
      onSubtitleChanged: (id) => unawaited(_onSubtitleChanged(id)),
      onAudioChanged: (id) => unawaited(_onAudioChanged(id)),
      onFitChanged: _cycleFit,
      fitLabel: fitLabel,
      onFullscreenChanged: widget.onFullscreenChanged,
      fullscreen: widget.fullscreen,
      isLive: widget.source.isLive,
      child: Video(controller: _controller, fit: _fit),
    );
  }
}

class _PlaybackFailure extends StatelessWidget {
  const _PlaybackFailure({required this.message});

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
