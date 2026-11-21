/// The execution limits applied to one plugin context.
final class RuntimeLimits {
  const RuntimeLimits({
    this.callTimeout = const Duration(seconds: 60),
    this.evaluationTimeout = const Duration(seconds: 3),
    this.memoryBytes = 64 * 1024 * 1024,
    this.maxHostCallsPerInvocation = 250,
    this.maxHttpRequestsPerInvocation = 120,
    this.pollInterval = const Duration(milliseconds: 2),
    this.maxTimerDelay = const Duration(seconds: 10),
  });

  /// Wall-clock budget for one plugin call (`getHome`, `loadLinks`, …).
  ///
  /// Generous on purpose: a home screen is often four API pages fetched one
  /// after another, and SkyStream plugins delay between pages to stay polite.
  /// 25s cut that off mid-way and reported a timeout that looked like a bug in
  /// the plugin.
  final Duration callTimeout;

  /// Budget for one single script evaluation, so a hung expression cannot
  /// stall the pump loop.
  final Duration evaluationTimeout;

  /// QuickJS heap cap for the context.
  final int memoryBytes;

  /// Host calls one invocation may make, across all channels.
  final int maxHostCallsPerInvocation;

  /// Network requests one invocation may make.
  final int maxHttpRequestsPerInvocation;

  /// How long the pump waits before asking the plugin whether it is done.
  final Duration pollInterval;

  /// Longest `setTimeout` the host will honour.
  final Duration maxTimerDelay;

  RuntimeLimits copyWith({
    Duration? callTimeout,
    Duration? evaluationTimeout,
    int? memoryBytes,
    int? maxHostCallsPerInvocation,
    int? maxHttpRequestsPerInvocation,
    Duration? pollInterval,
    Duration? maxTimerDelay,
  }) =>
      RuntimeLimits(
        callTimeout: callTimeout ?? this.callTimeout,
        evaluationTimeout: evaluationTimeout ?? this.evaluationTimeout,
        memoryBytes: memoryBytes ?? this.memoryBytes,
        maxHostCallsPerInvocation:
            maxHostCallsPerInvocation ?? this.maxHostCallsPerInvocation,
        maxHttpRequestsPerInvocation:
            maxHttpRequestsPerInvocation ?? this.maxHttpRequestsPerInvocation,
        pollInterval: pollInterval ?? this.pollInterval,
        maxTimerDelay: maxTimerDelay ?? this.maxTimerDelay,
      );
}

/// A raw JavaScript engine context.
///
/// Deliberately tiny: the engine only has to evaluate a script and return the
/// value as text. Everything else — host functions, timeouts, killing a hung
/// context — lives in `JsPluginHost`, so engines can be swapped (QuickJS on
/// native, a fake in tests) without touching plugin logic.
abstract interface class JsRuntime {
  /// Creates the context and evaluates the bootstrap.
  Future<void> start();

  /// Evaluates [script] and returns its result as a string.
  ///
  /// `null` is returned for `undefined`/`null` results.
  Future<String?> evaluate(String script);

  /// Destroys the context. Safe to call when not started.
  Future<void> dispose();
}

/// Raised by an engine when a script throws or the context dies.
final class JsEvalException implements Exception {
  const JsEvalException(this.message, {this.stack, this.isTimeout = false});

  final String message;
  final String? stack;

  /// True when the engine interrupted the script because it ran too long.
  final bool isTimeout;

  @override
  String toString() => 'JsEvalException($message)';
}
