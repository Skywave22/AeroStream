import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';

import '../../domain/entities/stream_source.dart';
import 'playback_engine.dart';

/// libmpv through `media_kit`: HLS, DASH, progressive files and the codecs in
/// between, with the same code on every target.
final class MediaKitPlaybackEngine implements PlaybackEngine {
  MediaKitPlaybackEngine();

  @override
  bool supports(StreamSource source) {
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
  }) {
    if (!supports(source)) return null;
    return MediaKitSurface(
      key: ValueKey<String>(source.url),
      source: source,
      subtitles: subtitles,
      startAt: startAt,
      onProgress: onProgress,
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
    super.key,
  });

  final StreamSource source;
  final List<SubtitleTrack> subtitles;

  /// Where to resume from, when the user has been here before.
  final Duration? startAt;

  /// Called every few seconds, and once more when the surface goes away.
  final ProgressCallback? onProgress;

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
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  DateTime _lastReport = DateTime.fromMillisecondsSinceEpoch(0);
  Object? _error;

  @override
  void initState() {
    super.initState();
    _positionSubscription = _player.stream.position.listen((position) {
      _position = position;
      final now = DateTime.now();
      if (now.difference(_lastReport) >= _reportEvery) {
        _lastReport = now;
        _report();
      }
    });
    _durationSubscription = _player.stream.duration.listen((duration) {
      _duration = duration;
    });
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

  @override
  void dispose() {
    // One last report before the decoder goes away, so leaving mid-episode
    // still records where the user was.
    _report();
    unawaited(_positionSubscription?.cancel());
    unawaited(_durationSubscription?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return _PlaybackFailure(message: '$error');
    }
    return Video(controller: _controller);
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

/// The engine this build installs at boot.
MediaKitPlaybackEngine createPlaybackEngine() => MediaKitPlaybackEngine();
