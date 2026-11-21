import 'dart:convert';
import 'dart:io';

import 'package:aerostream/app/self_check.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

void main() {
  late Directory temporary;
  late File fixture;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('aerostream-selfcheck-');
    fixture = File('${temporary.path}/SkyStreamTest.cs3');
    await fixture.writeAsBytes(<int>[0x50, 0x4B, 0x03, 0x04]);
  });

  tearDown(() => temporary.delete(recursive: true));

  test('publishes only the compiled self-check repository and extension',
      () async {
    final delegate = FakeHttpService(<String, Object>{
      'https://example.com/live.json': '{"live":true}',
    });
    final service = SelfCheckHttpService(
      delegate: delegate,
      fixture: fixture.path,
    );

    final repository =
        (await service.get(SelfCheckHttpService.repository)).valueOrNull!;
    final listing = jsonDecode(repository.text) as List<Object?>;
    final entry = listing.single as Map<String, Object?>;
    expect(entry['internalName'], 'SkyStreamTest');
    expect(entry['url'], SelfCheckHttpService.extension.toString());

    final extension =
        (await service.get(SelfCheckHttpService.extension)).valueOrNull!;
    expect(extension.bytes, <int>[0x50, 0x4B, 0x03, 0x04]);

    final public = Uri.parse('https://example.com/live.json');
    expect((await service.get(public)).valueOrNull!.text, '{"live":true}');
    expect(delegate.requested, <String>[public.toString()]);
  });
}
