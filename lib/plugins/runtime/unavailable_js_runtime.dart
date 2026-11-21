import 'js_runtime.dart';

/// Stands in for the JavaScript engine where none can run.
///
/// AeroStream's engine is provided per platform (QuickJS on Android, iOS,
/// macOS, Windows and Linux). Where it is missing — web, or a build that left
/// it out — plugins fail with a clear, typed error instead of a crash, and the
/// UI shows "JavaScript plugins cannot run on this platform".
final class UnavailableJsRuntime implements JsRuntime {
  UnavailableJsRuntime(
      {this.reason = 'The JavaScript engine is not available'});

  final String reason;

  @override
  Future<void> start() async => throw JsEvalException(reason, isTimeout: false);

  @override
  Future<String?> evaluate(String script) async =>
      throw JsEvalException(reason);

  @override
  Future<void> dispose() async {}
}
