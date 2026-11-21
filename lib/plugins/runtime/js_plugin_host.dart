import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import '../../core/errors/plugin_error.dart';
import '../../core/json/json_read.dart';
import '../../core/logging/app_log.dart';
import '../../core/result.dart';
import 'js_host_api.dart';
import 'js_runtime.dart';

/// One sandboxed plugin context.
///
/// The host owns the protocol: it starts the plugin, then pumps until the
/// plugin is done, servicing each host call the plugin queued. Because the
/// plugin never gets a socket, a timer or a filesystem handle, this loop is the
/// entire trust boundary — every budget below is enforced here, not in JS.
///
/// A plugin that hangs, floods the queue or throws is killed: its context is
/// destroyed and the next call starts a fresh one. That is the only reliable
/// way to stop a runaway `while (true) {}` on a single-threaded engine.
final class JsPluginHost {
  JsPluginHost({
    required JsRuntime runtime,
    required JsHostApi api,
    required this.pluginId,
    required this.bootstrap,
    this.pluginSource,
    this.manifestJson,
    this.prelude = const <String>[],
    this.limits = const RuntimeLimits(),
  })  : _runtime = runtime,
        _api = api;

  final JsRuntime _runtime;
  final JsHostApi _api;
  final String pluginId;

  /// The shared host bootstrap (`assets/js/host_bootstrap.js`).
  final String bootstrap;

  /// The plugin's own JavaScript.
  final String? pluginSource;

  /// The plugin manifest, injected as the `manifest` global.
  final String? manifestJson;

  /// Scripts evaluated after the bootstrap and before the plugin source.
  ///
  /// This is how a multi-module ecosystem (Vega) registers its provider
  /// modules before anything calls into them.
  final List<String> prelude;

  final RuntimeLimits limits;

  bool _started = false;
  int _generation = 0;

  static const String bootstrapAsset = 'assets/js/host_bootstrap.js';

  /// Loads the bootstrap that ships with the app.
  static Future<String> loadBootstrap([AssetBundle? bundle]) =>
      (bundle ?? rootBundle).loadString(bootstrapAsset);

  /// Invokes one plugin entry point and returns its JSON-decoded value.
  Future<Result<Object?>> call(
    String function, {
    List<Object?> args = const <Object?>[],
  }) async {
    final started = DateTime.now();
    final deadline = started.add(limits.callTimeout);

    try {
      await _ensureStarted();
      await _evaluate(
        '__aeroInvoke(${jsonEncode(function)}, '
        '${jsonEncode(jsonEncode(args))})',
      );
    } on JsEvalException catch (error) {
      return Err<Object?>(await _crash(error));
    }

    var hostCalls = 0;
    var httpCalls = 0;

    // Timers wait here rather than inside the loop: a plugin races its
    // requests against a timeout timer, and sleeping through that timer starved
    // the request it was guarding. `subdub` schedules a 25s timeout and then
    // fetches; the fetch only started after the host had idled for 10s, by
    // which time the plugin's own guard had expired and reported "timeout" for
    // a request that never ran.
    final pending = <_PendingTimer>[];

    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        return Err<Object?>(await _timeout());
      }
      await _fireDueTimers(pending);

      String? polled;
      try {
        polled = await _evaluate('__aeroPoll()');
      } on JsEvalException catch (error) {
        return Err<Object?>(await _crash(error));
      }
      await _drainLogs();

      if (polled == null || polled == 'null' || polled.isEmpty) {
        await Future<void>.delayed(_idleDelay(pending));
        continue;
      }

      Object? decoded;
      try {
        decoded = jsonDecode(polled);
      } on FormatException {
        continue;
      }
      if (decoded is! Map) continue;
      final message = readMap(decoded);

      if (readBool(message['done'])) {
        final error = message['error'];
        AppLog.debug(
          '$function answered in '
          '${DateTime.now().difference(started).inMilliseconds}ms',
          pluginId: pluginId,
        );
        if (error != null) return Err<Object?>(_pluginError(error));
        return Ok<Object?>(message['value']);
      }

      final call = JsHostCall(
        id: readString(message['id']) ?? '',
        channel: readString(message['channel']) ?? '',
        payload: readString(message['payload']) ?? 'null',
      );
      if (call.id.isEmpty) continue;

      hostCalls++;
      if (hostCalls > limits.maxHostCallsPerInvocation) {
        return Err<Object?>(
          await _sandbox(
            'Plugin made more than ${limits.maxHostCallsPerInvocation} '
            'host calls in one operation',
            violation: 'host-call-budget',
          ),
        );
      }

      if (call.channel == 'timer') {
        final delay = _timerDelay(call);
        AppLog.debug(
          'timer ${readInt(call.json['ms']) ?? 0}ms queued for '
          '${delay.inMilliseconds}ms',
          pluginId: pluginId,
        );
        pending.add(_PendingTimer(call, delay));
        continue;
      }

      if (call.channel.startsWith('http:')) {
        httpCalls++;
        if (httpCalls > limits.maxHttpRequestsPerInvocation) {
          return Err<Object?>(
            await _sandbox(
              'Plugin made more than '
              '${limits.maxHttpRequestsPerInvocation} requests in one operation',
              violation: 'request-budget',
            ),
          );
        }
      }

      final reply = await _api.handle(call);
      try {
        await _evaluate(
          '__aeroResolve(${jsonEncode(call.id)}, ${jsonEncode(reply.json)}, '
          '${reply.isError})',
        );
      } on JsEvalException catch (error) {
        return Err<Object?>(await _crash(error));
      }
    }
  }

  /// Evaluates an arbitrary expression in the plugin's context.
  ///
  /// Used by adapters for things the entry points do not cover (dynamic
  /// settings, capability probes).
  Future<Result<Object?>> evaluateExpression(String expression) async {
    try {
      await _ensureStarted();
      final raw = await _evaluate('JSON.stringify($expression)');
      if (raw == null || raw == 'null') return const Ok<Object?>(null);
      try {
        return Ok<Object?>(jsonDecode(raw));
      } on FormatException {
        return Ok<Object?>(raw);
      }
    } on JsEvalException catch (error) {
      return Err<Object?>(await _crash(error));
    }
  }

  /// True when the context answers a trivial evaluation.
  Future<bool> healthCheck() async {
    try {
      await _ensureStarted();
      return await _evaluate('1 + 1') == '2';
    } on JsEvalException {
      return false;
    }
  }

  /// Destroys the context and releases host resources.
  Future<void> dispose() async {
    _started = false;
    _generation++;
    _api.dispose();
    await _runtime.dispose();
  }

  // ---- internals ---------------------------------------------------------

  Future<void> _ensureStarted() async {
    if (_started) return;
    await _runtime.start();
    await _evaluate(bootstrap);

    for (final script in prelude) {
      await _evaluate(script);
    }

    final source = pluginSource;
    if (source != null) {
      final prefix = manifestJson == null
          ? 'var manifest = {};\n'
          : 'var manifest = $manifestJson;\n';
      await _evaluate('$prefix$source');
    }
    _started = true;
  }

  Future<String?> _evaluate(String script) async {
    try {
      return await _runtime.evaluate(script).timeout(limits.evaluationTimeout);
    } on TimeoutException {
      throw const JsEvalException(
        'Script evaluation timed out',
        isTimeout: true,
      );
    } on JsEvalException {
      rethrow;
    } on Object catch (error) {
      throw JsEvalException('$error');
    }
  }

  /// How long the host will wait for a timer the plugin scheduled.
  ///
  /// Capped so one long `setTimeout` cannot park a call for minutes, and never
  /// negative: plugins do pass `-1` (meaning "soon") by accident.
  Duration _timerDelay(JsHostCall call) {
    final requested = readInt(call.json['ms']) ?? 0;
    final cap = limits.maxTimerDelay.inMilliseconds;
    final bounded = requested < 0 ? 0 : (requested > cap ? cap : requested);
    return Duration(milliseconds: bounded);
  }

  /// Fires every pending timer whose deadline has passed.
  Future<void> _fireDueTimers(List<_PendingTimer> pending) async {
    if (pending.isEmpty) return;
    final now = DateTime.now();
    for (final timer in pending) {
      if (timer.fired || now.isBefore(timer.due)) continue;
      timer.fired = true;
      await _fireTimer(timer.call);
    }
  }

  /// How long an idle pass waits before polling again.
  ///
  /// Polling every 2ms is right while a plugin is working through host calls;
  /// it is pure heat while the only thing left is a 10s timer, so wait for the
  /// nearest deadline instead, capped so a hung call is still noticed quickly.
  Duration _idleDelay(List<_PendingTimer> pending) {
    var delay = limits.pollInterval;
    for (final timer in pending) {
      if (timer.fired) continue;
      final remaining = timer.due.difference(DateTime.now());
      if (remaining <= delay) continue;
      delay = remaining > const Duration(milliseconds: 50)
          ? const Duration(milliseconds: 50)
          : remaining;
    }
    return delay;
  }

  Future<void> _fireTimer(JsHostCall call) async {
    final timerId = readString(call.json['timerId']) ?? '';
    try {
      await _evaluate('__aeroFireTimer(${jsonEncode(timerId)})');
      await _evaluate(
        '__aeroResolve(${jsonEncode(call.id)}, "null", false)',
      );
    } on JsEvalException {
      // The context died while waiting; the next poll reports the crash.
    }
  }

  Future<void> _drainLogs() async {
    String? raw;
    try {
      raw = await _evaluate('__aeroDrainLogs()');
    } on JsEvalException {
      return;
    }
    if (raw == null || raw.isEmpty || raw == 'null') return;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! List) return;
    for (final entry in decoded) {
      final map = readMap(entry);
      final message = readString(map['message']);
      if (message == null) continue;
      AppLog.pluginLog(
        pluginId,
        message,
        level: readString(map['level']) ?? 'info',
      );
    }
  }

  PluginError _pluginError(Object? raw) {
    final map = readMap(raw);
    final message =
        readString(map['message']) ?? 'The plugin reported an error';
    final kind = readString(map['kind']);
    final stack = readString(map['stack']);
    if (kind == 'unsupported') {
      return PluginUnsupportedError(message, pluginId: pluginId);
    }
    return PluginUnknownError(
      message,
      pluginId: pluginId,
      cause: stack,
    );
  }

  Future<PluginError> _crash(JsEvalException error) async {
    await _kill();
    AppLog.error(
      'Plugin context died: ${error.message}',
      pluginId: pluginId,
      detail: error.stack,
    );
    if (error.isTimeout) {
      return PluginTimeoutError(
        error.message,
        pluginId: pluginId,
        timeout: limits.evaluationTimeout,
      );
    }
    return PluginCrashError(
      error.message,
      pluginId: pluginId,
      cause: error.stack,
      restarted: true,
    );
  }

  Future<PluginError> _timeout() async {
    await _kill();
    AppLog.warn(
      'Plugin call exceeded ${limits.callTimeout.inSeconds}s and was killed',
      pluginId: pluginId,
    );
    return PluginTimeoutError(
      'The plugin did not answer within ${limits.callTimeout.inSeconds}s',
      pluginId: pluginId,
      timeout: limits.callTimeout,
    );
  }

  Future<PluginError> _sandbox(
    String message, {
    required String violation,
  }) async {
    await _kill();
    AppLog.warn('Sandbox violation ($violation): $message', pluginId: pluginId);
    return PluginSandboxError(
      message,
      pluginId: pluginId,
      violation: violation,
    );
  }

  /// Tears the context down; the next call starts a fresh generation.
  Future<void> _kill() async {
    _started = false;
    _generation++;
    try {
      await _runtime.dispose();
    } on Object {
      // A dead engine cannot fail twice.
    }
  }

  /// Increments on every restart; used by tests and the debug console.
  int get generation => _generation;
}

/// A timer the plugin asked for, waiting for its deadline.
final class _PendingTimer {
  _PendingTimer(this.call, Duration delay) : due = DateTime.now().add(delay);

  final JsHostCall call;
  final DateTime due;
  bool fired = false;
}
