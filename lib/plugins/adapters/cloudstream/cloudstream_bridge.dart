import 'dart:async';

import 'package:flutter/services.dart';

import '../../../core/errors/plugin_error.dart';
import '../../../core/json/json_read.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/result.dart';

/// The typed boundary between Dart and the Android CloudStream host.
///
/// CloudStream extensions are Kotlin compiled against CloudStream's library;
/// they cannot run in a JS engine, so on Android a native host loads the `.cs3`
/// with a `DexClassLoader`, hosts the CloudStream API surface the extension
/// links against, and answers over this channel. On every other platform the
/// channel is absent and CloudStream plugins are shown as "Android only".
///
/// Commands and their payloads are documented in `docs/PLUGIN_SPEC.md`
/// ("CloudStream host contract"). Everything crossing this boundary is JSON, so
/// the host can add fields without breaking the app.
abstract interface class CloudStreamBridge {
  /// Whether a native host answered the handshake.
  Future<bool> isAvailable();

  /// Sends [command] with [arguments] and returns the decoded reply.
  Future<Result<Map<String, Object?>>> invoke(
    String command,
    Map<String, Object?> arguments, {
    Duration timeout = const Duration(seconds: 30),
  });
}

/// [CloudStreamBridge] over a [MethodChannel].
///
/// A missing implementation (iOS, desktop) is reported as "unsupported", never
/// as a crash: the whole feature is gated on [isAvailable].
final class MethodChannelCloudStreamBridge implements CloudStreamBridge {
  MethodChannelCloudStreamBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'dev.aerostream/cloudstream';

  final MethodChannel _channel;
  bool? _available;

  @override
  Future<bool> isAvailable() async {
    if (_available != null) return _available!;
    try {
      final reply = await _channel
          .invokeMethod<Object?>('handshake')
          .timeout(const Duration(seconds: 5));
      _available = readBool(reply, fallback: true);
    } on MissingPluginException {
      _available = false;
    } on PlatformException catch (error) {
      AppLog.warn('CloudStream host handshake failed: ${error.message}');
      _available = false;
    } on TimeoutException {
      _available = false;
    }
    return _available!;
  }

  @override
  Future<Result<Map<String, Object?>>> invoke(
    String command,
    Map<String, Object?> arguments, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!await isAvailable()) {
      return const Err<Map<String, Object?>>(
        PluginUnsupportedError(
          'The CloudStream host is not available on this platform',
          operation: 'cloudstream-host',
        ),
      );
    }
    try {
      final reply = await _channel
          .invokeMethod<Object?>(command, arguments)
          .timeout(timeout);
      if (reply is Map) return Ok<Map<String, Object?>>(_stringKeyed(reply));
      return const Ok<Map<String, Object?>>(<String, Object?>{});
    } on TimeoutException {
      return Err<Map<String, Object?>>(
        PluginTimeoutError(
          'The CloudStream host did not answer $command in '
          '${timeout.inSeconds}s',
        ),
      );
    } on MissingPluginException {
      _available = false;
      return const Err<Map<String, Object?>>(
        PluginUnsupportedError(
          'The CloudStream host is not installed in this build',
          operation: 'cloudstream-host',
        ),
      );
    } on PlatformException catch (error) {
      return Err<Map<String, Object?>>(
        PluginCrashError(
          error.message ?? 'The extension threw inside the host',
          cause: error.details,
        ),
      );
    }
  }

  static Map<String, Object?> _stringKeyed(Map<Object?, Object?> raw) {
    final result = <String, Object?>{};
    for (final entry in raw.entries) {
      final value = entry.value;
      result[entry.key.toString()] = value is Map ? _stringKeyed(value) : value;
    }
    return result;
  }
}
