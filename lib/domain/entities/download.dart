import '../../core/json/json_read.dart';
import 'enums.dart';
import 'episode.dart';
import 'media_item.dart';

/// Where a download is in its life.
enum DownloadStatus {
  /// Waiting for the queue.
  queued,

  /// Bytes are moving.
  running,

  /// Stopped by the user, or interrupted by the app closing. Restartable.
  paused,

  /// Everything is on disk.
  complete,

  /// The server or the filesystem said no.
  failed,
}

/// One saved stream: a title (or an episode of one) and the file behind it.
///
/// The item is snapshotted rather than referenced, for the same reason history
/// is: a download outlives the plugin that produced it.
final class DownloadTask {
  const DownloadTask({
    required this.id,
    required this.item,
    required this.url,
    required this.fileName,
    required this.createdAt,
    this.episode,
    this.headers = const <String, String>{},
    this.status = DownloadStatus.queued,
    this.receivedBytes = 0,
    this.totalBytes,
    this.error,
  });

  /// Stable per item *and* episode: one download per thing watched.
  final String id;

  final MediaItem item;
  final Episode? episode;

  /// The remote link, kept so an interrupted download can be restarted.
  final String url;
  final Map<String, String> headers;

  /// File name inside the downloads directory. Sanitised at creation.
  final String fileName;

  final DateTime createdAt;
  final DownloadStatus status;
  final int receivedBytes;

  /// Null until the server tells us — and some servers never do.
  final int? totalBytes;
  final String? error;

  /// 0..1, or null when the size is unknown.
  double? get progress {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }

  bool get isActive =>
      status == DownloadStatus.queued || status == DownloadStatus.running;

  /// Whether the user can watch the file that is already on disk.
  bool get isPlayable => status == DownloadStatus.complete;

  String get title =>
      episode == null ? item.title : '${item.title} · ${episode!.label}';

  DownloadTask copyWith({
    DownloadStatus? status,
    int? receivedBytes,
    int? totalBytes,
    String? error,
    bool clearError = false,
  }) =>
      DownloadTask(
        id: id,
        item: item,
        episode: episode,
        url: url,
        headers: headers,
        fileName: fileName,
        createdAt: createdAt,
        status: status ?? this.status,
        receivedBytes: receivedBytes ?? this.receivedBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        error: clearError ? null : (error ?? this.error),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'item': item.toJson(),
        'url': url,
        'fileName': fileName,
        'createdAt': createdAt.toIso8601String(),
        'status': status.name,
        'receivedBytes': receivedBytes,
        if (episode != null) 'episode': episode!.toJson(),
        if (headers.isNotEmpty) 'headers': headers,
        if (totalBytes != null) 'totalBytes': totalBytes,
        if (error != null) 'error': error,
      };

  factory DownloadTask.fromJson(Map<String, Object?> json) {
    final episodeJson = json['episode'];
    final statusName = readString(json['status']);
    return DownloadTask(
      id: readString(json['id']) ?? '',
      item: MediaItem.fromJson(readMap(json['item'])),
      episode:
          episodeJson is Map ? Episode.fromJson(readMap(episodeJson)) : null,
      url: readString(json['url']) ?? '',
      headers: readStringMap(json['headers']),
      fileName: readString(json['fileName']) ?? 'download.bin',
      createdAt:
          readDate(json['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      status: DownloadStatus.values.firstWhere(
        (value) => value.name == statusName,
        orElse: () => DownloadStatus.paused,
      ),
      receivedBytes: readInt(json['receivedBytes']) ?? 0,
      totalBytes: readInt(json['totalBytes']),
      error: readString(json['error']),
    );
  }
}

/// A title worth offering in the queue: progressive HTTP(S) only.
///
/// HLS and DASH are segment lists, not files. Saving them means fetching every
/// segment and remuxing, which this build does not do — saying so up front is
/// better than a download that silently produces a broken file.
bool isDownloadableLink(String url, {bool isHls = false, bool isDash = false}) {
  if (isHls || isDash) return false;
  final lower = url.toLowerCase();
  if (lower.contains('.m3u8') || lower.contains('.mpd')) return false;
  return lower.startsWith('http://') || lower.startsWith('https://');
}

/// File extension to save [url] under, best effort.
String extensionForUrl(String url) {
  final path = Uri.tryParse(url)?.path ?? '';
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return 'bin';
  final ext = path.substring(dot + 1).toLowerCase();
  if (ext.length > 5 || !RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return 'bin';
  return ext;
}

/// A file name that is safe on every platform and still recognisable.
String downloadFileName({
  required String title,
  required String extension,
  MediaType type = MediaType.other,
}) {
  final slug = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final base = slug.isEmpty ? 'download' : slug;
  return '${base.substring(0, base.length > 80 ? 80 : base.length)}.$extension';
}
