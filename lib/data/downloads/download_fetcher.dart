import 'dart:io';

import 'package:dio/dio.dart';

import '../../core/network/network_policy.dart';

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
///
/// Redirects are followed by hand and every hop is checked against the
/// private-host rules — `dio.download` would follow them silently, which is
/// how a CDN link turns into a LAN probe halfway through a download.
final class DioDownloadFetcher implements DownloadFetcher {
  DioDownloadFetcher({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(minutes: 10),
                followRedirects: false,
                maxRedirects: 0,
                validateStatus: (int? _) => true,
                responseType: ResponseType.stream,
              ),
            );

  final Dio _dio;

  static const int _maxHops = 5;

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// Where a redirect may point: http(s) only, never a private/loopback/
  /// link-local host.
  static Uri? _target(String? location, Uri base) {
    if (location == null || location.trim().isEmpty) return null;
    final parsed = Uri.tryParse(location.trim());
    if (parsed == null) return null;
    final resolved = parsed.hasScheme ? parsed : base.resolveUri(parsed);
    if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
    if (NetworkPolicy.isPrivateHost(resolved.host)) return null;
    return resolved;
  }

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

    // Walk the redirect chain manually: each 3xx body is empty, so a hop is
    // one cheap request and the connection that carries the bytes only ever
    // touches a policy-checked URL.
    var current = url;
    if (current.scheme != 'http' && current.scheme != 'https') {
      throw ArgumentError.value(
        url,
        'url',
        'Only http(s) downloads are allowed',
      );
    }
    if (NetworkPolicy.isPrivateHost(current.host)) {
      throw ArgumentError.value(
        url,
        'url',
        'Refusing to download from a private host',
      );
    }

    for (var hop = 0;; hop++) {
      try {
        final response = await _dio.download(
          current.toString(),
          destination,
          cancelToken: cancelToken,
          deleteOnError: true,
          options: Options(
            followRedirects: false,
            maxRedirects: 0,
            validateStatus: (int? _) => true,
            headers: headers.isEmpty ? null : headers,
          ),
          onReceiveProgress: (received, total) => onProgress(
            received,
            total <= 0 ? null : total,
          ),
        );
        final status = response.statusCode ?? 0;
        if (_isRedirect(status)) {
          if (hop >= _maxHops - 1) {
            await _deleteQuietly(file);
            throw StateError('Too many redirects downloading $url');
          }
          final next = _target(response.headers.value('location'), current);
          if (next == null) {
            await _deleteQuietly(file);
            throw StateError(
              '${current.host} redirected to an unusable target',
            );
          }
          await _deleteQuietly(file); // never keep a 3xx page as the payload
          current = next;
          continue;
        }
        if (status < 200 || status >= 300) {
          await _deleteQuietly(file);
          throw StateError('HTTP $status downloading ${current.host}');
        }
        break;
      } on DioException catch (error) {
        if (CancelToken.isCancel(error)) {
          await _deleteQuietly(file);
          throw const DownloadCancelled();
        }
        rethrow;
      }
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
