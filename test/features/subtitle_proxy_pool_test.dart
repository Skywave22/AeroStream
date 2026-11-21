import 'dart:convert';
import 'dart:io';

import 'package:aerostream/domain/entities/stream_source.dart';
import 'package:aerostream/features/player/subtitle_proxy_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('external subtitle headers reach the origin through one reused proxy',
      () async {
    final seenAuthorization = <String?>[];
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      seenAuthorization.add(request.headers.value('authorization'));
      request.response.headers.contentType = ContentType(
        'text',
        'plain',
        charset: 'utf-8',
      );
      request.response.write('1\n00:00:00,000 --> 00:00:01,000\nHello\n');
      await request.response.close();
    });
    addTearDown(() => upstream.close(force: true));

    final pool = SubtitleProxyPool();
    addTearDown(() => pool.close());
    final track = SubtitleTrack(
      url:
          'http://${upstream.address.address}:${upstream.port}/captions/en.srt',
      language: 'English',
      format: 'srt',
      headers: const <String, String>{
        'Authorization': 'Bearer subtitle-token',
      },
    );

    final first = await pool.playbackUri(track);
    final second = await pool.playbackUri(track);
    expect(second, first, reason: 'one player surface should reuse its proxy');
    expect(first.path, endsWith('/captions/en.srt'));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(first)).close();
    final body = await utf8.decodeStream(response);

    expect(response.statusCode, HttpStatus.ok);
    expect(body, contains('Hello'));
    expect(seenAuthorization, <String?>['Bearer subtitle-token']);
  });
}
