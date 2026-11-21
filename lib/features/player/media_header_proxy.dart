import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/logging/app_log.dart';

/// A loopback-only reverse proxy for native players that cannot send arbitrary
/// per-media request headers.
///
/// libVLC 3 only exposes User-Agent and Referer. This proxy injects the complete
/// header map supplied by a plugin, forwards byte-range requests, and keeps HLS
/// and DASH child requests inside the proxy. A random path token prevents other
/// local processes from using the endpoint as an open proxy.
final class MediaHeaderProxy {
  MediaHeaderProxy._({
    required HttpServer server,
    required HttpClient client,
    required String token,
    required Uri initialUri,
    required Map<String, String> headers,
  })  : _server = server,
        _client = client,
        _token = token,
        _initialUri = initialUri,
        _headers = Map<String, String>.unmodifiable(headers);

  static const int _manifestLimit = 8 * 1024 * 1024;

  static const Set<String> _hopByHopHeaders = <String>{
    'connection',
    'content-length',
    'host',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
  };

  static const Set<String> _requestHeadersToForward = <String>{
    'accept',
    'if-match',
    'if-modified-since',
    'if-none-match',
    'if-range',
    'if-unmodified-since',
    'range',
  };

  final HttpServer _server;
  final HttpClient _client;
  final String _token;
  final Uri _initialUri;
  final Map<String, String> _headers;
  StreamSubscription<HttpRequest>? _requests;
  bool _closed = false;

  /// Starts a proxy bound only to 127.0.0.1 and returns its private playback URL.
  static Future<MediaHeaderProxy> start({
    required Uri upstream,
    required Map<String, String> headers,
  }) async {
    if (upstream.scheme != 'http' && upstream.scheme != 'https') {
      throw ArgumentError.value(
        upstream,
        'upstream',
        'Only HTTP and HTTPS media can be proxied.',
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    final client = HttpClient()..autoUncompress = false;
    final random = Random.secure();
    final token = base64Url
        .encode(List<int>.generate(24, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final proxy = MediaHeaderProxy._(
      server: server,
      client: client,
      token: token,
      initialUri: upstream,
      headers: headers,
    );
    proxy._requests = server.listen((request) {
      unawaited(proxy._handle(request));
    });
    return proxy;
  }

  /// The URL handed to libVLC.
  Uri get playbackUri => _proxyUri(_initialUri);

  Uri _proxyUri(Uri target) {
    final origin = target.origin;
    final originToken =
        base64Url.encode(utf8.encode(origin)).replaceAll('=', '');
    final upstreamSegments = target.pathSegments;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _server.port,
      pathSegments: <String>[
        _token,
        originToken,
        if (upstreamSegments.isEmpty) '' else ...upstreamSegments,
      ],
      query: target.hasQuery ? target.query : null,
    );
  }

  Uri? _upstreamUri(HttpRequest request) {
    final segments = request.uri.pathSegments;
    if (segments.length < 2 || segments.first != _token) return null;
    try {
      final originText = utf8.decode(
        base64Url.decode(base64Url.normalize(segments[1])),
      );
      final origin = Uri.parse(originText);
      if (origin.scheme != 'http' && origin.scheme != 'https') return null;
      if (!origin.hasAuthority || origin.path.isNotEmpty) return null;
      return origin.replace(
        pathSegments: segments.skip(2),
        query: request.uri.hasQuery ? request.uri.query : null,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final target = _upstreamUri(request);
    if (target == null) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
      await response.close();
      return;
    }

    try {
      final upstreamRequest = await _client.openUrl(request.method, target);
      upstreamRequest.followRedirects = false;
      for (final name in _requestHeadersToForward) {
        final values = request.headers[name];
        if (values == null) continue;
        for (final value in values) {
          upstreamRequest.headers.add(name, value);
        }
      }
      for (final entry in _headers.entries) {
        final name = entry.key.trim();
        if (name.isEmpty || _hopByHopHeaders.contains(name.toLowerCase())) {
          continue;
        }
        upstreamRequest.headers.set(name, entry.value);
      }
      // Manifests must be readable before their child URLs can be rewritten.
      upstreamRequest.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final upstream = await upstreamRequest.close();
      response.statusCode = upstream.statusCode;
      final rewriteBody = request.method == 'GET' &&
          upstream.statusCode >= 200 &&
          upstream.statusCode < 300 &&
          (_isHls(target, upstream.headers.contentType) ||
              _isDash(target, upstream.headers.contentType));
      _copyResponseHeaders(
        upstream,
        response,
        target,
        rewritingBody: rewriteBody,
      );

      if (request.method == 'HEAD') {
        await upstream.drain<void>();
        await response.close();
        return;
      }
      if (!rewriteBody) {
        await response.addStream(upstream);
        await response.close();
        return;
      }

      final bytes = await _readManifest(upstream);
      final body = utf8.decode(bytes, allowMalformed: true);
      final rewritten = _isHls(target, upstream.headers.contentType)
          ? _rewriteHls(body, target)
          : _rewriteDash(body, target);
      final output = utf8.encode(rewritten);
      response.headers.contentLength = output.length;
      response.add(output);
      await response.close();
    } on Object catch (error, stackTrace) {
      AppLog.warn(
        'Media header proxy failed for $target',
        detail: error,
      );
      AppLog.debug('$stackTrace');
      try {
        response.statusCode = HttpStatus.badGateway;
      } on StateError {
        // Headers were already sent while streaming a response.
      }
      try {
        await response.close();
      } on Object {
        // The native player may have abandoned the request after a seek.
      }
    }
  }

  void _copyResponseHeaders(
    HttpClientResponse upstream,
    HttpResponse downstream,
    Uri target, {
    required bool rewritingBody,
  }) {
    upstream.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (_hopByHopHeaders.contains(lower) || lower == 'content-length') {
        return;
      }
      if (rewritingBody && lower == 'content-encoding') return;
      if (lower == HttpHeaders.locationHeader) {
        final location = values.firstOrNull;
        if (location != null) {
          final redirected = target.resolve(location);
          if (redirected.scheme == 'http' || redirected.scheme == 'https') {
            downstream.headers.set(name, _proxyUri(redirected).toString());
          }
        }
        return;
      }
      for (final value in values) {
        downstream.headers.add(name, value);
      }
    });
    if (!rewritingBody && upstream.contentLength >= 0) {
      downstream.contentLength = upstream.contentLength;
    }
  }

  static bool _isHls(Uri uri, ContentType? contentType) {
    final mime = contentType?.mimeType.toLowerCase();
    return uri.path.toLowerCase().endsWith('.m3u8') ||
        mime == 'application/vnd.apple.mpegurl' ||
        mime == 'application/x-mpegurl';
  }

  static bool _isDash(Uri uri, ContentType? contentType) {
    return uri.path.toLowerCase().endsWith('.mpd') ||
        contentType?.mimeType.toLowerCase() == 'application/dash+xml';
  }

  static Future<List<int>> _readManifest(HttpClientResponse response) async {
    final output = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response) {
      length += chunk.length;
      if (length > _manifestLimit) {
        throw const FormatException('Media manifest exceeds 8 MiB.');
      }
      output.add(chunk);
    }
    return output.takeBytes();
  }

  String _proxiedReference(String reference, Uri base) {
    final trimmed = reference.trim();
    if (trimmed.isEmpty) return reference;
    final resolved = base.resolve(trimmed);
    if (resolved.scheme != 'http' && resolved.scheme != 'https') {
      return reference;
    }
    return _proxyUri(resolved).toString();
  }

  String _rewriteHls(String body, Uri base) {
    final uriAttribute = RegExp(r'''URI=(['"])(.*?)\1''');
    final hadTrailingNewline = body.endsWith('\n');
    final lines = const LineSplitter().convert(body);
    final rewritten = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        rewritten.add(line);
      } else if (trimmed.startsWith('#')) {
        rewritten.add(
          line.replaceAllMapped(uriAttribute, (match) {
            final quote = match.group(1)!;
            final uri = _proxiedReference(match.group(2)!, base);
            return 'URI=$quote$uri$quote';
          }),
        );
      } else {
        final leading = line.substring(0, line.length - line.trimLeft().length);
        final trailing = line.substring(line.trimRight().length);
        rewritten.add(
          '$leading${_proxiedReference(trimmed, base)}$trailing',
        );
      }
    }
    final result = rewritten.join('\n');
    return hadTrailingNewline ? '$result\n' : result;
  }

  String _rewriteDash(String body, Uri base) {
    var output = body.replaceAllMapped(
      RegExp(
        r'''\b(media|initialization|sourceURL|href|url)=(['"])(.*?)\2''',
        caseSensitive: false,
      ),
      (match) {
        final name = match.group(1)!;
        final quote = match.group(2)!;
        final uri = _proxiedReference(match.group(3)!, base);
        return '$name=$quote$uri$quote';
      },
    );
    output = output.replaceAllMapped(
      RegExp(
        r'''(<BaseURL\b[^>]*>)(.*?)(</BaseURL>)''',
        caseSensitive: false,
        dotAll: true,
      ),
      (match) {
        final value = match.group(2)!;
        final leading =
            value.substring(0, value.length - value.trimLeft().length);
        final trailing = value.substring(value.trimRight().length);
        final uri = _proxiedReference(value.trim(), base);
        return '${match.group(1)}$leading$uri$trailing${match.group(3)}';
      },
    );
    return output;
  }

  /// Stops accepting local requests and closes pooled upstream connections.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _requests?.cancel();
    _client.close(force: true);
    await _server.close(force: true);
  }
}

extension on List<String> {
  String? get firstOrNull => isEmpty ? null : first;
}
