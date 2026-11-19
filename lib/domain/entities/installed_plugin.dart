import 'plugin_info.dart';

/// An installed plugin: its manifest record plus where the artifact lives.
final class InstalledPlugin {
  const InstalledPlugin({
    required this.info,
    required this.artifactPath,
    this.previousArtifactPath,
  });

  final PluginInfo info;

  /// Absolute path to the installed artifact (a `.sky` zip, a Vega bundle
  /// directory, or a `.cs3` file).
  final String artifactPath;

  /// The artifact this version replaced, kept for one-step rollback.
  final String? previousArtifactPath;

  String get id => info.id;

  /// Composite identity used by the store: `<ecosystem>:<id>`.
  String get key => '${info.ecosystem.name}:${info.id}';

  InstalledPlugin copyWith({
    PluginInfo? info,
    String? artifactPath,
    String? previousArtifactPath,
  }) =>
      InstalledPlugin(
        info: info ?? this.info,
        artifactPath: artifactPath ?? this.artifactPath,
        previousArtifactPath: previousArtifactPath ?? this.previousArtifactPath,
      );

  @override
  bool operator ==(Object other) =>
      other is InstalledPlugin &&
      other.info == info &&
      other.artifactPath == artifactPath;

  @override
  int get hashCode => Object.hash(info, artifactPath);

  @override
  String toString() => 'InstalledPlugin(${info.id} @ ${info.version.raw})';
}
