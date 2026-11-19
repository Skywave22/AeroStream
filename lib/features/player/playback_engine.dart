import 'package:flutter/material.dart';

import '../../domain/entities/stream_source.dart';

/// Renders a stream surface.
///
/// The engine is a seam on purpose: platforms that can host a video pipeline
/// `playerEngineProvider` with a real implementation, while builds
/// that cannot (or tests) leave it null and the watch screen explains itself
/// instead of rendering a black rectangle.
abstract interface class PlaybackEngine {
  /// Whether this engine can render [source] itself.
  bool supports(StreamSource source);

  /// The video surface for [source], or null when the engine cannot play it
  /// and the UI should offer an external player instead.
  Widget? buildSurface(BuildContext context, StreamSource source);

  /// Releases decoder resources when the user leaves the player.
  Future<void> dispose();
}
