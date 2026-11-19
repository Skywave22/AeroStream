import '../../core/json/json_read.dart';
import 'enums.dart';
import 'media_item.dart';

/// A home-screen row produced by one plugin.
final class HomeSection {
  const HomeSection({
    required this.title,
    required this.items,
    this.layout = HomeSectionLayout.posterRow,
    this.pluginId,
    this.catalogId,
    this.canPaginate = false,
  });

  final String title;
  final List<MediaItem> items;
  final HomeSectionLayout layout;

  /// Which plugin produced the row. Filled in by the aggregator so a card can
  /// be routed back to the plugin that owns it.
  final String? pluginId;

  /// For catalog-style ecosystems (Vega), the id to page through.
  final String? catalogId;

  /// Whether the plugin can serve further pages of this row.
  final bool canPaginate;

  bool get isEmpty => items.isEmpty;

  HomeSection copyWith({
    String? title,
    List<MediaItem>? items,
    HomeSectionLayout? layout,
    String? pluginId,
    String? catalogId,
    bool? canPaginate,
  }) =>
      HomeSection(
        title: title ?? this.title,
        items: items ?? this.items,
        layout: layout ?? this.layout,
        pluginId: pluginId ?? this.pluginId,
        catalogId: catalogId ?? this.catalogId,
        canPaginate: canPaginate ?? this.canPaginate,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        'layout': layout.name,
        'items': items.map((item) => item.toJson()).toList(growable: false),
        if (pluginId != null) 'pluginId': pluginId,
        if (catalogId != null) 'catalogId': catalogId,
        if (canPaginate) 'canPaginate': true,
      };

  factory HomeSection.fromJson(Map<String, Object?> json) => HomeSection(
        title: readString(json['title']) ?? 'Untitled',
        layout: HomeSectionLayout.fromWire(json['layout']),
        items: readMapList(json['items']).map(MediaItem.fromJson).toList(
              growable: false,
            ),
        pluginId: readString(json['pluginId']),
        catalogId: readString(json['catalogId']),
        canPaginate: readBool(json['canPaginate']),
      );

  @override
  bool operator ==(Object other) =>
      other is HomeSection &&
      other.title == title &&
      other.layout == layout &&
      other.pluginId == pluginId &&
      other.catalogId == catalogId;

  @override
  int get hashCode => Object.hash(title, layout, pluginId, catalogId);

  @override
  String toString() => 'HomeSection($title, ${items.length} items)';
}

/// One page of search results from one plugin.
final class SearchPage {
  const SearchPage({
    this.items = const <MediaItem>[],
    this.nextPage,
    this.hasMore = false,
    this.pluginId,
  });

  final List<MediaItem> items;

  /// Token (or page number) to request next, when the plugin paginates.
  final Object? nextPage;

  /// Whether another page exists.
  final bool hasMore;

  final String? pluginId;

  bool get isEmpty => items.isEmpty;

  SearchPage copyWith({
    List<MediaItem>? items,
    Object? nextPage,
    bool? hasMore,
    String? pluginId,
  }) =>
      SearchPage(
        items: items ?? this.items,
        nextPage: nextPage ?? this.nextPage,
        hasMore: hasMore ?? this.hasMore,
        pluginId: pluginId ?? this.pluginId,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'items': items.map((item) => item.toJson()).toList(growable: false),
        if (nextPage != null) 'nextPage': nextPage,
        'hasMore': hasMore,
        if (pluginId != null) 'pluginId': pluginId,
      };

  factory SearchPage.fromJson(Map<String, Object?> json) => SearchPage(
        items: readMapList(json['items']).map(MediaItem.fromJson).toList(
              growable: false,
            ),
        nextPage: json['nextPage'],
        hasMore: readBool(json['hasMore']),
        pluginId: readString(json['pluginId']),
      );

  static const SearchPage empty = SearchPage();

  @override
  String toString() => 'SearchPage(${items.length} items, hasMore: $hasMore)';
}
