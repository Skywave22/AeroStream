/// Picks the JavaScript engine for the current platform.
///
/// The conditional export is what keeps `dart:ffi` out of a web build: the
/// native engine is only ever compiled where it can exist.
library;

export 'engine_factory_io.dart'
    if (dart.library.js_interop) 'engine_factory_web.dart';
