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
| CloudStream plugins | host dependent | — | — | — | — |
| SQLite store | ✅ | ✅ | ✅ | ✅ | ✅ |
| Filesystem artifacts | ✅ | ✅ | ✅ | ✅ | ✅ |
| Video playback (libmpv) | ✅ | ✅ | ✅ | ✅ | ✅ |

There is no web target. The app reads with `dart:io`, runs plugins through
`dart:ffi`, and plays video through libmpv; a browser build would be a shell
that cannot do any of the three. `scripts/scaffold_platforms.sh` therefore does
not generate one, and `PlatformProfile` reports web as "no ecosystem runs" if it
is ever built that way.

### CloudStream is a host question, not a platform question

`.cs3` extensions are Kotlin compiled against CloudStream's library. They need a
native host that loads the DEX and answers over the
`dev.aerostream/cloudstream` channel. Android is the only platform where that is
possible, and even there the host has to *be in the build*:

* the bridge is `null` when the platform is not Android, and
* when it is present, `isAvailable()` performs a handshake. A missing plugin, a
  platform error or a five-second timeout all mean "not available".

`ecosystemStatuses()` (`lib/core/platform/ecosystem_status.dart`) turns that into
the sentence the UI shows, and it distinguishes the two ways CloudStream can be
unavailable:

| Situation | What the app says |
| --- | --- |
| Not Android | *Android only: .cs3 extensions are Kotlin, loaded by the Android host* |
| Android, host absent | *The CloudStream host is not part of this build, so .cs3 extensions can be installed but not started* |
| Android, host answered | runs |

That matrix is shown in Settings › Platform, one row per ecosystem, and drives
the badge next to each plugin in Extensions. Installing a `.cs3` on a host-less
build stays allowed — the file is harmless and the reason is displayed — but the
plugin is never offered as playable.

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

* **No CI build per platform.** CI runs `flutter analyze` and `flutter test`,
  which is what catches type and logic errors; the platform runners are
  generated so the code is analyzed against a full project, but a release build
  for each target is a local step. A green run is not a guarantee that every
  native dependency links on every platform.
* **The CloudStream Kotlin host is not in this repository.** The Dart half, the
  channel contract and the support matrix are; Android builds without it report
  CloudStream as installable-but-unstartable.
* **Playback is libmpv through `media_kit`.** A build without the native video
  libraries (tests) leaves `playerEngineProvider` null and the watch screen says
  so.
* **The JavaScript engine is QuickJS** on its own isolate per plugin
  (`lib/plugins/runtime/quickjs_engine.dart`, selected by `engine_factory.dart`).
