import 'dart:async';

import 'package:cs3_engine/cs3_engine.dart';

import '../../../core/errors/plugin_error.dart';
import '../../../core/json/json_read.dart';
import '../../../core/logging/app_log.dart';
import '../../../core/result.dart';

/// The shared JSON boundary to SkyStream's CloudStream compatibility engine.
///
/// Android runs the engine in-process, iOS hosts it in an embedded OpenJDK Zero
/// VM, and desktop starts the bundled Java sidecar. The Dart adapter does not
/// need platform-specific commands: every host speaks this same protocol.
abstract interface class CloudStreamBridge {
  Future<bool> isAvailable();

  /// Engine events needed by browser and extension-UI surfaces.
  Stream<Map<String, Object?>> get events;

  Future<Result<Map<String, Object?>>> invoke(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]);

  Future<void> dispose();
}

/// Lifecycle owner for the one [Cs3Engine] instance used by the app.
///
/// Startup is lazy so a broken Java installation cannot stop AeroStream itself
/// from opening. Concurrent first calls share one startup, and a sidecar that
/// exits is replaced on the next call. A successful handshake is cached only
/// while that engine remains alive.
final class Cs3EngineBridge implements CloudStreamBridge {
  Cs3EngineBridge({required String dataDir, String? java, String? language})
      : _dataDir = dataDir,
        _java = java,
        _language = language;

  final String _dataDir;
  final String? _java;
  final String? _language;

  Cs3Engine? _engine;
  Future<Cs3Engine>? _starting;
  StreamSubscription<Map<String, dynamic>>? _engineEvents;
  final StreamController<Map<String, Object?>> _reportedEvents =
      StreamController<Map<String, Object?>>.broadcast();
  bool _handshaken = false;
  bool _disposed = false;

  @override
  Stream<Map<String, Object?>> get events => _reportedEvents.stream;

  Future<Cs3Engine> _runningEngine() async {
    if (_disposed) throw StateError('the CloudStream engine was disposed');

    final current = _engine;
    if (current != null && current.isRunning) return current;
    _engine = null;
    _handshaken = false;
    await _engineEvents?.cancel();
    _engineEvents = null;

    final pending = _starting;
    if (pending != null) return pending;

    final startup = Cs3Engine.start(dataDir: _dataDir, java: _java);
    _starting = startup;
    try {
      final started = await startup;
      if (_disposed) {
        await started.dispose();
        throw StateError('the CloudStream engine was disposed');
      }
      _engine = started;
      _engineEvents = started.events.listen(
        (event) => _onEvent(started, event),
        onError: (Object error, StackTrace stackTrace) {
          AppLog.error(
            'CloudStream engine event stream failed: $error',
            detail: error,
            stackTrace: stackTrace,
          );
        },
      );
      return started;
    } finally {
      if (identical(_starting, startup)) _starting = null;
    }
  }

  @override
  Future<bool> isAvailable() async {
    final current = _engine;
    if (_handshaken && current != null && current.isRunning) return true;
    try {
      final engine = await _runningEngine();
      final hello = await engine.hello();
      final language = _language?.trim();
      if (language != null && language.isNotEmpty) {
        await engine.setLanguage(language);
      }
      _handshaken = true;
      AppLog.info(
        'CloudStream engine ready: ${hello['engine'] ?? 'unknown'} '
        '(${hello['platform'] ?? 'unknown platform'})',
      );
      return true;
    } catch (error, stackTrace) {
      AppLog.error(
        'CloudStream engine did not start: $error',
        detail: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  void _onEvent(Cs3Engine engine, Map<String, dynamic> event) {
    if (!_reportedEvents.isClosed) {
      _reportedEvents.add(Map<String, Object?>.from(event));
    }
    final type = readString(event['event']) ?? 'unknown';
    if (type == 'repositoryAdded') {
      AppLog.warn(
        'A CloudStream extension requested repository '
        '${readString(event['url']) ?? '(unknown URL)'}. Add it from the '
        'Extensions screen to review it before installation.',
      );
      return;
    }
    if (type == 'webRequest') {
      final operation = readString(event['op']);
      final requestId = readInt(event['rid']);
      if (requestId != null &&
          operation != null &&
          const <String>{'solve', 'fetch', 'resolve', 'eval'}
              .contains(operation)) {
        AppLog.warn(
          'CloudStream requested browser operation $operation for '
          '${readString(event['url']) ?? 'an extension page'}, but this build '
          'has no challenge-browser surface. Returning an empty answer.',
        );
        unawaited(_rejectBrowserRequest(engine, requestId, operation));
      }
      return;
    }
    if (type == 'uiOpened' || type == 'ui' || type == 'popups') {
      AppLog.warn(
        'CloudStream extension UI event "$type" is not renderable in this '
        'AeroStream build yet.',
      );
    }
  }

  Future<void> _rejectBrowserRequest(
    Cs3Engine engine,
    int requestId,
    String operation,
  ) async {
    try {
      if (operation == 'solve') {
        await engine.webReply(requestId);
      } else {
        await engine.webAnswer(requestId);
      }
    } catch (error, stackTrace) {
      AppLog.error(
        'Could not reject CloudStream browser request: $error',
        detail: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<Result<Map<String, Object?>>> invoke(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    try {
      final engine = await _runningEngine();
      final response = await engine.call(method, arguments);
      return Ok<Map<String, Object?>>(Map<String, Object?>.from(response));
    } on Cs3EngineException catch (error, stackTrace) {
      return Err<Map<String, Object?>>(_engineError(error, method, stackTrace));
    } catch (error, stackTrace) {
      return Err<Map<String, Object?>>(
        PluginCrashError(
          'CloudStream engine failed during $method: $error',
          cause: error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  PluginError _engineError(
    Cs3EngineException error,
    String operation,
    StackTrace stackTrace,
  ) {
    final type = error.type.toLowerCase();
    if (type.contains('timeout')) {
      return PluginTimeoutError(
        error.message,
        cause: error,
        stackTrace: stackTrace,
      );
    }
    if (type.contains('javanotfound') || type.contains('unsupported')) {
      return PluginUnsupportedError(
        error.message,
        cause: error,
        stackTrace: stackTrace,
        operation: operation,
      );
    }
    return PluginCrashError(
      '${error.type}: ${error.message}',
      cause: error,
      stackTrace: stackTrace,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _handshaken = false;
    final pending = _starting;
    final current = _engine;
    _engine = null;
    await _engineEvents?.cancel();
    _engineEvents = null;
    await _reportedEvents.close();
    if (current != null) {
      await current.dispose();
    } else if (pending != null) {
      try {
        await (await pending).dispose();
      } catch (_) {
        // Startup already failed; there is no process left to close.
      }
    }
  }
}
