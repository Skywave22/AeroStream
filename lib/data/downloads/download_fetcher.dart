import 'dart:io';

import 'package:dio/dio.dart';

/// Thrown by a [DownloadFetcher] when the user cancelled.
final class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => 'Download cancelled';
}

/// How a caller stops a download that is already in flight.
///
/// A small class rather than a `Stream` or a `Future` because the fetcher only
/// needs to answer "should I still be writing?" — and because a ticket is easy
/// to fake in a test.
final class DownloadTicket {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners) {
      listener();
    }
    _listeners.clear();
  }

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }
}

/// Moves bytes from a URL to a file.
///
/// A seam because the only honest way to test a downloader is to not use the
/// network: the queue, the status transitions and the cleanup are the parts
/// that break.
abstract interface class DownloadFetcher {
  /// Writes [url] to [destination] and returns the number of bytes written.
  ///
  /// [onProgress] receives bytes so far and the total when the server sent a
  /// `Content-Length`. Throws [DownloadCancelled] when [ticket] is cancelled.
  Future<int> download({
    required Uri url,
    required Map<String, String> headers,
    required String destination,
    required DownloadTicket ticket,
    required void Function(int received, int? total) onProgress,
  });
}

/// Dio-backed fetcher: follows redirects, streams straight to disk.
final class DioDownloadFetcher implements DownloadFetcher {
  DioDownloadFetcher({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(minutes: 10),
                followRedirects: true,
                maxRedirects: 5,
                responseType: ResponseType.stream,
              ),
            );

  final Dio _dio;

  @override
  Future<int> download({
    required Uri url,
    required Map<String, String> headers,
    required String destination,
    required DownloadTicket ticket,
    required void Function(int received, int? total) onProgress,
  }) async {
    final cancelToken = CancelToken();
    ticket.onCancel(cancelToken.cancel);
    final file = File(destination);
    await file.parent.create(recursive: true);

    try {
      await _dio.download(
        url.toString(),
        destination,
        cancelToken: cancelToken,
        options: headers.isEmpty ? null : Options(headers: headers),
        onReceiveProgress: (received, total) => onProgress(
          received,
          total <= 0 ? null : total,
        ),
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        await _deleteQuietly(file);
        throw const DownloadCancelled();
      }
      rethrow;
    }

    // The bytes on disk are the only trustworthy count: not every server sends
    // a length, and a truncated response is a failed download, not a short one.
    return file.length();
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A leftover partial file is cleaned by the next attempt.
    }
  }
}
