import 'dart:convert';

import 'package:flutter_qjs_next/flutter_qjs.dart';

import 'js_runtime.dart';

/// [JsRuntime] over QuickJS.
///
/// The engine is deliberately thin. Everything AeroStream needs from
/// JavaScript — the bridge, timers, promises, the module registries — is
/// implemented in `assets/js/*.js` and evaluated into this context, so moving
/// to a different engine means writing another class this small, not porting a
/// protocol.
///
/// The context is created with **no web APIs installed**: no `fetch`, no
/// `console`, no timers from the package. Every one of those is defined by the
/// host bootstrap instead, which is what makes "the whole privileged surface is
/// in one file" true. The engine contributes ECMAScript, a heap ceiling and an
/// interrupt.
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

  JavascriptRuntime? _engine;
  bool _disposed = false;

  @override
  Future<void> start() async {
    if (_engine != null) return;
    if (_disposed) {
      throw const JsEvalException('This JavaScript context has been disposed');
    }
    final engine = getJavascriptRuntime(
      memoryLimit: memoryLimit,
      // Milliseconds of wall-clock JS work before the engine interrupts.
      timeout: hardTimeout.inMilliseconds,
      webApis: const JsWebApis.none(),
    );
    _engine = engine;
    // Force the context up now, so a host without a usable engine fails at
    // `start()` with a clear error instead of inside the first plugin call.
    await evaluate('undefined');
  }

  @override
  Future<String?> evaluate(String script) async {
    final engine = _engine;
    if (engine == null || _disposed) {
      throw const JsEvalException('The JavaScript engine is not running');
    }

    final JsEvalResult result;
    try {
      result = engine.evaluate(script, sourceUrl: 'aerostream');
      // Plugin code is asynchronous: an `await` continues on a microtask, and
      // QuickJS only runs jobs when asked. Draining here is what lets a poll
      // observe progress made by a promise that resolved during the last step.
      engine.executePendingJobs();
    } on JsEvalException {
      rethrow;
    } on Object catch (error) {
      // The package throws its own error type for engine-level failures; the
      // contract above only exposes [JsEvalException].
      final message = error is JSError ? error.message : error.toString();
      throw JsEvalException(
        message,
        isTimeout: message.toLowerCase().contains('interrupt'),
      );
    }

    if (result.isError) {
      final error = result.rawResult;
      final message = error is JSError ? error.message : result.stringResult;
      throw JsEvalException(
        message,
        stack: error is JSError ? error.stack : null,
        isTimeout: message.toLowerCase().contains('interrupt'),
      );
    }

    // The host protocol is string-in, string-out: every wrapper the host
    // evaluates (`__aeroPoll`, `JSON.stringify(...)`) already returns JSON
    // text. Anything else is encoded so the caller never sees a raw object.
    final value = result.rawResult;
    if (value == null) return 'null';
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } on JsonUnsupportedObjectError {
      return value.toString();
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      engine.dispose();
    } on Object {
      // The context is already gone (crash or interrupt): nothing to release.
    }
  }
}
