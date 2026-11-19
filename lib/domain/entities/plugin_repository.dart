import '../../core/json/json_read.dart';
import '../../core/utils/version.dart';
import 'enums.dart';

/// A repository the user added, and where its plugin lists live.
///
/// All three ecosystems ship the *same* outer manifest shape, verified against
/// live repositories:
///
/// ```json
/// { "name": "…", "description": "…", "iconUrl": "…",
///   "manifestVersion": 1, "pluginLists": ["https://…/plugins.json"] }
/// ```
///
/// They differ only in what a plugin-list entry points at: a `.sky` zip
/// (SkyStream), a provider bundle (Vega) or a `.cs3` (CloudStream).
final class PluginRepository {
  const PluginRepository({
    required this.id,
    required this.name,
    required this.url,
    required this.ecosystem,
    this.description,
    this.iconUrl,
    this.pluginLists = const <String>[],
    this.includedRepos = const <String>[],
    this.manifestVersion = 1,
    this.addedAt,
    this.lastCheckedAt,
    this.enabled = true,
    this.isBuiltIn = false,
  });

  /// Stable id: the manifest's `packageName` when present, otherwise a hash of
  /// [url]. Never the display name, which changes.
  final String id;

  final String name;

  /// The URL the user entered (or that a short code resolved to).
  final String url;

  /// The ecosystem the manifest turned out to be. A repository is
  /// single-ecosystem: the shape of its plugin list decides.
  final PluginEcosystem ecosystem;

  final String? description;
  final String? iconUrl;

  /// Absolute URLs of the plugin lists.
  final List<String> pluginLists;

  /// Other repository manifests this one points at (CloudStream mega-repos).
  final List<String> includedRepos;

  final int manifestVersion;
  final DateTime? addedAt;
  final DateTime? lastCheckedAt;
  final bool enabled;

  /// Bundled with the app rather than added by the user.
  final bool isBuiltIn;

  PluginRepository copyWith({
    String? id,
    String? name,
    String? url,
    PluginEcosystem? ecosystem,
    String? description,
    String? iconUrl,
    List<String>? pluginLists,
    List<String>? includedRepos,
    int? manifestVersion,
    DateTime? addedAt,
    DateTime? lastCheckedAt,
    bool? enabled,
    bool? isBuiltIn,
  }) =>
      PluginRepository(
        id: id ?? this.id,
        name: name ?? this.name,
        url: url ?? this.url,
        ecosystem: ecosystem ?? this.ecosystem,
        description: description ?? this.description,
        iconUrl: iconUrl ?? this.iconUrl,
        pluginLists: pluginLists ?? this.pluginLists,
        includedRepos: includedRepos ?? this.includedRepos,
        manifestVersion: manifestVersion ?? this.manifestVersion,
        addedAt: addedAt ?? this.addedAt,
        lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
        enabled: enabled ?? this.enabled,
        isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'url': url,
        'ecosystem': ecosystem.wire,
        if (description != null) 'description': description,
        if (iconUrl != null) 'iconUrl': iconUrl,
        'pluginLists': pluginLists,
        if (includedRepos.isNotEmpty) 'includedRepos': includedRepos,
        'manifestVersion': manifestVersion,
        if (addedAt != null) 'addedAt': addedAt!.toIso8601String(),
        if (lastCheckedAt != null)
          'lastCheckedAt': lastCheckedAt!.toIso8601String(),
        'enabled': enabled,
        if (isBuiltIn) 'isBuiltIn': true,
      };

  factory PluginRepository.fromJson(Map<String, Object?> json) =>
      PluginRepository(
        id: readString(json['id']) ?? '',
        name: readString(json['name']) ?? 'Repository',
        url: readString(json['url']) ?? '',
        ecosystem: PluginEcosystem.fromWire(json['ecosystem']),
        description: readString(json['description']),
        iconUrl: readString(json['iconUrl']),
        pluginLists: readStringList(json['pluginLists']),
        includedRepos: readStringList(json['includedRepos']),
        manifestVersion: readInt(json['manifestVersion']) ?? 1,
        addedAt: readDate(json['addedAt']),
        lastCheckedAt: readDate(json['lastCheckedAt']),
        enabled: readBool(json['enabled'], fallback: true),
        isBuiltIn: readBool(json['isBuiltIn']),
      );

  @override
  bool operator ==(Object other) =>
      other is PluginRepository &&
      other.id == id &&
      other.url == url &&
      other.ecosystem == ecosystem;

  @override
  int get hashCode => Object.hash(id, url, ecosystem);

  @override
  String toString() => 'PluginRepository($id, $name, ${ecosystem.wire})';
}

/// A plugin that a repository offers but the user has not installed (or has
/// installed at an older version).
final class AvailablePlugin {
  const AvailablePlugin({
    required this.id,
    required this.name,
    required this.downloadUrl,
    required this.ecosystem,
    required this.repositoryId,
    this.version = PluginVersion.none,
    this.description,
    this.authors = const <String>[],
    this.language,
    this.iconUrl,
    this.supportedTypes = const <MediaType>{},
    this.fileSize,
    this.fileHash,
    this.apiVersion,
    this.status = 1,
    this.settings = const <String>[],
  });

  /// The plugin's own identifier within its ecosystem.
  final String id;

  final String name;
  final PluginVersion version;
  final String? description;
  final List<String> authors;
  final String? language;
  final String? iconUrl;
  final Set<MediaType> supportedTypes;
  final String downloadUrl;
  final PluginEcosystem ecosystem;
  final String repositoryId;
  final int? fileSize;

  /// `sha256-<hex>` when the repository publishes one.
  final String? fileHash;

  final int? apiVersion;

  /// CloudStream uses 1 for working, other values for disabled/broken.
  final int status;

  /// Setting keys a plugin declares in its manifest.
  final List<String> settings;

  bool get isWorking => status == 1;

  AvailablePlugin copyWith({
    String? id,
    String? name,
    PluginVersion? version,
    String? description,
    List<String>? authors,
    String? language,
    String? iconUrl,
    Set<MediaType>? supportedTypes,
    String? downloadUrl,
    PluginEcosystem? ecosystem,
    String? repositoryId,
    int? fileSize,
    String? fileHash,
    int? apiVersion,
    int? status,
    List<String>? settings,
  }) =>
      AvailablePlugin(
        id: id ?? this.id,
        name: name ?? this.name,
        version: version ?? this.version,
        description: description ?? this.description,
        authors: authors ?? this.authors,
        language: language ?? this.language,
        iconUrl: iconUrl ?? this.iconUrl,
        supportedTypes: supportedTypes ?? this.supportedTypes,
        downloadUrl: downloadUrl ?? this.downloadUrl,
        ecosystem: ecosystem ?? this.ecosystem,
        repositoryId: repositoryId ?? this.repositoryId,
        fileSize: fileSize ?? this.fileSize,
        fileHash: fileHash ?? this.fileHash,
        apiVersion: apiVersion ?? this.apiVersion,
        status: status ?? this.status,
        settings: settings ?? this.settings,
      );

  /// A plugin must be runnable where the app is running, working, and have a
  /// URL before the install button may be enabled.
  bool isInstallable({required bool isAndroid}) {
    if (!isWorking) return false;
    if (downloadUrl.isEmpty) return false;
    if (ecosystem == PluginEcosystem.cloudstream && !isAndroid) return false;
    return true;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'version': version.raw,
        if (description != null) 'description': description,
        if (authors.isNotEmpty) 'authors': authors,
        if (language != null) 'language': language,
        if (iconUrl != null) 'iconUrl': iconUrl,
        'supportedTypes': supportedTypes.map((type) => type.wire).toList(
              growable: false,
            ),
        'downloadUrl': downloadUrl,
        'ecosystem': ecosystem.wire,
        'repositoryId': repositoryId,
        if (fileSize != null) 'fileSize': fileSize,
        if (fileHash != null) 'fileHash': fileHash,
        if (apiVersion != null) 'apiVersion': apiVersion,
        'status': status,
        if (settings.isNotEmpty) 'settings': settings,
      };

  factory AvailablePlugin.fromJson(Map<String, Object?> json) =>
      AvailablePlugin(
        id: readString(json['id']) ?? '',
        name: readString(json['name']) ?? 'Unknown plugin',
        version: PluginVersion.parse(json['version']),
        description: readString(json['description']),
        authors: readStringList(json['authors']),
        language: readString(json['language']),
        iconUrl: readString(json['iconUrl']),
        supportedTypes: readStringList(json['supportedTypes'])
            .map(MediaType.fromWire)
            .toSet(),
        downloadUrl: readString(json['downloadUrl']) ?? '',
        ecosystem: PluginEcosystem.fromWire(json['ecosystem']),
        repositoryId: readString(json['repositoryId']) ?? '',
        fileSize: readInt(json['fileSize']),
        fileHash: readString(json['fileHash']),
        apiVersion: readInt(json['apiVersion']),
        status: readInt(json['status']) ?? 1,
        settings: readStringList(json['settings']),
      );

  @override
  bool operator ==(Object other) =>
      other is AvailablePlugin &&
      other.id == id &&
      other.ecosystem == ecosystem &&
      other.version == version &&
      other.downloadUrl == downloadUrl;

  @override
  int get hashCode => Object.hash(id, ecosystem, version, downloadUrl);

  @override
  String toString() =>
      'AvailablePlugin($id, $name, ${version.raw}, ${ecosystem.wire})';
}
