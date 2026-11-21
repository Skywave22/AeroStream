import 'js_runtime.dart';
import 'quickjs_engine.dart';

/// The engine every plugin gets on platforms that can host QuickJS.
///
/// One isolate per plugin, created lazily by the runtime factory: plugins must
/// not share a context, because a context is the unit the sandbox budgets and
/// kills.
JsRuntime Function() createPlatformEngineFactory() => QuickJsRuntime.new;
