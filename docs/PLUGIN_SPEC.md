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

`manifestVersion` is a contract version, not a plugin version: a repository
that asks for one newer than this build understands is refused by name
("needs a newer AeroStream: it asks for manifest version 2"), the way
CloudStream refuses an incompatible repository, rather than being half-read
with unknown fields quietly dropped.

`pluginLists` may be relative; entries are resolved against the manifest URL.
CloudStream's own `Repository` data class is exactly these five fields
(`iconUrl`, `name`, `description`, `manifestVersion`, `pluginLists`) — there is
no `includedRepos` key in the format. AeroStream still follows a `repos` /
`includedRepos` array when a fork publishes one, but treats it as an extension,
not as part of the contract.

What a plugin *is* depends on what a plugin-list entry points at: a `.sky` zip,
a directory of Vega modules, or a `.cs3` file. That decides the ecosystem.

### Adding a source: what the box accepts

The three ecosystems do not agree on what belongs in "Add repository", and each
one's answer is its own convention:

| Input | Understood as |
| --- | --- |
| `https://…/repo.json` | a manifest (SkyStream, CloudStream) |
| `https://…/manifest.json`, or a folder on any host | a Vega source; `/manifest.json` is appended |
| `cloudstreamrepo://<rest>`, `https://cs.repo/?<rest>` | CloudStream deep link: the prefix is stripped |
| `abc123` | a `cutt.ly/abc123` shortcode (CloudStream, SkyStream); `!abc123` goes through `py.md` |
| `author`, `author@gl` (`@cb`, `@bb`, `@gh`) | a Vega author: `author/vega-providers` on that host |
| `https://github.com/<author>/<repo>[/tree/<branch>]` (also Codeberg, GitLab, Bitbucket, raw.githubusercontent) | a Vega source, canonicalised to its raw base |

A bare word is ambiguous (`author` could be a shortcode or a Vega author), so
resolution is a cascade: the redirect service is asked first, then the Vega
convention. Exactly one hop is followed and only http(s) targets are accepted —
a shortcode is not allowed to become a redirect-following primitive.

The token is tried twice: as typed, then lower-cased. Both redirect services
are case-sensitive and codes are minted in lower case, so `Universe` only
resolves because of the second attempt. `!code` skips the `cutt.ly` candidates.

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

Two further manifest keys exist and are handled:

* `domains` — mirrors, published either as strings or as `{name, url}` objects.
* `providers` — sub-providers of one JS bundle: `{id, name, baseUrl?}`.

Both are parsed into `PluginEndpoint`s at install and shown in Extensions ›
Installed › the tune button. Choosing one stores it per plugin
(`plugin.endpoint.<id>`) and the runtime injects `manifest.baseUrl` (mirror, or
a provider that declares a URL) and/or `manifest.providerId` (a provider
resolved at runtime), so plugin code never learns the user switched. Two
deliberate restrictions: **one endpoint is active at a time** (SkyStream can
enable several sub-providers at once; this app does not yet) and a mirror that
disappears in a new version silently falls back to the manifest default.

`plugin.js` runs with these globals available:

| Global | Signature | Returns |
| --- | --- | --- |
| `getHome` | `(callback)` | `{categoryName: [MultimediaItem]}` |
| `search` | `(query, page, callback)` | `{success, data: [MultimediaItem]}` |
| `load` | `(url, callback)` | item with `episodes` / `streams` |
| `loadStreams` | `(url, callback)` | `{success, data: [Stream]} ` |

Callbacks receive `{success, data}`. A `Stream` is
`{url, source?, quality?, headers?, subtitles?, drmKid?, licenseUrl?}` where
`quality` is a **number** (`1080`) or a string (`"720p"`), and `0`/`"Auto"`
marks an HLS master. Subtitles are `{url, label, lang}` and may sit on the
envelope or on a single stream.

Links that begin `MAGIC_PROXY_v1` or `magic_m3u8:` only work inside SkyStream's
own byte proxy. AeroStream reports how many were skipped instead of dropping
them silently, and flags `drmKid`/`licenseUrl` streams as DRM-protected so the
player can say so instead of failing three seconds in. A category named `Trending` is rendered as
the hero carousel. `type` is one of `movie`, `series`, `anime`, `livestream`.

Helpers the bootstrap provides to plugin code:

* `sendMessage(channel, payload)` — the only way out of the sandbox (see
  `ARCHITECTURE.md` for the channel table);
* `fetch(input, init)` — returns a `Response` the way a browser does:
  `ok`, `status`, `headers.get`, `text()`, `json()`, `clone()`;
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

Modules live under `dist/<value>/`, or under the entry's `path` when the
manifest declares one (`{value, display_name, version, path}`), and are
CommonJS:

| Module | Functions AeroStream calls |
| --- | --- |
| `posts.js` | `getPosts({filter, page, providerValue})`, `getSearchPosts({searchQuery, page, providerValue})` |
| `meta.js` | `getMeta({link, providerValue})` |
| `stream.js` | `getStream({link, type, isDownload, providerValue})` |
| `episodes.js` | `getEpisodes({url, providerValue})` — the `episodesLink` from `getMeta`'s `linkList` is the `url` |
| `catalog.js`, `settings.js`, `headers.js` | optional; loaded when present |

Vega's own downloader fetches `posts`, `meta`, `stream`, `catalog` (required)
and `episodes`, `settings` (optional), so those six names are the ones that can
exist in a bundle — plus `headers` and `providerContext`, which its newer
providers import. AeroStream installs all eight and **refuses a bundle that is
missing one of the four required modules**, naming them, instead of installing
half a provider that fails on first playback. Modules are fetched with
`?v=<version>&t=<timestamp>`, the same cache-busting Vega uses, because these
files come straight from `raw.githubusercontent.com`.

Each module must export the function it is called for. AeroStream checks with
`__vegaHas(module, fn)` before calling `__vegaCall(module, fn, optionsJson)`,
and a provider that lacks a module simply does not offer that capability.

Stream objects are `{server, link, type, quality}`; `type` is mapped as
`m3u8`/`hls` → HLS, `mpd`/`dash` → DASH, anything else → progressive.
Subtitles are `{url, language?, label?}`.

Vega providers expect an axios-like HTTP client and a Node-ish `crypto`; the
bootstrap supplies both (`axios` over `http:get`/`http:post`, `crypto` over
`crypto:md5`/`crypto:sha256`/`crypto:hmac`/`crypto:aes`), plus `cheerio` via
`assets/js/cheerio_lite.js`.

---

## CloudStream

**Artifact:** `.cs3` — either a raw DEX, or a ZIP containing `classes.dex` plus
optional `resources.arsc`, compiled `res/*` and `manifest.json`. Its Kotlin code
is compiled against the CloudStream library; it cannot run in a JavaScript
engine. Installation validates the raw DEX or packaged `classes.dex` before the
artifact reaches `cs3_engine`.

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

`status` follows CloudStream's own table: **0 down, 1 ok, 2 slow, 3 beta
only**. Only `0` stops an install; 2 and 3 are installable and are labelled in
the list ("Reported slow", "Beta channel only"). `fileHash` is verified on
install when present. `apiVersion` must be `1`.

### The `cs3_engine` contract

AeroStream uses SkyStream's actual cross-platform engine protocol. Android
loads DEX in-process; desktop converts it and talks to a Java sidecar; iOS runs
it in embedded OpenJDK Zero. Those transports are private to the package. The
adapter sees the same JSON methods everywhere:

| Command | Important arguments | Reply |
| --- | --- | --- |
| `hello` | — | `{engine, platform, vm, plugins, providers, uptimeMs}` |
| `loadPlugin` | `{path, url?}` | `{plugin, version, providers: [{name, mainUrl, lang, types, hasMainPage, sections}], extractors, hasSettings}` |
| `providers` | — | all loaded provider descriptors |
| `mainPage` | `{provider, page, section?, plugin?}` | `{sections: [{name, items}]}` |
| `search` | `{provider, query, page, plugin?}` | `{items, hasNext}` |
| `load` | `{provider, url, plugin?}` | a direct mapped `LoadResponse`, including `dataUrl` or episodes with opaque string `data` |
| `loadLinks` | `{provider, data, timeoutMs, plugin?}` | `{links, subtitles, completed, error?, fullScreen?}` |
| `setRepositories` | `{repositories: [{url, name, iconUrl?}]}` | repository count |
| `setLanguage`, `setClearances` | language/clearance state | applied state |
| `unloadPlugin`, `reloadPlugin` | `{path, url?}` | lifecycle result |
| browser / UI replies | request/session ids plus event-specific fields | engine-specific result |

Every link carries CloudStream's `source`, `name`, `url`, media `type`, numeric
`quality`, `referer`, arbitrary `headers`, and optional `drm` map. Subtitles
carry `lang`, `url` and `headers`. AeroStream sends episode `data` and movie
`dataUrl` back byte-for-byte as Dart strings; they are opaque provider payloads,
not URLs to normalize.

One extension may register several providers. Home and search call all of them;
each mapped item records the provider that produced it so `load` and
`loadLinks` select the same one even when provider names collide (the plugin
path disambiguates them).

---

## Install and update rules

1. The artifact is downloaded with a size cap and, when the listing carries
   `fileHash`, verified before anything is written.
2. Files are staged in a sibling directory and swapped in with `rename`.
3. The previous version's path is recorded for one-step rollback.
4. A plugin whose manifest id disagrees with the listing is rejected.
5. Disabling a plugin keeps its files; uninstalling removes them and leaves
   library entries intact, marked unavailable.

## Not implemented (and labelled as such in the app)

| Capability | Where it would go |
| --- | --- |
| Enabling several SkyStream sub-providers at once | one endpoint per plugin is selectable |
| Plugin `settings` values (declared in `plugin.json`) | parsed and stored, no editing UI yet |
| Byte proxy (`MAGIC_PROXY_v1`, `magic_m3u8:`) | reported as unavailable, never silently dropped |
| DRM (Widevine/PlayReady: `drmKid`, `licenseUrl`, Vega `StreamDrm`) | flagged on the source; the bundled player has no CDM |
| Interactive browser challenges / CloudStream `webRequest` pages | engine events exist; AeroStream UI/answer handling is not complete, so browser-dependent extensions can still fail |
| CloudStream extension settings/pop-up UI | engine serializes the UI tree; AeroStream does not render that tree yet |

## Sandbox rules

Plugin code can: make HTTP requests to public hosts (singly or in parallel),
parse HTML host-side, hash, HMAC, base64, AES-CBC decrypt, unpack P.A.C.K.E.R
obfuscation, and read/write its own settings namespace. Crypto runs host-side
(the keys and the plaintext never sit in the sandbox longer than one call);
unpacking is pure string work and runs in-process. Plugin code cannot:
reach the filesystem, spawn processes, read another plugin's settings, open
sockets, or call any host channel not in the table above.
