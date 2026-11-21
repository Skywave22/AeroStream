/// The app's own identity, in one place.
///
/// `pubspec.yaml` is the source of truth for the version (pub.dev, the store
/// listing and `flutter build --build-name` all read it from there), but the UI
/// must never hard-code a second copy that silently drifts after a release
/// bump. A test asserts these constants still match `pubspec.yaml`; if it goes
/// red, update the numbers here.
library;

/// `version:` in pubspec.yaml, without the build number.
const String appName = 'AeroStream';
const String appVersion = '0.2.0';

/// The `+N` part of `version:`.
const int appBuildNumber = 2;

/// What the About tile shows.
String get appVersionLabel => '$appVersion ($appBuildNumber)';
