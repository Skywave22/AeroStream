import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// One recorded log line, for the in-app debug console.
@immutable
final class LogEntry {
  const LogEntry({
    required this.at,
    required this.level,
    required this.message,
    this.pluginId,
    this.detail,
  });

  final DateTime at;
  final String level;
  final String message;
  final String? pluginId;
  final String? detail;

  String get formatted {
    final stamp = at.toIso8601String().substring(11, 23);
    final scope = pluginId == null ? '' : '[$pluginId] ';
    return '$stamp ${level.toUpperCase().padRight(5)} $scope$message';
  }
}

/// Application logging.
///
/// Two sinks: the platform console (via `logger`) and a bounded in-memory ring
/// buffer that the developer-mode debug console renders. Plugin output is
/// namespaced by plugin id, so a noisy plugin cannot drown the app's logs.
final class AppLog {
  AppLog._();

  static const int _capacity = 500;

  static final Logger _logger = Logger(
    filter: kReleaseMode ? ProductionFilter() : DevelopmentFilter(),
    printer: SimplePrinter(printTime: true, colors: false),
  );

  static final ListQueue<LogEntry> _buffer = ListQueue<LogEntry>();
  static final StreamController<LogEntry> _entries =
      StreamController<LogEntry>.broadcast();
  static final Map<String, ListQueue<LogEntry>> _pluginBuffers =
      <String, ListQueue<LogEntry>>{};

  /// Every log line, oldest first, capped at 500 entries.
  static List<LogEntry> get history => List<LogEntry>.unmodifiable(_buffer);

  /// Fires for each new line; the debug console listens to this.
  static Stream<LogEntry> get stream => _entries.stream;

  /// Log lines emitted by one plugin.
  static List<LogEntry> pluginHistory(String pluginId) =>
      List<LogEntry>.unmodifiable(_pluginBuffers[pluginId] ?? <LogEntry>[]);

  static void debug(String message, {String? pluginId}) =>
      _write('debug', message, pluginId: pluginId);

  static void info(String message, {String? pluginId}) =>
      _write('info', message, pluginId: pluginId);

  static void warn(String message, {String? pluginId, Object? detail}) =>
      _write('warn', message, pluginId: pluginId, detail: detail);

  static void error(
    String message, {
    String? pluginId,
    Object? detail,
    StackTrace? stackTrace,
  }) =>
      _write(
        'error',
        message,
        pluginId: pluginId,
        detail: detail,
        stackTrace: stackTrace,
      );

  /// Records a plugin's own `console.log` output.
  static void pluginLog(String pluginId, String message, {String? level}) =>
      _write(level ?? 'info', message, pluginId: pluginId);

  static void _write(
    String level,
    String message, {
    String? pluginId,
    Object? detail,
    StackTrace? stackTrace,
  }) {
    final entry = LogEntry(
      at: DateTime.now(),
      level: level,
      message: message,
      pluginId: pluginId,
      detail: detail?.toString(),
    );

    _buffer.addLast(entry);
    if (_buffer.length > _capacity) _buffer.removeFirst();

    if (pluginId != null) {
      final pluginBuffer = _pluginBuffers.putIfAbsent(
        pluginId,
        ListQueue<LogEntry>.new,
      );
      pluginBuffer.addLast(entry);
      if (pluginBuffer.length > _capacity) pluginBuffer.removeFirst();
    }

    if (!_entries.isClosed) _entries.add(entry);

    final line = entry.formatted;
    switch (level) {
      case 'error':
        _logger.e(line, stackTrace: stackTrace);
      case 'warn':
        _logger.w(line);
      case 'debug':
        _logger.d(line);
      default:
        _logger.i(line);
    }
  }

  /// Clears the buffers (used by "clear logs" in developer mode).
  static void clear() {
    _buffer.clear();
    _pluginBuffers.clear();
  }

  static Future<void> dispose() async {
    await _entries.close();
  }
}
