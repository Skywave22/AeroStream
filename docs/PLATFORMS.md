# Platforms

AeroStream targets Android, iOS, macOS, Windows, Linux and the web, in that
order of priority. The repository ships only the Dart sources: platform runners
are generated, not committed, so they never drift from the Flutter version in
use.

```bash
./scripts/scaffold_platforms.sh    # adds android/ ios/ macos/ windows/ linux/ web/
flutter run -d <device>
```

CI runs the scaffold script before analyzing, which means every change is
compiled against all six targets, not just the one the developer had open.

## What runs where

| Capability | Android | iOS | macOS | Windows | Linux | Web |
| --- | --- | --- | --- | --- | --- | --- |
| Shell / navigation | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| SkyStream, Vega plugins | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| CloudStream plugins | ✅ | host absent | host absent | host absent | host absent | — |
| SQLite store | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| Filesystem artifacts | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| Video playback | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

Two things gate a feature per platform, and both are explicit:

* `PlatformProfile.supports(ecosystem)` — CloudStream needs a native host;
* `jsEngineFactoryProvider` — a build without a JavaScript engine gets
  `UnavailableJsRuntime`, which fails with a typed error and a message the UI
  can show ("JavaScript plugins cannot run on this platform").

The web target is a shell: browsers cannot host QuickJS's native bindings, and
file-backed storage has no analogue there. It is compiled so the UI stays
honest, but plugins are disabled.

## Storage locations

| Platform | `getApplicationSupportDirectory()` |
| --- | --- |
| Android | app-private files dir |
| iOS / macOS | `~/Library/Application Support/<bundle id>` |
| Windows | `%APPDATA%\<app>` |
| Linux | `~/.local/share/<app>` |

Layout: `aerostream.db` (repositories, installs), `plugins/`
(`<ecosystem>/<id>/<version>/`). Uninstalling a plugin deletes its directory;
the database row goes with it.

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

* Playback is libmpv through `media_kit`; the watch screen lists every source
  the plugins returned and hands the chosen one to `MediaKitPlaybackEngine`.
  A build without the native video libraries (tests) leaves
  `playerEngineProvider` null and the screen says so.
* The JavaScript engine is QuickJS, running on its own isolate per plugin
  (`lib/plugins/runtime/quickjs_engine.dart`, selected by
  `engine_factory.dart`). It is absent on web, where `dart:ffi` cannot exist
  and the browser gets `UnavailableJsRuntime`.
* CloudStream needs its Kotlin host side; the Dart half and the channel
  contract are done.
