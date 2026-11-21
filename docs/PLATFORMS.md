# Platforms

AeroStream targets Android, iOS, macOS, Windows and Linux, in that order of
priority. The repository ships only the Dart sources: platform runners are
generated, not committed, so they never drift from the Flutter version in use.

```bash
./scripts/scaffold_platforms.sh    # adds android/ ios/ macos/ windows/ linux/
flutter run -d <device>
```

CI runs the same script before analyzing, so the analyzer and the tests always
see a complete project rather than a bare `lib/`.

## What runs where

| Capability | Android | iOS | macOS | Windows | Linux |
| --- | --- | --- | --- | --- | --- |
| Shell / navigation | ✅ | ✅ | ✅ | ✅ | ✅ |
| SkyStream, Vega plugins | ✅ | ✅ | ✅ | ✅ | ✅ |
| CloudStream plugins | DEX in-process | OpenJDK Zero | JVM sidecar | JVM sidecar | JVM sidecar |
| SQLite store | ✅ | ✅ | ✅ | ✅ | ✅ |
| Filesystem artifacts | ✅ | ✅ | ✅ | ✅ | ✅ |
| Video playback (libVLC default / libmpv secondary) | ✅ | ✅ | ✅ | ✅ | ✅ |

There is no web target. The app reads with `dart:io`, runs plugins through
`dart:ffi`, and plays video through libmpv; a browser build would be a shell
that cannot do any of the three. `scripts/scaffold_platforms.sh` therefore does
not generate one, and `PlatformProfile` reports web as "no ecosystem runs" if it
is ever built that way.

### CloudStream is one protocol over platform-specific hosts

`.cs3` extensions are Kotlin/DEX compiled against CloudStream's library. They
arrive either as a raw DEX or, when they carry Android resources, as a ZIP with
`classes.dex`, `resources.arsc` and compiled `res/*`. `packages/cs3_engine`,
vendored from SkyStream, makes both forms runnable on every native target:

| Target | Execution model |
| --- | --- |
| Android | DEX loaded directly in the app process |
| Linux / Windows / macOS | DEX converted to JVM classes and run in a Java sidecar |
| iOS | converted classes run in an embedded OpenJDK Zero VM without JIT |

All three transports speak the engine's JSON protocol. `Cs3EngineBridge` starts
it lazily and `isAvailable()` calls `hello`; `ecosystemStatuses()` reports
CloudStream as runnable only after that answer. A failed embedded host, broken
Java runtime or packaging error is shown as an engine-start failure rather than
an incorrect "Android only" badge. Web is the sole platform-class exclusion.

Desktop release jobs run `packages/cs3_engine/tool/build_runtime.dart` with a
platform JDK 21. The resulting trimmed runtime is bundled as a package asset and
unpacked on first use, so end users do not need Java. Without that build asset,
the engine deliberately falls back to Java 17+ from `JAVA_HOME`, Android Studio
or `PATH` for developer builds.

Android's generated runner is adapted by `scripts/scaffold_platforms.sh`: its
`Application` is `ExtensionHostApplication`, and its activity extends
CloudStream's `MainActivity` while hosting Flutter in a `FlutterFragment`. This
is required because real extensions cast their context to those CloudStream
classes.

The JavaScript ecosystems are gated the same way: `jsEngineFactoryProvider`
supplies QuickJS, and a build without it gets `UnavailableJsRuntime`, which
fails with a typed error the UI can render.

### Cleartext HTTP

Plugin sources choose their own URLs, and a fair number are still plain `http`.
Android and the Apple platforms refuse cleartext by default, which would turn
"this plugin's API is not https" into an unexplained playback failure. The
scaffold script opts in — `android:usesCleartextTraffic="true"` and an
`NSAppTransportSecurity` exception — the same way CloudStream does.

The app's own `NetworkPolicy` still decides which hosts a plugin may reach, and
it blocks private and link-local addresses regardless of scheme.

## Storage locations

| Platform | `getApplicationSupportDirectory()` |
| --- | --- |
| Android | app-private files dir |
| iOS / macOS | `~/Library/Application Support/<bundle id>` |
| Windows | `%APPDATA%\<app>` |
| Linux | `~/.local/share/<app>` |

Layout: `aerostream.db` (repositories, installs), `plugins/`
(`<ecosystem>/<id>/<version>/`). Uninstalling a plugin deletes its directory and
the database row.

## Desktop and TV notes

* **Keyboard and D-pad.** Every navigation control is a focusable Material
  widget; the shell is a bottom bar under 720 px wide and a rail above it, with
  labels above 1200 px.
* **Window sizing.** The layout is responsive rather than fixed: grids compute
  their column count from the available width, the hero row caps at five cards.
* **Text scaling** is clamped to 0.85–1.6 so a large system font cannot break a
  row of posters.

## Building for release

```bash
flutter build apk --release --split-per-abi
flutter build ios --release
flutter build macos --release
flutter build windows --release
flutter build linux --release
```

Signing keys, provisioning profiles and store metadata are deliberately not in
this repository.

## Known gaps

* **CI builds all five platform artifacts, but only Android and Linux run on
  every branch.** A green compiler run is still not proof that a particular
  user-supplied extension completes discovery, extraction and playback on a
  physical device.
* **CloudStream browser and extension-UI events need an AeroStream surface.**
  The engine and content calls are integrated; extensions that require an
  interactive challenge or their own settings window can still fail loudly
  rather than hang silently.
* **DRM is informational only.** DRM links remain in the source list and are
  labelled unsupported; neither internal player attempts them.
* **The JavaScript engine is QuickJS** on its own isolate per plugin
  (`lib/plugins/runtime/quickjs_engine.dart`, selected by `engine_factory.dart`).
