import '../../core/json/json_read.dart';
import '../../core/utils/version.dart';
import 'enums.dart';

/// What a plugin can do. The UI hides controls it cannot honour.
final class PluginCapabilities {
  const PluginCapabilities({
    this.home = false,
    this.search = false,
    this.details = false,
    this.episodes = false,
    this.streams = false,
    this.subtitles = false,
    this.settings = false,
    this.catalogs = false,
    this.downloads = false,
    this.cast = false,
  });

  final bool home;
  final bool search;
  final bool details;
  final bool episodes;
  final bool streams;
  final bool subtitles;
  final bool settings;
  final bool catalogs;
  final bool downloads;
  final bool cast;

  static const PluginCapabilities all = PluginCapabilities(
    home: true,
    search: true,
    details: true,
    episodes: true,
    streams: true,
    subtitles: true,
    settings: true,
    catalogs: true,
    downloads: true,
    cast: true,
  );

  static const PluginCapabilities none = PluginCapabilities();

  PluginCapabilities copyWith({
    bool? home,
    bool? search,
    bool? details,
    bool? episodes,
    bool? streams,
    bool? subtitles,
    bool? settings,
    bool? catalogs,
    bool? downloads,
    bool? cast,
  }) =>
      PluginCapabilities(
        home: home ?? this.home,
        search: search ?? this.search,
        details: details ?? this.details,
        episodes: episodes ?? this.episodes,
        streams: streams ?? this.streams,
        subtitles: subtitles ?? this.subtitles,
        settings: settings ?? this.settings,
        catalogs: catalogs ?? this.catalogs,
        downloads: downloads ?? this.downloads,
        cast: cast ?? this.cast,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'home': home,
        'search': search,
        'details': details,
        'episodes': episodes,
        'streams': streams,
        'subtitles': subtitles,
        'settings': settings,
        'catalogs': catalogs,
        'downloads': downloads,
        'cast': cast,
      };

  factory PluginCapabilities.fromJson(Map<String, Object?> json) =>
      PluginCapabilities(
        home: readBool(json['home']),
        search: readBool(json['search']),
        details: readBool(json['details']),
        episodes: readBool(json['episodes']),
        streams: readBool(json['streams']),
        subtitles: readBool(json['subtitles']),
        settings: readBool(json['settings']),
        catalogs: readBool(json['catalogs']),
        downloads: readBool(json['downloads']),
        cast: readBool(json['cast']),
      );

  @override
  bool operator ==(Object other) =>
      other is PluginCapabilities &&
      other.home == home &&
      other.search == search &&
      other.details == details &&
      other.episodes == episodes &&
      other.streams == streams &&
      other.subtitles == subtitles &&
      other.settings == settings &&
      other.catalogs == catalogs &&
      other.downloads == downloads &&
      other.cast == cast;

  @override
  int get hashCode => Object.hash(
        home,
        search,
        details,
        episodes,
        streams,
        subtitles,
        settings,
        catalogs,
        downloads,
        cast,
      );
}

/// One installed plugin.
final class PluginInfo {
  const PluginInfo({
    required this.id,
    required this.name,
    required this.ecosystem,
    this.version = PluginVersion.none,
    this.description,
    this.authors = const <String>[],
    this.language,
    this.iconUrl,
    this.supportedTypes = const <MediaType>{},
    this.capabilities = PluginCapabilities.none,
    this.repositoryId,
    this.sourceUrl,
    this.installedAt,
    this.enabled = true,
    this.priority = 0,
    this.apiVersion,
    this.sizeBytes,
    this.requiresProxy = false,
    this.settings = const <PluginSetting>[],
  });

  /// The manifest's own identifier (`packageName`, provider value, …).
  final String id;

  final String name;
  final PluginEcosystem ecosystem;
  final PluginVersion version;
  final String? description;
  final List<String> authors;
  final String? language;
  final String? iconUrl;
  final Set<MediaType> supportedTypes;
  final PluginCapabilities capabilities;

  /// Which repository installed this, for update checks.
  final String? repositoryId;

  /// Where the artifact was downloaded from; re-used for updates.
  final String? sourceUrl;

  final DateTime? installedAt;
  final bool enabled;

  /// Lower runs first in aggregated queries.
  final int priority;

  /// CloudStream extensions declare an API version; JS plugins do not.
  final int? apiVersion;

  final int? sizeBytes;

  /// True when the plugin's links only work through AeroStream's proxy.
  final bool requiresProxy;

  /// Static settings the plugin declares; dynamic ones are asked at runtime.
  final List<PluginSetting> settings;

  bool get isJavaScript =>
      ecosystem == PluginEcosystem.skystream ||
      ecosystem == PluginEcosystem.vega;

  /// A plugin can only run where its runtime exists.
  bool runsOnCurrentPlatform(bool isAndroid) =>
      ecosystem == PluginEcosystem.cloudstream ? isAndroid : true;

  PluginInfo copyWith({
    String? id,
    String? name,
    PluginEcosystem? ecosystem,
    PluginVersion? version,
    String? description,
    List<String>? authors,
    String? language,
    String? iconUrl,
    Set<MediaType>? supportedTypes,
    PluginCapabilities? capabilities,
    String? repositoryId,
    String? sourceUrl,
    DateTime? installedAt,
    bool? enabled,
    int? priority,
    int? apiVersion,
    int? sizeBytes,
    bool? requiresProxy,
    List<PluginSetting>? settings,
  }) =>
      PluginInfo(
        id: id ?? this.id,
        name: name ?? this.name,
        ecosystem: ecosystem ?? this.ecosystem,
        version: version ?? this.version,
        description: description ?? this.description,
        authors: authors ?? this.authors,
        language: language ?? this.language,
        iconUrl: iconUrl ?? this.iconUrl,
        supportedTypes: supportedTypes ?? this.supportedTypes,
        capabilities: capabilities ?? this.capabilities,
        repositoryId: repositoryId ?? this.repositoryId,
        sourceUrl: sourceUrl ?? this.sourceUrl,
        installedAt: installedAt ?? this.installedAt,
        enabled: enabled ?? this.enabled,
        priority: priority ?? this.priority,
        apiVersion: apiVersion ?? this.apiVersion,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        requiresProxy: requiresProxy ?? this.requiresProxy,
        settings: settings ?? this.settings,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'ecosystem': ecosystem.wire,
        'version': version.raw,
        if (description != null) 'description': description,
        if (authors.isNotEmpty) 'authors': authors,
        if (language != null) 'language': language,
        if (iconUrl != null) 'iconUrl': iconUrl,
        'supportedTypes': supportedTypes.map((type) => type.wire).toList(
              growable: false,
            ),
        'capabilities': capabilities.toJson(),
        if (repositoryId != null) 'repositoryId': repositoryId,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
        if (installedAt != null) 'installedAt': installedAt!.toIso8601String(),
        'enabled': enabled,
        'priority': priority,
        if (apiVersion != null) 'apiVersion': apiVersion,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        if (requiresProxy) 'requiresProxy': true,
        'settings': settings.map((setting) => setting.toJson()).toList(
              growable: false,
            ),
      };

  factory PluginInfo.fromJson(Map<String, Object?> json) => PluginInfo(
        id: readString(json['id']) ?? '',
        name: readString(json['name']) ?? 'Unknown plugin',
        ecosystem: PluginEcosystem.fromWire(json['ecosystem']),
        version: PluginVersion.parse(json['version']),
        description: readString(json['description']),
        authors: readStringList(json['authors']),
        language: readString(json['language']),
        iconUrl: readString(json['iconUrl']),
        supportedTypes: readStringList(json['supportedTypes'])
            .map(MediaType.fromWire)
            .toSet(),
        capabilities:
            PluginCapabilities.fromJson(readMap(json['capabilities'])),
        repositoryId: readString(json['repositoryId']),
        sourceUrl: readString(json['sourceUrl']),
        installedAt: readDate(json['installedAt']),
        enabled: readBool(json['enabled'], fallback: true),
        priority: readInt(json['priority']) ?? 0,
        apiVersion: readInt(json['apiVersion']),
        sizeBytes: readInt(json['sizeBytes']),
        requiresProxy: readBool(json['requiresProxy']),
        settings: readMapList(json['settings'])
            .map(PluginSetting.fromJson)
            .toList(growable: false),
      );

  @override
  bool operator ==(Object other) =>
      other is PluginInfo &&
      other.id == id &&
      other.ecosystem == ecosystem &&
      other.version == version &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, ecosystem, version, enabled);

  @override
  String toString() => 'PluginInfo($id, $name, ${version.raw})';
}

/// A control a plugin declares, rendered by the settings screen.
final class PluginSetting {
  const PluginSetting({
    required this.key,
    required this.title,
    this.type = PluginSettingType.text,
    this.value,
    this.options = const <String>[],
    this.description,
  });

  final String key;
  final String title;
  final PluginSettingType type;
  final Object? value;
  final List<String> options;
  final String? description;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'title': title,
        'type': type.name,
        if (value != null) 'value': value,
        if (options.isNotEmpty) 'options': options,
        if (description != null) 'description': description,
      };

  factory PluginSetting.fromJson(Map<String, Object?> json) {
    final rawType = readString(json['type'])?.toLowerCase() ?? 'text';
    final type = PluginSettingType.values.firstWhere(
      (candidate) => candidate.name == rawType,
      orElse: () => PluginSettingType.text,
    );
    return PluginSetting(
      key: readString(json['key']) ?? readString(json['name']) ?? '',
      title: readString(json['title']) ?? readString(json['name']) ?? 'Setting',
      type: type,
      value: json['value'],
      options: readStringList(json['options']),
      description: readString(json['description']),
    );
  }
}

enum PluginSettingType {
  text,
  password,
  number,
  toggle,
  select,
  multiSelect,
  action,
}
