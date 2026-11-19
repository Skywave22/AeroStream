# AeroStream

A cross-platform media client **runtime**. AeroStream ships with no content of
its own — every catalogue, search result, episode list and video link comes
from a plugin that the user installs from a repository they choose.

It runs three plugin ecosystems behind one unified interface:

| Ecosystem | Artifact | Runtime | Platforms |
| --- | --- | --- | --- |
| **SkyStream** | `.sky` (zip: `plugin.json` + `plugin.js`) | Sandboxed JavaScript | all |
| **Vega** | provider modules (`posts.js`, `stream.js`, …) | Sandboxed JavaScript | all |
| **CloudStream** | `.cs3` (Kotlin/DEX) | Native Kotlin host (`DexClassLoader`) | Android |

## Status

| Phase | Scope | State |
| --- | --- | --- |
| 0 | Project foundation, CI | done |
| 1 | Unified domain model + plugin abstraction | done |
| 2 | Extension / repository manager | done |
| 3 | JavaScript runtime + host API bridge | done |
| 4 | SkyStream adapter | done |
| 5 | Vega adapter | done |
| 6 | CloudStream adapter (Android host) | done — Kotlin host pending |
| 7 | Adaptive UI/UX | done |
| 8 | Player | done — source selection, libmpv playback, subtitles |
| 9 | Library, history, downloads | done — saved titles, continue watching, resume, off-line downloads |
| 10 | Settings, security, privacy | settings and persisted theme done |
| 11 | Platform polish | planned |
| 12 | Testing, performance, release | in progress |

Plugins run on QuickJS, one isolate per plugin, behind a bridge that only
exposes HTTP, HTML parsing, hashing, base64 and namespaced storage. Playback is
libmpv through `media_kit`, behind a `PlaybackEngine` seam so a build without
the native libraries reports that instead of showing a black rectangle.
Progress is recorded as you watch, so "Continue watching" and the resume point
in the player survive closing the app.

See `docs/ARCHITECTURE.md` for the layer map, `docs/PLUGIN_SPEC.md` for the
verified on-the-wire formats of all three ecosystems, and `docs/PLATFORMS.md`
for per-target build notes.

## Quick start

```bash
flutter pub get
./scripts/scaffold_platforms.sh   # one-off: adds ios/macos/windows/linux runners
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
tool/           js_selftest.mjs — runs the real JS in a Node VM
docs/           architecture, plugin spec, platforms, disclaimer
```

The JavaScript tests run without Flutter:

```bash
node tool/js_selftest.mjs
```

## Legal

AeroStream is a client. It hosts nothing, indexes nothing and bundles nothing.
Plugins and the sites they read are third-party, user-chosen and the user's
responsibility. See `docs/DISCLAIMER.md`.
