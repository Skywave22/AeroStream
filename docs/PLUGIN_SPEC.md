# Plugin specification

AeroStream runs three ecosystems. All three are documented here as they exist on
the wire today, verified against live repositories — not as anyone wishes they
were.

A repository always answers with the same outer manifest:

```json
{
  "name": "Example Repo",
  "description": "…",
  "iconUrl": "https://…/icon.png",
  "manifestVersion": 1,
  "pluginLists": ["https://…/plugins.json"]
}
```

`pluginLists` may be relative; entries are resolved against the manifest URL.
Some repositories also publish `includedRepos` (CloudStream mega-repos), which
AeroStream follows one level deep.

What a plugin *is* depends on what a plugin-list entry points at: a `.sky` zip,
a directory of Vega modules, or a `.cs3` file. That decides the ecosystem.

---

## SkyStream

**Artifact:** `.sky` — a zip containing `plugin.json` and `plugin.js`.

```json
{
  "packageName": "com.example.plugin",
  "name": "Example",
  "version": 3,
  "baseUrl": "https://example.com",
  "description": "…",
  "authors": ["…"],
  "languages": ["en"],
  "categories": ["Movies"],
  "settings": [{"key": "quality", "title": "Quality"}],
  "domains": ["example.com"]
}
```

`version` is an integer, not a semver string. `packageName` must match the id
the repository listed; a mismatch is a parse error and the install is rejected.

`plugin.js` runs with these globals available:

| Global | Signature | Returns |
| --- | --- | --- |
| `getHome` | `(callback)` | `{categoryName: [MultimediaItem]}` |
| `search` | `(query, page, callback)` | `{success, data: [MultimediaItem]}` |
| `load` | `(url, callback)` | item with `episodes` / `streams` |
| `loadStreams` | `(url, callback)` | `{success, data: [Stream]} ` |

Callbacks receive `{success, data}`. A category named `Trending` is rendered as
the hero carousel. `type` is one of `movie`, `series`, `anime`, `livestream`.

Helpers the bootstrap provides to plugin code:

* `sendMessage(channel, payload)` — the only way out of the sandbox (see
  `ARCHITECTURE.md` for the channel table);
* `manifest` — the parsed `plugin.json`;
* `console`, `setTimeout`/`setInterval`/`clearTimeout`, `URL`,
  `URLSearchParams`, `TextEncoder`/`TextDecoder`, `btoa`/`atob`;
* Promises and `async`/`await` work: a function that returns a value instead of
  calling its callback is settled immediately.

---

## Vega

**Artifact:** a provider bundle. The repository publishes the provider array
itself, so adding it needs no separate manifest:

```json
[
  {
    "display_name": "Example",
    "value": "example",
    "version": "1.0",
    "icon": "https://…/icon.png",
    "type": "global",
    "hasSettings": false,
    "disabled": false
  }
]
```

Modules live under `dist/<value>/` and are CommonJS:

| Module | Functions AeroStream calls |
| --- | --- |
| `posts.js` | `getPosts({filter, page, providerValue})`, `getSearchPosts({searchQuery, page, providerValue})` |
| `meta.js` | `getMeta({link, providerValue})` |
| `stream.js` | `getStream({link, type, isDownload, providerValue})` |
| `catalog.js`, `settings.js`, `headers.js` | optional; loaded when present |

Each module must export the function it is called for. AeroStream checks with
`__vegaHas(module, fn)` before calling `__vegaCall(module, fn, optionsJson)`,
and a provider that lacks a module simply does not offer that capability.

Stream objects are `{server, link, type, quality}`; `type` is mapped as
`m3u8`/`hls` → HLS, `mpd`/`dash` → DASH, anything else → progressive.
Subtitles are `{url, language?, label?}`.

Vega providers expect an axios-like HTTP client and a Node-ish `crypto`; the
bootstrap supplies both (`axios` over `http:get`/`http:post`, `crypto` over
`crypto:md5`/`crypto:sha256`/`crypto:hmac`), plus `cheerio` via
`assets/js/cheerio_lite.js`.

---

## CloudStream

**Artifact:** `.cs3` — a DEX container with Kotlin code compiled against the
CloudStream library. It cannot run in a JavaScript engine.

Repository entries look like:

```json
{
  "url": "https://…/plugin.cs3",
  "status": 1,
  "version": 12,
  "name": "Example",
  "internalName": "ExampleProvider",
  "authors": ["…"],
  "description": "…",
  "fileSize": 123456,
  "repositoryUrl": "https://…",
  "language": "en",
  "tvTypes": ["Movie"],
  "iconUrl": "https://…",
  "apiVersion": 1,
  "fileHash": "sha256-<hex>"
}
```

`status` other than `1` means broken/disabled. `fileHash` is verified on install
when present. `apiVersion` must be `1`.

### The host contract

On Android a native host loads the `.cs3` with a `DexClassLoader`, provides the
CloudStream API surface the extension links against, and answers over the
`dev.aerostream/cloudstream` method channel. Everything crossing that boundary
is JSON, so the host can add fields without breaking the app.

| Command | Arguments | Reply |
| --- | --- | --- |
| `handshake` | — | `true` when the host is ready |
| `loadPlugin` | `{pluginPath, pluginId}` | `{providers: ["…"]}` |
| `getMainPage` | — | `{sections: [{name, items}]}` |
| `search` | `{query}` | `{items: […]}` |
| `load` | `{url}` | `{item, episodes: [{name, url, season, episode, data}]}` |
| `loadLinks` | `{url, data}` | `{links: [{url, name, quality, headers, isM3u8, extractor}], subtitles: […]}` |
| `unloadPlugin` | `{pluginId}` | — |

`MissingPluginException` means "this build has no CloudStream host": the
extension stays visible, is marked as unavailable on this platform, and cannot
be installed. Nothing crashes.

Because the host is Kotlin, CloudStream extensions are gated on
`PlatformProfile.supports(PluginEcosystem.cloudstream)` — on every platform
where a host exists (`cs3_engine` on Android, and the same protocol elsewhere)
the adapter is identical; where none exists the ecosystem is simply absent.

---

## Install and update rules

1. The artifact is downloaded with a size cap and, when the listing carries
   `fileHash`, verified before anything is written.
2. Files are staged in a sibling directory and swapped in with `rename`.
3. The previous version's path is recorded for one-step rollback.
4. A plugin whose manifest id disagrees with the listing is rejected.
5. Disabling a plugin keeps its files; uninstalling removes them and leaves
   library entries intact, marked unavailable.

## Sandbox rules

Plugin code can: make HTTP requests to public hosts, parse HTML host-side, hash
and base64, and read/write its own settings namespace. Plugin code cannot:
reach the filesystem, spawn processes, read another plugin's settings, open
sockets, or call any host channel not in the table above.
