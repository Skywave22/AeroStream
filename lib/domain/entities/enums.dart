/// Enumerations shared by the whole domain.
library;

/// The three plugin runtimes AeroStream can host.
enum PluginEcosystem {
  skystream('skystream', 'SkyStream', 'JavaScript'),
  vega('vega', 'Vega', 'JavaScript'),
  cloudstream('cloudstream', 'CloudStream', 'Kotlin/DEX');

  const PluginEcosystem(this.wire, this.label, this.runtimeLabel);

  /// The identifier used in storage, URLs and manifests.
  final String wire;

  /// Human label for badges and filters.
  final String label;

  /// What the plugin actually executes as, shown in the UI.
  final String runtimeLabel;

  static PluginEcosystem? tryParse(Object? value) {
    if (value == null) return null;
    final normalized = value.toString().trim().toLowerCase();
    for (final ecosystem in PluginEcosystem.values) {
      if (ecosystem.wire == normalized || ecosystem.name == normalized) {
        return ecosystem;
      }
    }
    return null;
  }

  static PluginEcosystem fromWire(Object? value) =>
      tryParse(value) ?? PluginEcosystem.skystream;
}

/// What a catalogue entry *is*.
enum MediaType {
  movie('movie', 'Movie'),
  series('series', 'Series'),
  anime('anime', 'Anime'),
  live('livestream', 'Live'),
  other('other', 'Other');

  const MediaType(this.wire, this.label);

  final String wire;
  final String label;

  static MediaType fromWire(Object? value) {
    if (value == null) return MediaType.other;
    final normalized = value.toString().trim().toLowerCase();
    for (final type in MediaType.values) {
      if (type.wire == normalized || type.name == normalized) return type;
    }
    // Ecosystem-specific spellings.
    switch (normalized) {
      case 'tv':
      case 'tvseries':
      case 'tv_series':
      case 'show':
      case 'drama':
        return MediaType.series;
      case 'film':
      case 'movies':
        return MediaType.movie;
      case 'cartoon':
      case 'animation':
      case 'donghua':
        return MediaType.anime;
      case 'live':
      case 'livestream':
      case 'live_stream':
        return MediaType.live;
    }
    return MediaType.other;
  }

  /// Whether this type is expected to have seasons and episodes.
  bool get isEpisodic =>
      this == MediaType.series || this == MediaType.anime || this == MediaType.live;
}

/// How a home row should be laid out.
enum HomeSectionLayout {
  /// Wide, auto-advancing hero cards (SkyStream's `Trending`).
  carousel,
  posterRow,
  backdropRow,
  grid,
  compact;

  static HomeSectionLayout fromWire(Object? value) {
    if (value == null) return HomeSectionLayout.posterRow;
    final normalized = value.toString().trim().toLowerCase();
    for (final layout in HomeSectionLayout.values) {
      if (layout.name.toLowerCase() == normalized) return layout;
    }
    return switch (normalized) {
      'hero' || 'featured' => HomeSectionLayout.carousel,
      'list' || 'row' || 'horizontal' => HomeSectionLayout.posterRow,
      'banner' => HomeSectionLayout.backdropRow,
      'tiles' => HomeSectionLayout.grid,
      _ => HomeSectionLayout.posterRow,
    };
  }
}

/// Advisory playback policy a plugin can attach to an item.
enum PlaybackPolicy {
  none,
  vpnRecommended,
  torrent,
  externalPlayerOnly,
  internalPlayerOnly;

  static PlaybackPolicy fromWire(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'vpn recommended' || 'vpn_recommended' => PlaybackPolicy.vpnRecommended,
      'torrent' => PlaybackPolicy.torrent,
      'externalplayeronly' || 'external_player_only' =>
        PlaybackPolicy.externalPlayerOnly,
      'internalplayeronly' || 'internal_player_only' =>
        PlaybackPolicy.internalPlayerOnly,
      _ => PlaybackPolicy.none,
    };
  }
}
