import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/stream_source.dart';

/// Renders a stream surface.
///
/// The engine is a seam on purpose: builds that cannot host a video pipeline
/// (tests, a platform without native libraries) leave the provider null and the
/// watch screen explains itself instead of rendering a black rectangle.
abstract interface class PlaybackEngine {
  /// Whether this engine can render [source] itself.
  bool supports(StreamSource source);

  /// The video surface for [source], or null when the engine cannot play it
  /// and the UI should offer an external player instead.
  Widget? buildSurface(
    BuildContext context,
    StreamSource source, {
    List<SubtitleTrack> subtitles = const <SubtitleTrack>[],
  });

  /// Releases decoder resources when the user leaves the player.
  Future<void> dispose();
}

/// The playback engine for this build, or null when there is none.
///
/// Overridden at boot with [createPlaybackEngine]; left null in tests and in
/// builds without a video pipeline.
final playerEngineProvider = Provider<PlaybackEngine?>((ref) => null);
