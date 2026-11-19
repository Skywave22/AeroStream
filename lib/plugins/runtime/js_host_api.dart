import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/export.dart' show KeyParameter, ParametersWithIV;

import '../../core/errors/plugin_error.dart';
import '../../core/logging/app_log.dart';
import '../../core/network/http_service.dart';
import '../../core/network/network_policy.dart';
import '../../core/result.dart';
import '../../domain/repositories/extension_store.dart';

/// A call a plugin made into the host.
final class JsHostCall {
  const JsHostCall({
    required this.id,
    required this.channel,
    required this.payload,
  });

  final String id;
  final String channel;
  final String payload;

  Map<String, Object?> get json {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry(key.toString(), value as Object?),
        );
      }
    } on FormatException {
      // A malformed payload is the plugin's problem; the handlers see {}.
    }
    return const <String, Object?>{};
  }

  @override
  String toString() => 'JsHostCall($channel, $id)';
}

/// The host's answer to a [JsHostCall].
final class JsHostReply {
  const JsHostReply(this.json, {this.isError = false});

  const JsHostReply.error(String message)
      : json = '{"message":"$message"}',
        isError = true;

  final String json;
  final bool isError;

  static const JsHostReply ok = JsHostReply('null');
}

/// Everything a plugin is allowed to ask the host to do.
///
/// This is the whole privileged surface. There is no filesystem channel, no
/// process channel, and no way to register a new one from JavaScript.
final class JsHostApi {
  JsHostApi({
    required HttpService http,
    required SettingsStore settings,
    required this.pluginId,
    this.policy = const NetworkPolicy(),
  })  : _http = http,
        _settings = settings;

  final HttpService _http;
  final SettingsStore _settings;
  final String pluginId;
  final NetworkPolicy policy;

  /// Documents kept alive between calls so a plugin can hold a parsed page.
  final Map<String, dom.Document> _documents = <String, dom.Document>{};
  int _documentSeq = 0;

  /// Handles [call]. Never throws: a failed host call becomes an error reply,
  /// which the plugin sees as a rejected promise.
  Future<JsHostReply> handle(JsHostCall call) async {
    try {
      return await _dispatch(call);
    } on PluginError catch (error) {
      AppLog.warn(
        'Host call ${call.channel} failed: ${error.message}',
        pluginId: pluginId,
      );
      return _errorReply(error);
    } on Object catch (error, stack) {
      AppLog.error(
        'Host call ${call.channel} crashed: $error',
        pluginId: pluginId,
        detail: error,
        stackTrace: stack,
      );
      return JsHostReply(
        jsonEncode(<String, Object?>{
          'message': 'Host call failed: $error',
          'kind': 'host',
        }),
        isError: true,
      );
    }
  }

  Future<JsHostReply> _dispatch(JsHostCall call) async {
    final payload = call.json;
    switch (call.channel) {
      case 'http:get':
        return _httpRequest(payload, method: 'GET');
      case 'http:post':
        return _httpRequest(payload, method: 'POST');
      case 'http:batch':
        return _batch(payload);
      case 'html:parse':
        return _parseDocument(payload);
      case 'html:select':
        return _select(payload);
      case 'html:query':
        return _queryDocument(payload);
      case 'html:attr':
        return _attribute(payload);
      case 'html:text':
        return _text(payload);
      case 'crypto:md5':
        return _digest(payload, 'md5');
      case 'crypto:sha256':
        return _digest(payload, 'sha256');
      case 'crypto:hmac':
        return _hmac(payload);
      case 'crypto:aes':
        return _aesDecrypt(payload);
      case 'text:b64encode':
        return _base64(payload, encode: true);
      case 'text:b64decode':
        return _base64(payload, encode: false);
      case 'storage:get':
        return _storageGet(payload);
      case 'storage:set':
        return _storageSet(payload);
      case 'storage:remove':
        return _storageRemove(payload);
      default:
        return JsHostReply.error('Unknown host channel "${call.channel}"');
    }
  }

  JsHostReply _errorReply(PluginError error) => JsHostReply(
        jsonEncode(<String, Object?>{
          'message': error.message,
          'kind': error.kind,
          'userMessage': error.userMessage,
        }),
        isError: true,
      );

  // ---- HTTP --------------------------------------------------------------

  Future<JsHostReply> _httpRequest(
    Map<String, Object?> payload, {
    required String method,
  }) async {
    final rawUrl = payload['url']?.toString();
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl);
    if (uri == null) {
      return const JsHostReply.error('Invalid URL');
    }
    final checked = policy.check(uri);
    if (checked is Err<Uri>) return _errorReply(checked.error);

    final headers = <String, String>{};
    final rawHeaders = payload['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value.toString();
      }
    }

    final started = DateTime.now();
    final response = method == 'POST'
        ? await _http.post(uri, body: payload['body'], headers: headers)
        : await _http.get(uri, headers: headers);
    final elapsed = DateTime.now().difference(started);

    switch (response) {
      case Err<HttpPayload>(:final error):
        AppLog.warn(
          '$method ${uri.host} failed after ${elapsed.inMilliseconds}ms: '
          '${error.message}',
          pluginId: pluginId,
        );
        return _errorReply(error);
      case Ok<HttpPayload>(:final value):
        AppLog.debug(
          '$method ${uri.host} -> ${value.statusCode} '
          '(${value.bytes.length}B, ${elapsed.inMilliseconds}ms)',
          pluginId: pluginId,
        );
        return JsHostReply(
          jsonEncode(<String, Object?>{
            'status': value.statusCode,
            'url': value.url ?? uri.toString(),
            'body': value.text,
            'headers': value.headers,
          }),
        );
    }
  }

  Future<JsHostReply> _batch(Map<String, Object?> payload) async {
    final requests = payload['requests'];
    if (requests is! List) {
      return const JsHostReply.error('requests must be a list');
    }
    final results = <Object?>[];
    for (final request in requests) {
      if (request is! Map) continue;
      final uri = Uri.tryParse(request['url']?.toString() ?? '');
      if (uri == null) {
        results.add(<String, Object?>{'error': 'invalid url'});
        continue;
      }
      final checked = policy.check(uri);
      if (checked is Err<Uri>) {
        results.add(<String, Object?>{'error': checked.error.message});
        continue;
      }
      final headers = <String, String>{};
      final rawHeaders = request['headers'];
      if (rawHeaders is Map) {
        for (final entry in rawHeaders.entries) {
          headers[entry.key.toString()] = entry.value.toString();
        }
      }
      final response = await _http.get(uri, headers: headers);
      results.add(
        switch (response) {
          Ok<HttpPayload>(:final value) => <String, Object?>{
              'status': value.statusCode,
              'body': value.text,
            },
          Err<HttpPayload>(:final error) => <String, Object?>{
              'error': error.message,
            },
        },
      );
    }
    return JsHostReply(jsonEncode(<String, Object?>{'responses': results}));
  }

  // ---- HTML --------------------------------------------------------------

  JsHostReply _parseDocument(Map<String, Object?> payload) {
    final html = payload['html']?.toString() ?? '';
    final document = html_parser.parse(html);
    final id = 'doc${++_documentSeq}';
    _documents[id] = document;
    if (_documents.length > 20) {
      // Keep the oldest 10 only: a plugin parsing thousands of pages would
      // otherwise hold the whole heap.
      final keys = _documents.keys.toList()..sort();
      for (final key in keys.take(_documents.length - 10)) {
        _documents.remove(key);
      }
    }
    return JsHostReply(jsonEncode(<String, Object?>{'id': id}));
  }

  JsHostReply _select(Map<String, Object?> payload) {
    final document = html_parser.parse(payload['html']?.toString() ?? '');
    final selector = payload['selector']?.toString() ?? '';
    final attribute = payload['attribute']?.toString();
    return JsHostReply(
      jsonEncode(_extract(document, selector, attribute)),
    );
  }

  JsHostReply _queryDocument(Map<String, Object?> payload) {
    final document = _documents[payload['doc']?.toString()];
    if (document == null) return const JsHostReply.error('Unknown document id');
    return JsHostReply(
      jsonEncode(
        _extract(
          document,
          payload['selector']?.toString() ?? '',
          payload['attribute']?.toString(),
        ),
      ),
    );
  }

  JsHostReply _attribute(Map<String, Object?> payload) {
    final document = _documents[payload['doc']?.toString()];
    if (document == null) return const JsHostReply.error('Unknown document id');
    final element = _first(document, payload['selector']?.toString() ?? '');
    if (element == null) return const JsHostReply('null');
    final value = element.attributes[payload['attribute']?.toString() ?? ''];
    return JsHostReply(jsonEncode(value));
  }

  JsHostReply _text(Map<String, Object?> payload) {
    final document = _documents[payload['doc']?.toString()];
    if (document == null) return const JsHostReply.error('Unknown document id');
    final element = _first(document, payload['selector']?.toString() ?? '');
    return JsHostReply(jsonEncode(element?.text.trim()));
  }

  dom.Element? _first(dom.Document document, String selector) {
    if (selector.trim().isEmpty) {
      return document.body ?? document.documentElement;
    }
    try {
      return document.querySelector(selector);
    } on Object {
      return null;
    }
  }

  List<Object?> _extract(
    dom.Document document,
    String selector,
    String? attribute,
  ) {
    if (selector.trim().isEmpty) return const <Object?>[];
    List<dom.Element> elements;
    try {
      elements = document.querySelectorAll(selector);
    } on Object {
      return const <Object?>[];
    }
    if (attribute != null) {
      return elements
          .map((element) => element.attributes[attribute])
          .whereType<String>()
          .toList(growable: false);
    }
    return elements
        .map(
          (element) => <String, Object?>{
            'text': element.text.trim(),
            'html': element.innerHtml,
            'attrs': element.attributes,
          },
        )
        .toList(growable: false);
  }

  // ---- crypto / encoding -------------------------------------------------

  JsHostReply _digest(Map<String, Object?> payload, String algorithm) {
    final input = utf8.encode(payload['input']?.toString() ?? '');
    final digest = algorithm == 'md5'
        ? crypto.md5.convert(input).toString()
        : crypto.sha256.convert(input).toString();
    return JsHostReply(jsonEncode(digest));
  }

  JsHostReply _hmac(Map<String, Object?> payload) {
    final key = utf8.encode(payload['key']?.toString() ?? '');
    final message = utf8.encode(payload['message']?.toString() ?? '');
    final algorithm =
        payload['algorithm']?.toString().toLowerCase() ?? 'sha256';
    final hmac = algorithm == 'sha1'
        ? crypto.Hmac(crypto.sha1, key)
        : crypto.Hmac(crypto.sha256, key);
    return JsHostReply(jsonEncode(hmac.convert(message).toString()));
  }

  /// AES-CBC decryption, the shape plugins use for "the API answers
  /// base64(AES(payload))" endpoints.
  ///
  /// `data` is base64 or hex; `key` and `iv` are base64/hex when they look like
  /// it and UTF-8 text otherwise, which is how these keys are written in the
  /// wild. PKCS#7 padding is stripped when present, and the plaintext is
  /// returned as text so `JSON.parse(await crypto.decryptAES(...))` just works.
  JsHostReply _aesDecrypt(Map<String, Object?> payload) {
    final data = _bytesFrom(payload['data'], preferText: false);
    final key = _bytesFrom(payload['key']);
    final iv = _bytesFrom(payload['iv']);

    if (data == null || data.isEmpty) {
      throw const PluginParseError(
        'crypto.decryptAES needs base64 or hex data',
      );
    }
    if (key == null || (key.length != 16 && key.length != 24 && key.length != 32)) {
      throw const PluginParseError(
        'crypto.decryptAES needs a 16, 24 or 32 byte key',
      );
    }
    if (data.length % 16 != 0) {
      throw const PluginParseError(
        'crypto.decryptAES data is not a whole number of blocks',
      );
    }

    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        false,
        ParametersWithIV(KeyParameter(key), iv ?? Uint8List(16)),
      );

    final plain = Uint8List(data.length);
    for (var offset = 0; offset < data.length; offset += 16) {
      cipher.processBlock(data, offset, plain, offset);
    }

    // Strip PKCS#7 padding only when it is well formed; some feeds pad with
    // spaces or not at all.
    var length = plain.length;
    if (length > 0) {
      final pad = plain[length - 1];
      if (pad > 0 && pad <= 16 && pad <= length) {
        var valid = true;
        for (var i = length - pad; i < length; i++) {
          if (plain[i] != pad) {
            valid = false;
            break;
          }
        }
        if (valid) length -= pad;
      }
    }

    return JsHostReply(
      jsonEncode(utf8.decode(plain.sublist(0, length), allowMalformed: true)),
    );
  }

  /// Decodes base64, then hex, then UTF-8 text, depending on what it looks like.
  Uint8List? _bytesFrom(Object? value, {bool preferText = true}) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) return null;

    if (!preferText) {
      final base64Bytes = _tryBase64(text);
      if (base64Bytes != null) return base64Bytes;
      final hexBytes = _tryHex(text);
      if (hexBytes != null) return hexBytes;
      return Uint8List.fromList(utf8.encode(text));
    }

    final hexBytes = _tryHex(text);
    if (hexBytes != null) return hexBytes;
    final base64Bytes = _tryBase64(text);
    if (base64Bytes != null) return base64Bytes;
    return Uint8List.fromList(utf8.encode(text));
  }

  Uint8List? _tryBase64(String text) {
    if (!RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(text)) return null;
    try {
      return Uint8List.fromList(base64.decode(base64.normalize(text)));
    } on FormatException {
      return null;
    }
  }

  Uint8List? _tryHex(String text) {
    if (text.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) {
      return null;
    }
    final bytes = Uint8List(text.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(text.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  JsHostReply _base64(Map<String, Object?> payload, {required bool encode}) {
    if (encode) {
      return JsHostReply(
        jsonEncode(
            base64Encode(utf8.encode(payload['input']?.toString() ?? ''))),
      );
    }
    final raw = payload['input']?.toString() ?? '';
    try {
      return JsHostReply(
        jsonEncode(utf8.decode(base64.decode(base64.normalize(raw)))),
      );
    } on FormatException {
      return const JsHostReply.error('Invalid base64 input');
    }
  }

  JsHostReply _unsupported(String message) => JsHostReply(
        jsonEncode(
            <String, Object?>{'message': message, 'kind': 'unsupported'}),
        isError: true,
      );

  // ---- storage -----------------------------------------------------------

  String _storageKey(String key) => 'plugin.$pluginId.$key';

  JsHostReply _storageGet(Map<String, Object?> payload) {
    final key = payload['key']?.toString();
    if (key == null) return const JsHostReply.error('key is required');
    final stored = _settings.getString(_storageKey(key));
    if (stored == null) return JsHostReply(jsonEncode(payload['fallback']));
    return JsHostReply(jsonEncode(stored));
  }

  Future<JsHostReply> _storageSet(Map<String, Object?> payload) async {
    final key = payload['key']?.toString();
    if (key == null) return const JsHostReply.error('key is required');
    final value = payload['value'];
    await _settings.setString(
      _storageKey(key),
      value is String ? value : jsonEncode(value),
    );
    return JsHostReply.ok;
  }

  Future<JsHostReply> _storageRemove(Map<String, Object?> payload) async {
    final key = payload['key']?.toString();
    if (key == null) return const JsHostReply.error('key is required');
    await _settings.remove(_storageKey(key));
    return JsHostReply.ok;
  }

  /// Drops cached documents (called when the plugin context is torn down).
  void dispose() => _documents.clear();
}
