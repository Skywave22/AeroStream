import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../errors/plugin_error.dart';
import '../result.dart';
import 'network_policy.dart';
import 'redirect_location.dart';

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
  /// [followRedirects] — set false to get the raw 3xx response (with its
  /// `Location` header) instead of the final one. Providers that resolve
  /// redirects themselves need exactly that; the default keeps the historical
  /// behaviour of landing on the last `2xx`.
  Future<Result<HttpPayload>> get(
    Uri url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  });

  Future<Result<HttpPayload>> post(
    Uri url, {
    Object? body,
    Map<String, String>? headers,
    bool followRedirects = true,
  });

  /// HEAD. Some CDNs that 403 a plain GET still answer HEAD, and providers
  /// read existence off the status code alone.
  Future<Result<HttpPayload>> head(
    Uri url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  });

  /// Where [url] redirects to, without downloading the body.
  ///
  /// Only the first hop is followed and only http(s) targets are returned:
  /// shortcodes (`cutt.ly/<code>`, `py.md/<code>`) exist so a person can paste
  /// four characters instead of a URL, and resolving one must not become a
  /// general-purpose redirect follower for plugin code.
  Future<Result<Uri>> resolveRedirect(Uri url);
}

/// Dio-backed implementation with the safety rails switched on.
final class DioHttpService implements HttpService {
  DioHttpService({Dio? dio, this.limits = const HttpLimits()})
      : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = limits.timeout
      ..sendTimeout = limits.timeout
      ..receiveTimeout = limits.timeout
      // Redirects are followed by hand in [_send], with every hop checked
      // against the scheme and private-host rules. Dio's built-in following
      // gives that control away, and it happens before any check can run.
      ..followRedirects = false
      ..maxRedirects = 0
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
    bool followRedirects = true,
  }) =>
      _send(
        url,
        method: 'GET',
        headers: headers,
        followRedirects: followRedirects,
      );

  @override
  Future<Result<HttpPayload>> head(
    Uri url, {
    Map<String, String>? headers,
    bool followRedirects = true,
  }) =>
      _send(
        url,
        method: 'HEAD',
        headers: headers,
        followRedirects: followRedirects,
      );

  @override
  Future<Result<HttpPayload>> post(
    Uri url, {
    Object? body,
    Map<String, String>? headers,
    bool followRedirects = true,
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
        followRedirects: followRedirects,
      );

  /// The User-Agent shorteners are asked with.
  ///
  /// `cutt.ly` answers a bare `Dart/3.x (dart:io)` like a bot — with a 403, or
  /// with a captcha page instead of the redirect — and the shortcode then looks
  /// like it does not exist. The browsers every other client imitates get the
  /// plain redirect.
  static const String shortLinkUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  @override
  Future<Result<Uri>> resolveRedirect(Uri url) async {
    if (url.scheme != 'http' && url.scheme != 'https') {
      return Err<Uri>(
        PluginSandboxError(
          'Refusing to resolve a ${url.scheme} URL',
          violation: 'network-scheme',
        ),
      );
    }
    try {
      final response = await _dio.get<List<int>>(
        url.toString(),
        options: Options(
          followRedirects: false,
          // Below 500: a 404 means "no such code" and a 429 means "slow down",
          // and both are worth reporting by name rather than as a transport
          // error.
          validateStatus: (int? status) => status != null && status < 500,
          responseType: ResponseType.bytes,
          headers: const <String, Object?>{'User-Agent': shortLinkUserAgent},
        ),
      );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        final target = parseRedirectLocation(
          response.headers.value('location'),
          url,
        );
        if (target == null) {
          return Err<Uri>(
            PluginNetworkError(
              '${url.host} did not redirect anywhere useful',
              url: url.toString(),
            ),
          );
        }
        if (NetworkPolicy.isPrivateHost(target.host)) {
          return Err<Uri>(
            PluginSandboxError(
              'The short link points at a private address',
              violation: 'network-private-host',
            ),
          );
        }
        return Ok<Uri>(target);
      }
      if (isDeadShortLink(status)) {
        return Err<Uri>(
          PluginNetworkError(
            '${url.host} has no link at that address',
            statusCode: status,
            url: url.toString(),
          ),
        );
      }
      if (status >= 400) {
        return Err<Uri>(
          PluginNetworkError(
            status == 429
                ? '${url.host} is limiting shortcode lookups; try again in a '
                    'minute'
                : '${url.host} answered $status',
            statusCode: status,
            url: url.toString(),
          ),
        );
      }
      // A 200 page: the destination is in a meta refresh or a script.
      final body =
          utf8.decode(response.data ?? const <int>[], allowMalformed: true);
      final page = parseRedirectPage(body, url);
      if (page != null && !NetworkPolicy.isPrivateHost(page.host)) {
        return Ok<Uri>(page);
      }
      return Err<Uri>(
        PluginNetworkError(
          '${url.host} did not point anywhere',
          url: url.toString(),
        ),
      );
    } on DioException catch (error) {
      return Err<Uri>(
        PluginNetworkError(
          'Could not resolve that link: ${error.type.name}',
          statusCode: error.response?.statusCode,
          url: url.toString(),
          cause: error,
        ),
      );
    }
  }

  Future<Result<HttpPayload>> _send(
    Uri url, {
    required String method,
    Object? body,
    Map<String, String>? headers,
    bool followRedirects = true,
  }) async {
    if (url.scheme != 'http' && url.scheme != 'https') {
      return Err<HttpPayload>(
        PluginSandboxError(
          'Refusing to fetch a ${url.scheme.isEmpty ? 'relative' : url.scheme} URL',
          violation: 'network-scheme',
        ),
      );
    }

    var current = url;
    var currentMethod = method;
    var currentBody = body;
    var currentHeaders = headers;
    var hops = 0;
    try {
      while (true) {
        final response = await _dio.request<List<int>>(
          current.toString(),
          data: currentBody,
          options: Options(method: currentMethod, headers: currentHeaders),
        );

        final status = response.statusCode ?? 0;
        if (followRedirects && _isRedirect(status)) {
          final target = _validatedRedirectTarget(
            response.headers.value('location'),
            current,
          );
          if (target == null) {
            return Err<HttpPayload>(
              PluginNetworkError(
                '${current.host} redirects to a target that is not allowed',
                url: current.toString(),
              ),
            );
          }
          hops += 1;
          if (hops > limits.maxRedirects) {
            return Err<HttpPayload>(
              PluginNetworkError(
                'Too many redirects fetching ${url.host}',
                url: url.toString(),
              ),
            );
          }
          // 303 always, and 301/302 after a POST, become plain GETs.
          if (status == 303 ||
              ((status == 301 || status == 302) && currentMethod == 'POST')) {
            currentMethod = 'GET';
            currentBody = null;
          }
          // Credentials do not cross to another origin.
          if (currentHeaders != null && target.host != current.host) {
            currentHeaders = Map<String, String>.of(currentHeaders)
              ..removeWhere(
                (key, _) => const <String>{
                  'authorization',
                  'proxy-authorization',
                  'cookie',
                }.contains(key.toLowerCase()),
              );
          }
          current = target;
          continue;
        }

        final raw = response.data ?? const <int>[];
        final truncated = raw.length > limits.maxBytes;
        final bytes = truncated
            ? Uint8List.fromList(raw.sublist(0, limits.maxBytes))
            : Uint8List.fromList(raw);

        final payload = HttpPayload(
          bytes: bytes,
          statusCode: status,
          url: current.toString(),
          headers: response.headers.map.map(
            (key, value) => MapEntry(key, value.join(', ')),
          ),
          truncated: truncated,
        );

        // When the caller wants the raw redirect (followRedirects: false),
        // a 3xx is a first-class answer, not a failure.
        final ok = followRedirects ? payload.isSuccess : status < 400;
        if (!ok) {
          return Err<HttpPayload>(
            PluginNetworkError(
              'HTTP $status for ${url.host}',
              statusCode: status,
              url: url.toString(),
            ),
          );
        }
        return Ok<HttpPayload>(payload);
      }
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

  static bool _isRedirect(int status) =>
      status == 301 ||
      status == 302 ||
      status == 303 ||
      status == 307 ||
      status == 308;

  /// Where a redirect may point: a well-formed http(s) URL whose host is not
  /// loopback, private or link-local. Anything else ends the chain here,
  /// before a single byte moves.
  static Uri? _validatedRedirectTarget(String? location, Uri base) {
    if (location == null || location.trim().isEmpty) return null;
    final parsed = Uri.tryParse(location.trim());
    if (parsed == null) return null;
    final resolved = parsed.hasScheme ? parsed : base.resolveUri(parsed);
    if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
    if (NetworkPolicy.isPrivateHost(resolved.host)) return null;
    return resolved;
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
