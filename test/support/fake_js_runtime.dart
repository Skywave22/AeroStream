import 'dart:async';

import 'package:aerostream/plugins/runtime/js_runtime.dart';

/// A [JsRuntime] that answers the host protocol from Dart.
///
/// The real engine is QuickJS; this fake reproduces the protocol the host
/// speaks (`__aeroInvoke`, `__aeroPoll`, `__aeroResolve`, …) so timeouts,
/// budgets and error mapping are tested without a native runtime.
final class ScriptedJsRuntime implements JsRuntime {
  ScriptedJsRuntime({this.onEvaluate});

  Future<String?> Function(String script)? onEvaluate;

  final List<String> scripts = <String>[];
  int starts = 0;
  int disposes = 0;
  bool started = false;

  /// Scripts that were evaluated, filtered by prefix.
  List<String> scriptsStartingWith(String prefix) =>
      scripts.where((script) => script.startsWith(prefix)).toList();

  @override
  Future<void> start() async {
    starts++;
    started = true;
  }

  @override
  Future<String?> evaluate(String script) async {
    if (!started) throw const JsEvalException('context is not running');
    scripts.add(script);
    return onEvaluate?.call(script);
  }

  @override
  Future<void> dispose() async {
    disposes++;
    started = false;
  }
}

/// A tiny scripted plugin: the host sees exactly what a real plugin would
/// produce, one poll at a time.
final class FakePlugin {
  FakePlugin({this.value, this.error, this.hostCalls = const <FakeHostCall>[]});

  /// What the plugin resolves with when it completes.
  final Object? value;

  /// What it rejects with, if anything.
  final FakeError? error;

  /// Host calls it makes before completing.
  final List<FakeHostCall> hostCalls;

  int _index = 0;
  final List<String> resolved = <String>[];
  final List<String> rejected = <String>[];
  final List<String> invocations = <String>[];

  /// Wire this into [ScriptedJsRuntime.onEvaluate].
  Future<String?> onEvaluate(String script) async {
    if (script.startsWith('__aeroInvoke(')) {
      invocations.add(script);
      return '{"started":true}';
    }
    if (script.startsWith('__aeroResolve(')) {
      if (script.contains(', true)')) {
        rejected.add(script);
      } else {
        resolved.add(script);
      }
      return '{"ok":true}';
    }
    if (script.startsWith('__aeroDrainLogs()')) {
      return '[]';
    }
    if (script.startsWith('__aeroFireTimer(')) {
      return '{"ok":true}';
    }
    if (script.startsWith('__aeroPoll()')) {
      if (_index < hostCalls.length) {
        return hostCalls[_index++].toJson();
      }
      if (_index == hostCalls.length) {
        _index++;
        if (error != null) {
          return '{"done":true,"error":${error!.toJson()}}';
        }
        final encoded = value == null ? 'null' : _encode(value);
        return '{"done":true,"value":$encoded}';
      }
      return 'null';
    }
    return null;
  }

  static String _encode(Object? value) {
    if (value is String) return '"$value"';
    return '$value';
  }
}

/// A host call the fake plugin makes.
final class FakeHostCall {
  const FakeHostCall({
    required this.channel,
    required this.payload,
    this.id = 'c1',
  });

  final String id;
  final String channel;
  final String payload;

  String toJson() =>
      '{"id":"$id","channel":"$channel","payload":${_quote(payload)}}';

  static String _quote(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// A plugin-side error object.
final class FakeError {
  const FakeError(this.message, {this.kind = 'plugin'});

  final String message;
  final String kind;

  String toJson() => '{"message":"$message","kind":"$kind"}';
}
