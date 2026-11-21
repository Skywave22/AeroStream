import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aerostream/features/player/media_header_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('injects plugin headers and preserves byte ranges', () async {
    final seen = Completer<Map<String, String?>>();
    final origin = await _origin((request) async {
      seen.complete(<String, String?>{
        'authorization': request.headers.value(HttpHeaders.authorizationHeader),
        'cookie': request.headers.value(HttpHeaders.cookieHeader),
        'origin': request.headers.value('origin'),
        'range': request.headers.value(HttpHeaders.rangeHeader),
      });
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes 2-4/6')
        ..add(utf8.encode('cde'));
      await request.response.close();
    });
    addTearDown(() => origin.close(force: true));

    final proxy = await MediaHeaderProxy.start(
      upstream: _uri(origin, '/movie.mp4'),
      headers: const <String, String>{
        'Authorization': 'Bearer secret',
        'Cookie': 'session=abc',
        'Origin': 'https://plugin.example',
      },
    );
    addTearDown(proxy.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request = await client.getUrl(proxy.playbackUri);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=2-4');
    final response = await request.close();

    expect(response.statusCode, HttpStatus.partialContent);
    expect(
        response.headers.value(HttpHeaders.contentRangeHeader), 'bytes 2-4/6');
    expect(await utf8.decoder.bind(response).join(), 'cde');
    expect(
      await seen.future,
      <String, String?>{
        'authorization': 'Bearer secret',
        'cookie': 'session=abc',
        'origin': 'https://plugin.example',
        'range': 'bytes=2-4',
      },
    );
  });

  test('rewrites HLS playlists and proxies their children', () async {
    final requested = <String>[];
    final cookies = <String?>[];
    final origin = await _origin((request) async {
      requested.add(request.uri.path);
      cookies.add(request.headers.value(HttpHeaders.cookieHeader));
      switch (request.uri.path) {
        case '/hls/master.m3u8':
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write('''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="/keys/key.bin"
child/playlist.m3u8
''');
        case '/hls/child/playlist.m3u8':
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write('''#EXTM3U
#EXTINF:4,
segment.ts
''');
        case '/hls/child/segment.ts':
          request.response.add(<int>[1, 2, 3, 4]);
        case '/keys/key.bin':
          request.response.add(<int>[9, 8, 7]);
        default:
          request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
    addTearDown(() => origin.close(force: true));

    final proxy = await MediaHeaderProxy.start(
      upstream: _uri(origin, '/hls/master.m3u8'),
      headers: const <String, String>{'Cookie': 'stream=yes'},
    );
    addTearDown(proxy.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final master = await _getText(client, proxy.playbackUri);
    final childUri = Uri.parse(
      master.split('\n').firstWhere((line) => line.startsWith('http://')),
    );
    final keyMatch = RegExp(r'URI="([^"]+)"').firstMatch(master);
    final keyUri = Uri.parse(keyMatch!.group(1)!);

    expect(childUri.host, InternetAddress.loopbackIPv4.address);
    expect(keyUri.host, InternetAddress.loopbackIPv4.address);
    final child = await _getText(client, childUri);
    final segmentUri = Uri.parse(
      child.split('\n').firstWhere((line) => line.startsWith('http://')),
    );
    final segment = await _getBytes(client, segmentUri);
    final key = await _getBytes(client, keyUri);

    expect(segment, <int>[1, 2, 3, 4]);
    expect(key, <int>[9, 8, 7]);
    expect(
      requested,
      <String>[
        '/hls/master.m3u8',
        '/hls/child/playlist.m3u8',
        '/hls/child/segment.ts',
        '/keys/key.bin',
      ],
    );
    expect(cookies, everyElement('stream=yes'));
  });

  test('keeps redirects inside the authenticated proxy', () async {
    final origin = await _origin((request) async {
      if (request.uri.path == '/start') {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(HttpHeaders.locationHeader, '/final.mp4');
      } else {
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer redirected',
        );
        request.response.write('video');
      }
      await request.response.close();
    });
    addTearDown(() => origin.close(force: true));

    final proxy = await MediaHeaderProxy.start(
      upstream: _uri(origin, '/start'),
      headers: const <String, String>{
        'Authorization': 'Bearer redirected',
      },
    );
    addTearDown(proxy.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final request = await client.getUrl(proxy.playbackUri);
    request.followRedirects = false;
    final redirect = await request.close();
    final location = Uri.parse(
      redirect.headers.value(HttpHeaders.locationHeader)!,
    );
    await redirect.drain<void>();

    expect(redirect.statusCode, HttpStatus.found);
    expect(location.host, InternetAddress.loopbackIPv4.address);
    expect(await _getText(client, location), 'video');
  });
}

Future<HttpServer> _origin(
  Future<void> Function(HttpRequest request) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) => unawaited(handler(request)));
  return server;
}

Uri _uri(HttpServer server, String path) => Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      path: path,
    );

Future<String> _getText(HttpClient client, Uri uri) async {
  final response = await (await client.getUrl(uri)).close();
  expect(response.statusCode, HttpStatus.ok);
  return utf8.decoder.bind(response).join();
}

Future<List<int>> _getBytes(HttpClient client, Uri uri) async {
  final response = await (await client.getUrl(uri)).close();
  expect(response.statusCode, HttpStatus.ok);
  return response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
}
