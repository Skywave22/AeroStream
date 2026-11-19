import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';

import '../../core/logging/app_log.dart';
import 'js_runtime.dart';

/// [JsRuntime] over QuickJS, running on its own isolate.
///
/// The engine is deliberately thin. Everything AeroStream needs from
/// JavaScript — the bridge, timers, promises, the module registries — is
/// implemented in `assets/js/*.js` and evaluated into this context, so moving
/// to a different engine means writing another class this small, not porting a
/// protocol.
///
/// Two limits are enforced twice on purpose: the host also applies a Dart-side
/// timeout and kills the context when a call overruns, because an interrupt
/// inside the engine is the only thing that stops a `while (true) {}` that has
/// already started.
final class QuickJsRuntime implements JsRuntime {
  QuickJsRuntime({
    this.memoryLimit = 64 * 1024 * 1024,
    this.hardTimeout = const Duration(seconds: 25),
  });

  /// QuickJS aborts an allocation that would cross this ceiling.
  final int memoryLimit;

  /// Hard ceiling for a single evaluation, after which the engine interrupts
  /// the script by itself.
  final Duration hardTimeout;

  IsolateQjs? _engine;
  bool _disposed = false;

  @override
  Future<void> start() async {
    if (_engine != null) return;
    if (_disposed) {
      throw const JsEvalException('This JavaScript context has been disposed');
    }
    final engine = IsolateQjs(
      memoryLimit: memoryLimit,
      timeout: hardTimeout.inMilliseconds,
      hostPromiseRejectionHandler: (reason) {
        // A promise nobody awaited is a plugin bug, not a crash: the call that
        // would have consumed it has already timed out or returned.
        AppLog.warn('Unhandled promise rejection in a plugin: $reason');
      },
    );
    _engine = engine;
    // Force the isolate up now, so a host without a usable engine fails at
    // `start()` with a clear error instead of inside the first plugin call.
    await evaluate('undefined');
  }

  @override
  Future<String?> evaluate(String script) async {
    final engine = _engine;
    if (engine == null || _disposed) {
      throw const JsEvalException('The JavaScript engine is not running');
    }
    try {
      final result = await engine.evaluate(script, name: 'aerostream');
      // The host protocol is string-in, string-out: every wrapper the host
      // evaluates (`__aeroPoll`, `JSON.stringify(...)`) already returns JSON
      // text. Anything else is encoded so the caller never sees a raw object.
      if (result == null) return 'null';
      if (result is String) return result;
      try {
        return jsonEncode(result);
      } on JsonUnsupportedObjectError {
        return result.toString();
      }
    } on JSError catch (error) {
      throw JsEvalException(
        error.message,
        stack: error.stack,
        isTimeout: error.message.toLowerCase().contains('interrupted'),
      );
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      await engine.close();
    } on Object {
      // The isolate is already gone (crash or timeout): nothing to release.
    }
  }
}
