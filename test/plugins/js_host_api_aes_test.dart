import 'dart:convert';

import 'package:aerostream/core/errors/plugin_error.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/plugins/runtime/js_host_api.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// `AES-128-CBC`, produced with Node's crypto and appended PKCS#7 padding:
/// key `0123456789abcdef`, iv `fedcba9876543210`, plaintext `{"ok":true}`.
const _key = '0123456789abcdef';
const _iv = 'fedcba9876543210';
const _base64Cipher = '8x50Sodj15RIgU9dhPLw7w==';
const _hexCipher = 'f31e744a8763d79448814f5d84f2f0ef';

Future<Result<String>> _decrypt(Map<String, Object?> payload) async {
  final api = JsHostApi(
    http: FakeHttpService(),
    settings: InMemorySettingsStore(),
    pluginId: 'dev.example.aes',
  );
  final reply = await api.handle(
    JsHostCall(
      id: '1',
      channel: 'crypto:aes',
      payload: jsonEncode(payload),
    ),
  );
  final decoded = jsonDecode(reply.json);
  if (reply.isError) {
    return Err<String>(
      PluginParseError((decoded as Map)['message'].toString()),
    );
  }
  return Ok<String>(decoded.toString());
}

void main() {
  test('decrypts base64 data with an ASCII key and iv', () async {
    final result = await _decrypt(<String, Object?>{
      'data': _base64Cipher,
      'key': _key,
      'iv': _iv,
    });

    expect(result, isA<Ok<String>>());
    expect((result as Ok<String>).value, '{"ok":true}');
  });

  test('accepts hex ciphertext', () async {
    final result = await _decrypt(<String, Object?>{
      'data': _hexCipher,
      'dataEncoding': 'hex',
      'key': _key,
      'iv': _iv,
    });

    expect((result as Ok<String>).value, '{"ok":true}');
  });

  test('hex is detected without being declared', () async {
    final result = await _decrypt(<String, Object?>{
      'data': _hexCipher,
      'key': _key,
      'iv': _iv,
    });

    expect((result as Ok<String>).value, '{"ok":true}');
  });

  test('keyEncoding settles what the shape alone cannot', () async {
    // 32 characters are a legal AES-256 passphrase, so text is the default...
    final asText = await _decrypt(<String, Object?>{
      'data': _base64Cipher,
      'key': 'fedcba9876543210fedcba9876543210',
      'iv': _iv,
    });
    expect(asText, isA<Ok<String>>());

    // ...and the same characters read as hex are only 8 bytes.
    final asHex = await _decrypt(<String, Object?>{
      'data': _base64Cipher,
      'key': 'fedcba9876543210',
      'keyEncoding': 'hex',
      'iv': _iv,
    });
    expect(asHex, isA<Err<String>>());
    expect(
      (asHex as Err<String>).error.message,
      contains('16, 24 or 32 byte key'),
    );
  });

  test('a wrong-length key is a plugin error with a readable message',
      () async {
    final result = await _decrypt(<String, Object?>{
      'data': _base64Cipher,
      'key': 'short',
      'iv': _iv,
    });

    expect(result, isA<Err<String>>());
    expect(
      (result as Err<String>).error.message,
      contains('16, 24 or 32 byte key'),
    );
  });

  test('data that is not whole blocks is rejected, not truncated', () async {
    final result = await _decrypt(<String, Object?>{
      'data': base64Encode(utf8.encode('not a multiple of sixteen')),
      'key': _key,
      'iv': _iv,
    });

    expect(result, isA<Err<String>>());
    expect(
      (result as Err<String>).error.message,
      contains('whole number of blocks'),
    );
  });
}
