import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/json/json_read.dart';
import '../../data/downloads/download_fetcher.dart';
import '../../domain/entities/download.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/entities/stream_source.dart';

/// Where downloads are written. Overridden at boot with the app support
/// directory; tests point it at a temporary directory.
final downloadDirectoryProvider = Provider<Directory>((ref) {
  throw StateError('downloadDirectoryProvider must be overridden');
});

final downloadFetcherProvider = Provider<DownloadFetcher>(
  (ref) => DioDownloadFetcher(),
);

/// The download queue, newest first.
final downloadsProvider =
    NotifierProvider<DownloadsController, List<DownloadTask>>(
  DownloadsController.new,
);

/// A download that cannot be started, with a reason worth showing.
final class DownloadRejected implements Exception {
  const DownloadRejected(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Saves streams to disk, one at a time.
///
/// One at a time on purpose: two simultaneous downloads on a phone fight over
/// bandwidth and both look stalled. The queue is the list order.
class DownloadsController extends Notifier<List<DownloadTask>> {
  static const String storageKey = 'downloads.tasks';

  final Map<String, DownloadTicket> _tickets = <String, DownloadTicket>{};
  final Map<String, DateTime> _lastProgressAt = <String, DateTime>{};

  /// Downloads run one after another: each start waits for the previous one to
  /// finish, so a queue of ten does not try to use ten connections at once.
  Future<void> _chain = Future<void>.value();

  /// Progress is reported every few hundred kilobytes; the state is only
  /// rebuilt when a humans-noticeable amount of it changed.
  static const Duration _progressInterval = Duration(milliseconds: 400);

  bool _disposed = false;

  @override
  List<DownloadTask> build() {
    ref.onDispose(() => _disposed = true);
    final loaded = _load();
    // Nothing is actually running when the app starts: a task that was running
    // when the process died is a paused task.
    return loaded
        .map(
          (task) => task.status == DownloadStatus.running
              ? task.copyWith(status: DownloadStatus.paused, receivedBytes: 0)
              : task,
        )
        .toList(growable: false);
  }

  List<DownloadTask> _load() {
    final raw = ref.read(settingsStoreProvider).getString(storageKey);
    if (raw == null || raw.isEmpty) return const <DownloadTask>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <DownloadTask>[];
      return decoded
          .whereType<Map<Object?, Object?>>()
          .map((entry) => DownloadTask.fromJson(readMap(entry)))
          .toList(growable: false);
    } on FormatException {
      return const <DownloadTask>[];
    }
  }

  /// Path of [task] on disk, whether or not the file exists.
  String pathFor(DownloadTask task) =>
      '${ref.read(downloadDirectoryProvider).path}/${task.fileName}';

  /// The file [task] points at, ready to hand to a player.
  StreamSource playableSource(DownloadTask task) => StreamSource(
        url: 'file://${pathFor(task)}',
        quality: task.episode?.label ?? 'Downloaded',
        isHls: false,
        isDash: false,
      );

  DownloadTask? taskFor(MediaItem item, {Episode? episode}) {
    final id = _idFor(item, episode);
    for (final task in state) {
      if (task.id == id) return task;
    }
    return null;
  }

  static String _idFor(MediaItem item, Episode? episode) =>
      '${item.id}#${episode?.id ?? ''}';

  /// Queues [source] for [item] and returns the task.
  ///
  /// Throws [DownloadRejected] when the link is not a file this build can save,
  /// or when something for the same title is already queued.
  Future<DownloadTask> enqueue({
    required MediaItem item,
    required StreamSource source,
    Episode? episode,
    bool start = true,
  }) async {
    if (!isDownloadableLink(
      source.url,
      isHls: source.isHls,
      isDash: source.isDash,
    )) {
      throw const DownloadRejected(
        'This link is a stream playlist, not a file. AeroStream saves '
        'progressive HTTP links; for playlists use the player instead.',
      );
    }
    final existing = taskFor(item, episode: episode);
    if (existing != null && existing.isActive) {
      throw const DownloadRejected('This is already downloading.');
    }

    final task = DownloadTask(
      id: _idFor(item, episode),
      item: item,
      episode: episode,
      url: source.url,
      headers: source.headers,
      fileName: downloadFileName(
        title: episode == null ? item.title : '${item.title} ${episode.label}',
        extension: extensionForUrl(source.url),
      ),
      createdAt: DateTime.now(),
    );

    state = List<DownloadTask>.unmodifiable(<DownloadTask>[
      task,
      ...state.where((existing) => existing.id != task.id),
    ]);
    await _persist();
    if (start) unawaited(startDownload(task.id));
    return task;
  }

  /// Starts, or restarts, a task. Restarting discards whatever was on disk.
  ///
  /// Returns when this task's turn in the queue comes up and it has finished,
  /// which is what lets callers (and tests) await a whole download.
  Future<void> startDownload(String id) {
    if (_tickets.containsKey(id)) return Future<void>.value();
    final task = _byId(id);
    if (task == null || task.status == DownloadStatus.running) {
      return Future<void>.value();
    }

    final turn = Completer<void>();
    final previous = _chain;
    _chain = turn.future;
    return previous.then((_) async {
      try {
        await _download(id);
      } finally {
        if (!turn.isCompleted) turn.complete();
      }
    });
  }

  Future<void> _download(String id) async {
    final task = _byId(id);
    if (task == null) return;

    final ticket = DownloadTicket();
    _tickets[id] = ticket;
    _replace(
      task.copyWith(
        status: DownloadStatus.running,
        receivedBytes: 0,
        clearError: true,
      ),
    );

    final destination = pathFor(task);
    try {
      final bytes = await ref.read(downloadFetcherProvider).download(
            url: Uri.parse(task.url),
            headers: task.headers,
            destination: destination,
            ticket: ticket,
            onProgress: (received, total) =>
                _reportProgress(id, received, total),
          );
      final finished = _byId(id);
      if (finished == null) return;
      _replace(
        finished.copyWith(
          status: DownloadStatus.complete,
          receivedBytes: bytes,
          totalBytes: bytes,
          clearError: true,
        ),
      );
    } on DownloadCancelled {
      await _deleteFile(destination);
      if (_disposed) return;
      final cancelled = _byId(id);
      if (cancelled != null) {
        _replace(
          cancelled.copyWith(
            status: DownloadStatus.paused,
            receivedBytes: 0,
            clearError: true,
          ),
        );
      }
    } catch (error) {
      await _deleteFile(destination);
      if (_disposed) return;
      final failed = _byId(id);
      if (failed != null) {
        _replace(
          failed.copyWith(
            status: DownloadStatus.failed,
            receivedBytes: 0,
            error: _describe(error),
          ),
        );
      }
    } finally {
      _tickets.remove(id);
      _lastProgressAt.remove(id);
      await _persist();
    }
  }

  /// Stops a running download and keeps the task, ready to restart.
  Future<void> cancel(String id) async {
    _tickets[id]?.cancel();
    _tickets.remove(id);
    final task = _byId(id);
    if (task == null || !task.isActive) return;
    await _deleteFile(pathFor(task));
    _replace(task.copyWith(status: DownloadStatus.paused, receivedBytes: 0));
    await _persist();
  }

  /// Forgets a task and deletes its file.
  Future<void> remove(String id) async {
    final task = _byId(id);
    if (task == null) return;
    _tickets[id]?.cancel();
    _tickets.remove(id);
    await _deleteFile(pathFor(task));
    state =
        state.where((existing) => existing.id != id).toList(growable: false);
    await _persist();
  }

  Future<void> removeFinished() async {
    for (final task in state.where((task) => task.isPlayable)) {
      await _deleteFile(pathFor(task));
    }
    state = state.where((task) => !task.isPlayable).toList(growable: false);
    await _persist();
  }

  /// Bytes on disk for a finished task, or null when the file went away.
  Future<int?> fileSize(DownloadTask task) async {
    final file = File(pathFor(task));
    try {
      if (!await file.exists()) return null;
      return await file.length();
    } on FileSystemException {
      return null;
    }
  }

  void _reportProgress(String id, int received, int? total) {
    if (_disposed) return;
    final now = DateTime.now();
    final last = _lastProgressAt[id];
    final task = _byId(id);
    if (task == null) return;
    final isComplete = total != null && total > 0 && received >= total;
    if (!isComplete &&
        last != null &&
        now.difference(last) < _progressInterval) {
      return;
    }
    _lastProgressAt[id] = now;
    _replace(
      task.copyWith(
          receivedBytes: received, totalBytes: total ?? task.totalBytes),
    );
  }

  String _describe(Object error) {
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status != null) return 'The server answered $status.';
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return 'The server stopped responding.';
      }
      return 'The download failed (${error.type.name}).';
    }
    if (error is FileSystemException) {
      return 'The file could not be written: ${error.message}.';
    }
    return '$error';
  }

  Future<void> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing to do: the task is gone either way.
    }
  }

  DownloadTask? _byId(String id) {
    for (final task in state) {
      if (task.id == id) return task;
    }
    return null;
  }

  void _replace(DownloadTask task) {
    // A transfer can outlive the screen that started it — and the container,
    // when the app is shutting down. Nothing left to notify, nothing to write.
    if (_disposed) return;
    state = List<DownloadTask>.unmodifiable(
      state.map((existing) => existing.id == task.id ? task : existing),
    );
  }

  Future<void> _persist() async {
    final payload = jsonEncode(
      state.map((task) => task.toJson()).toList(growable: false),
    );
    try {
      await ref.read(settingsStoreProvider).setString(storageKey, payload);
    } on StateError {
      // The container is gone; the queue in memory was already correct.
    }
  }
}

/// Only finished downloads that are still on disk.
final playableDownloadsProvider = Provider<List<DownloadTask>>((ref) {
  return ref.watch(downloadsProvider).where((task) => task.isPlayable).toList();
});
