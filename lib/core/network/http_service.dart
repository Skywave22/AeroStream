import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../errors/plugin_error.dart';
import '../result.dart';

/// Limits applied to every download AeroStream performs.
final class HttpLimits {
  const HttpLimits({
    this.maxBytes = 8 * 1024 * 1024,
    this.timeout = const Duration(seconds: 25),
    this.maxRedirects = 5,
  });

  /// Hard cap on a response body. Repositories and artifacts are small; a
  /// 200 MB response is either a mistake or an attack.
  final int maxBytes;

  final Duration timeout;
  final int maxRedirects;
}

/// A completed HTTP response, body included.
final class HttpPayload {
  const HttpPayload({
    required this.bytes,
    required this.statusCode,
    this.url,
    this.headers = const <String, String>{},
    this.truncated = false,
  });

  final Uint8List bytes;
  final int statusCode;
  final String? url;
  final Map<String, String> headers;

  /// True when the body was cut at [HttpLimits.maxBytes].
  final bool truncated;

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  String get text => utf8.decode(bytes, allowMalformed: true);

  String? header(String name) {
    final wanted = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == wanted) return entry.value;
    }
    return null;
  }
}

/// The only way AeroStream talks to the network for plugin work.
///
/// Plugin code never gets a socket: it asks the host, the host applies the
/// policy (scheme, size, redirects, timeout) and logs the request.
abstract interface class HttpService {
  Future<Result<HttpPayload>> get(
    Uri url, {
    Map<String, String>? headers,
  });

  Future<Result<HttpPayload>> post(
    Uri url, {
    Object? body,
    Map<String, String>? headers,
  });
}

/// Dio-backed implementation with the safety rails switched on.
final class DioHttpService implements HttpService {
  DioHttpService({Dio? dio, this.limits = const HttpLimits()})
      : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = limits.timeout
      ..sendTimeout = limits.timeout
      ..receiveTimeout = limits.timeout
      ..followRedirects = true
      ..maxRedirects = limits.maxRedirects
      ..validateStatus = ((int? _) => true)
      ..responseType = ResponseType.bytes
      ..headers = <String, Object?>{'Accept': '*/*'};
  }

  final Dio _dio;
  final HttpLimits limits;

  @override
  Future<Result<HttpPayload>> get(
    Uri url, {
    Map<String, String>? headers,
  }) =>
      _send(url, method: 'GET', headers: headers);

  @override
  Future<Result<HttpPayload>> post(
    Uri url, {
    Object? body,
    Map<String, String>? headers,
  }) =>
      _send(
        url,
        method: 'POST',
        body: body,
        headers: headers == null
            ? null
            : <String, String>{
                ...headers,
                if (!headers.keys
                    .map((key) => key.toLowerCase())
                    .contains('content-type'))
                  'Content-Type': 'application/x-www-form-urlencoded'
              },
      );

  Future<Result<HttpPayload>> _send(
    Uri url, {
    required String method,
    Object? body,
    Map<String, String>? headers,
  }) async {
    if (url.scheme != 'http' && url.scheme != 'https') {
      return Err<HttpPayload>(
        PluginSandboxError(
          'Refusing to fetch a ${url.scheme.isEmpty ? 'relative' : url.scheme} URL',
          violation: 'network-scheme',
        ),
      );
    }

    try {
      final response = await _dio.request<List<int>>(
        url.toString(),
        data: body,
        options: Options(method: method, headers: headers),
      );

      final status = response.statusCode ?? 0;
      final raw = response.data ?? const <int>[];
      final truncated = raw.length > limits.maxBytes;
      final bytes = truncated
          ? Uint8List.fromList(raw.sublist(0, limits.maxBytes))
          : Uint8List.fromList(raw);

      final payload = HttpPayload(
        bytes: bytes,
        statusCode: status,
        url: response.realUri.toString(),
        headers: response.headers.map.map(
          (key, value) => MapEntry(key, value.join(', ')),
        ),
        truncated: truncated,
      );

      if (!payload.isSuccess) {
        return Err<HttpPayload>(
          PluginNetworkError(
            'HTTP $status for ${url.host}',
            statusCode: status,
            url: url.toString(),
          ),
        );
      }
      return Ok<HttpPayload>(payload);
    } on DioException catch (error) {
      return Err<HttpPayload>(_mapDioException(error, url));
    } on Object catch (error, stack) {
      return Err<HttpPayload>(
        PluginNetworkError(
          'Request failed: $error',
          url: url.toString(),
          cause: error,
          stackTrace: stack,
        ),
      );
    }
  }

  static PluginError _mapDioException(DioException error, Uri url) {
    final type = error.type;
    if (type == DioExceptionType.connectionTimeout ||
        type == DioExceptionType.receiveTimeout ||
        type == DioExceptionType.sendTimeout) {
      return PluginTimeoutError(
        'Timed out fetching ${url.host}',
        cause: error,
        timeout: error.requestOptions.receiveTimeout,
      );
    }
    if (type == DioExceptionType.badCertificate) {
      return PluginNetworkError(
        'TLS certificate rejected for ${url.host}',
        url: url.toString(),
        cause: error,
      );
    }
    return PluginNetworkError(
      error.message ?? 'Network error for ${url.host}',
      url: url.toString(),
      statusCode: error.response?.statusCode,
      cause: error,
    );
  }
}
