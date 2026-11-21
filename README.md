# AeroStream

A cross-platform media client **runtime**. AeroStream ships with no content of
its own — every catalogue, search result, episode list and video link comes
from a plugin that the user installs from a repository they choose.

It runs three plugin ecosystems behind one unified interface:

| Ecosystem | Artifact | Runtime | Platforms |
| --- | --- | --- | --- |
| **SkyStream** | `.sky` (zip: `plugin.json` + `plugin.js`) | Sandboxed JavaScript | Android, iOS, desktop |
| **Vega** | provider modules (`posts.js`, `stream.js`, …) | Sandboxed JavaScript | Android, iOS, desktop |
| **CloudStream** | `.cs3` (raw DEX, or a ZIP with `classes.dex` and resources) | SkyStream `cs3_engine`: DEX in-process on Android, JVM sidecar on desktop, embedded OpenJDK Zero on iOS | Android, iOS, macOS, Windows, Linux |

Each ecosystem's availability is reported per device in Settings › Platform.
CloudStream is marked runnable only after the packaged engine answers its
`hello` handshake (see `docs/PLATFORMS.md`).

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Project foundation, CI | done |
| 1 | Unified domain model + plugin abstraction | done |
| 2 | Extension / repository manager | done |
| 3 | JavaScript runtime + host API bridge | done |
| 4 | SkyStream adapter | done |
| 5 | Vega adapter | done |
| 6 | CloudStream adapter + cross-platform engine | integrated — packaged-device verification ongoing |
| 7 | Adaptive UI/UX | done |
| 8 | Player | done — shared UI, libVLC default, libmpv secondary, subtitles and header proxy |
| 9 | Library, history, downloads | done — saved titles, continue watching, resume, off-line downloads |
| 10 | Settings, security, privacy | done — appearance, playback, platform matrix, data controls |
| 11 | Platform polish | done — support matrix, cleartext, generated runners |
| 12 | Testing, performance, release | done — five-platform builds published as release assets; store publishing not attempted (`docs/RELEASING.md`) |

The vendored `packages/cs3_engine` is SkyStream's GPLv3 CloudStream
compatibility engine pinned to commit `f5523ae07d729b579be30976df8783a0b98c4559`.
Its source, notices and license ship in-tree; see `packages/cs3_engine/ORIGIN.md`.
The remaining compatibility gaps are listed honestly in
`docs/PLUGIN_SPEC.md`, especially extension browser/UI events that still need
an AeroStream surface. CI also runs a packaged Linux executable through a real,
compiled, resource-bearing `.cs3`: repository discovery, installation, provider
registration, Home, search, details and `loadLinks`. That is not a substitute
for playback validation on physical devices.

JavaScript plugins run on QuickJS, one isolate per plugin, behind a bridge that
only exposes HTTP, HTML parsing, hashing, base64 and namespaced storage.
Playback uses two internal native engines behind one UI: libVLC is the default
and libmpv through `media_kit` is the secondary choice. No WebView is used as a
video player.
Progress is recorded as you watch, so "Continue watching" and the resume point
in the player survive closing the app.

Extensions are three sections, one per ecosystem, the way the ecosystems
themselves present them: **SkyStream Providers**, **CloudStream Extensions** and
**Vega Providers**, reachable from the Extensions tab and from
*Settings › Extensions*. Each has its own sources, its own add-repository box
(a SkyStream code is not a Vega author), and its own Installed / Browse pages;
a repository added in one section is filed by what it publishes, so sharing a
`plugins.json` link with a CloudStream user still works.

See `docs/ARCHITECTURE.md` for the layer map, `docs/PLUGIN_SPEC.md` for the
verified on-the-wire formats of all three ecosystems, and `docs/PLATFORMS.md`
for per-target build notes.

The formats are checked against the upstream projects rather than guessed:
[akashdh11/skystream](https://github.com/akashdh11/skystream) (plus
[skystream-tools](https://github.com/akashdh11/skystream-tools) for the plugin
manifest and CLI),
[recloudstream/cloudstream](https://github.com/recloudstream/cloudstream) (the
`Repository`/`SitePlugin` data classes and `RepositoryManager.parseRepoUrl`) and
[vega-org/vega-app](https://github.com/vega-org/vega-app) (`ExtensionManager`,
`helpers.ts`, `ProviderManager`). Where this app cannot do what they do — DRM,
the byte proxy or interactive browser challenges — it says so in
`PLUGIN_SPEC.md` under "Not implemented", and in the UI at the point of use.

## Download

Tagged releases carry builds for every supported platform — Android (arm64-v8a,
armeabi-v7a, x86_64 and universal APKs), Linux x64, Windows (portable zip and
installer), macOS and an unsigned iOS `.ipa`. They are unsigned and marked as
pre-releases: see `docs/BUILDING.md` for what that means and how to build your
own.

## Quick start

```bash
flutter pub get
./scripts/scaffold_platforms.sh   # one-off: adds the android/ios/macos/windows/linux runners
flutter run -d <device>
flutter analyze --fatal-infos
flutter test
```

## Repo layout

```
assets/js/      host bootstrap, cheerio-lite, Vega compatibility layer
lib/core/       Result, typed plugin errors, network policy, JSON readers
lib/domain/     entities, MediaProvider, CatalogService
lib/plugins/    runtime (sandbox), adapters (3 ecosystems), managers, parsers
lib/data/       SQLite store, filesystem artifacts, preferences
lib/features/   screens: home, search, details, player, library, extensions…
packages/       vendored libVLC player and cross-platform cs3_engine
tool/           js_selftest.mjs — runs the real JS in a Node VM
docs/           architecture, plugin spec, platforms, building, releasing, disclaimer
```

The JavaScript tests run without Flutter:

```bash
node tool/js_selftest.mjs
```

## Legal

AeroStream is a client. It hosts, indexes and bundles no media or content
plugins. Plugins and the sites they read are third-party, user-chosen and the user's
responsibility. See `docs/DISCLAIMER.md`.
