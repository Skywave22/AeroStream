import 'package:flutter/material.dart';

import '../../domain/entities/stream_source.dart';

/// Renders a stream surface.
///
/// This interface keeps the watch screen independent of either native player.
/// Both engines use the same chrome and reject DRM before creating a decoder.
abstract interface class PlaybackEngine {
  /// Whether this engine can render [source] itself.
  bool supports(StreamSource source);

  /// Short human name shown in the player chrome (`libVLC`, `mpv`).
  String get displayName;

  /// The video surface for [source], or null when the engine cannot play it
  /// and the UI should explain why rather than show a black rectangle.
  Widget? buildSurface(
    BuildContext context,
    StreamSource source, {
    List<SubtitleTrack> subtitles = const <SubtitleTrack>[],
    Duration? startAt,
    ProgressCallback? onProgress,
    bool fullscreen = false,
    ValueChanged<bool>? onFullscreenChanged,
  });

  /// Releases resources held outside individual player surfaces.
  Future<void> dispose();
}

/// Reports playback progress, throttled by the surface: `(position, duration)`.
typedef ProgressCallback = void Function(Duration position, Duration duration);
