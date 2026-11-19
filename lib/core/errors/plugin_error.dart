/// Typed failures shared by every plugin ecosystem.
///
/// The taxonomy is deliberately small and UI-addressable: each kind maps to a
/// distinct recovery action (retry, change settings, install on another
/// platform, report a broken plugin).
sealed class PluginError implements Exception {
  const PluginError(
    this.message, {
    this.pluginId,
    this.cause,
    this.stackTrace,
  });

  /// Technical detail, for logs and the debug console.
  final String message;

  /// Which plugin was running, when that is known.
  final String? pluginId;

  /// Underlying exception or payload, kept for the debug console only.
  final Object? cause;

  final StackTrace? stackTrace;

  /// Stable machine-readable kind, used for filtering logs and for tests.
  String get kind;

  /// One sentence the UI can show without leaking internals.
  String get userMessage;

  /// Whether retrying the exact same call could succeed.
  bool get isRetryable => false;

  PluginError copyWithPlugin(String? id) => this;

  @override
  String toString() {
    final buffer = StringBuffer(kind);
    if (pluginId != null) buffer.write('[$pluginId]');
    buffer.write(': $message');
    if (cause != null) buffer.write(' (cause: $cause)');
    return buffer.toString();
  }
}

/// The plugin exceeded its execution budget and was killed.
final class PluginTimeoutError extends PluginError {
  const PluginTimeoutError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
    this.timeout,
  });

  final Duration? timeout;

  @override
  String get kind => 'timeout';

  @override
  String get userMessage => 'The plugin took too long to answer.';

  @override
  bool get isRetryable => true;

  @override
  PluginError copyWithPlugin(String? id) => PluginTimeoutError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
    timeout: timeout,
  );
}

/// The plugin answered, but not in a shape the adapter can understand.
final class PluginParseError extends PluginError {
  const PluginParseError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
    this.field,
  });

  /// The payload path that failed to parse, when known.
  final String? field;

  @override
  String get kind => 'parse';

  @override
  String get userMessage => 'The plugin returned data AeroStream could not read.';

  @override
  PluginError copyWithPlugin(String? id) => PluginParseError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
    field: field,
  );
}

/// A request the plugin made (or AeroStream made for it) failed on the wire.
final class PluginNetworkError extends PluginError {
  const PluginNetworkError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
    this.statusCode,
    this.url,
  });

  final int? statusCode;
  final String? url;

  @override
  String get kind => 'network';

  @override
  String get userMessage => 'The source could not be reached.';

  @override
  bool get isRetryable => true;

  @override
  PluginError copyWithPlugin(String? id) => PluginNetworkError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
    statusCode: statusCode,
    url: url,
  );
}

/// The plugin tried to do something the sandbox does not allow.
final class PluginSandboxError extends PluginError {
  const PluginSandboxError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
    this.violation,
  });

  /// e.g. `network-domain`, `memory`, `filesystem`.
  final String? violation;

  @override
  String get kind => 'sandbox';

  @override
  String get userMessage => 'The plugin tried to leave its sandbox.';

  @override
  PluginError copyWithPlugin(String? id) => PluginSandboxError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
    violation: violation,
  );
}

/// The plugin does not support the requested operation.
final class PluginUnsupportedError extends PluginError {
  const PluginUnsupportedError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
    this.operation,
  });

  final String? operation;

  @override
  String get kind => 'unsupported';

  @override
  String get userMessage => 'This plugin does not support that.';

  @override
  PluginError copyWithPlugin(String? id) => PluginUnsupportedError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
    operation: operation,
  );
}

/// The plugin runtime died (an uncaught error, a killed isolate, a crash).
final class PluginCrashError extends PluginError {
  const PluginCrashError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
    this.restarted = false,
  });

  /// Whether the host already restarted the runtime after the crash.
  final bool restarted;

  @override
  String get kind => 'crash';

  @override
  String get userMessage => 'The plugin stopped unexpectedly.';

  @override
  bool get isRetryable => true;

  @override
  PluginError copyWithPlugin(String? id) => PluginCrashError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
    restarted: restarted,
  );
}

/// The plugin (or repository) is not installed.
final class PluginNotFoundError extends PluginError {
  const PluginNotFoundError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
  });

  @override
  String get kind => 'not-found';

  @override
  String get userMessage => 'That plugin is not installed.';

  @override
  PluginError copyWithPlugin(String? id) => PluginNotFoundError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
  );
}

/// The user (or a policy) denied the operation.
final class PluginPermissionError extends PluginError {
  const PluginPermissionError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
    this.permission,
  });

  final String? permission;

  @override
  String get kind => 'permission';

  @override
  String get userMessage => 'A permission is required for that.';

  @override
  PluginError copyWithPlugin(String? id) => PluginPermissionError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
    permission: permission,
  );
}

/// The operation was cancelled, usually because the user navigated away.
final class PluginCancelledError extends PluginError {
  const PluginCancelledError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
  });

  @override
  String get kind => 'cancelled';

  @override
  String get userMessage => 'Cancelled.';

  @override
  PluginError copyWithPlugin(String? id) => PluginCancelledError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
  );
}

/// Anything that does not fit above. Never used for control flow.
final class PluginUnknownError extends PluginError {
  const PluginUnknownError(
    super.message, {
    super.pluginId,
    super.cause,
    super.stackTrace,
  });

  @override
  String get kind => 'unknown';

  @override
  String get userMessage => 'Something went wrong inside the plugin.';

  @override
  PluginError copyWithPlugin(String? id) => PluginUnknownError(
    message,
    pluginId: id,
    cause: cause,
    stackTrace: stackTrace,
  );
}
