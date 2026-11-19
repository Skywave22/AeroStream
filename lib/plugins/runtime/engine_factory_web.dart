import 'js_runtime.dart';
import 'unavailable_js_runtime.dart';

/// The web has no QuickJS: browsers cannot host the native bindings.
///
/// Everything else still works — the shell, the library, repository management —
/// and a plugin that needs JavaScript reports why it cannot run instead of
/// failing silently.
JsRuntime Function() createPlatformEngineFactory() =>
    () => UnavailableJsRuntime(
      reason: 'JavaScript plugins cannot run in a browser',
    );
