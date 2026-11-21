# Changelog

Notable changes, newest first. The version numbers match `pubspec.yaml`; a test
keeps `lib/core/app_info.dart` in step with it.

## Unreleased

Found by pointing the shipped runtime at the three sources people add first:
the SkyStream `universe` shortcode, the TJ-Plugins repository, and the Vega
source `vega-org` / `zenda-cross`.

### Extensions
* **Shortcodes that are typed with a capital work.** cutt.ly is case-sensitive
  and the SkyStream repository is published as `cutt.ly/sky-universe`, so
  `Universe` — the spelling the app's own documentation uses — resolved to a
  404 and fell through to "no repository answered". Both spellings are now
  tried, as SkyStream itself does, and the short link that does not exist is
  reported as such instead of looking like a network failure.
* **Short links that answer with a page resolve too.** Some shorteners reply
  `200` with the destination in a meta refresh or a `window.location`
  assignment rather than a 302; only the header was read. The lookup now also
  asks as a browser (a bare `Dart/3.x` User-Agent gets turned away) and
  distinguishes "no such code" (404/410) from "slow down" (429).
* **Vega installs stop requesting files that do not exist per provider.**
  `headers.js` and `providerContext.js` are published once at the source's
  `dist/`, not in every provider folder, so each install made two requests that
  always 404'd.
* **Vega providers could not run at all.** Their bundles call the global
  `fetch` and read a Response — `if (!res.ok) throw`, then `await res.text()` —
  and the sandbox handed back `{status, url, body}`, so every provider threw on
  its first request. `fetch` now returns the Response surface (`ok`, `status`,
  `headers.get`, `text()`, `json()`, `clone()`), and `providerContext` carries
  the names providers destructure (`commonHeaders`, `Crypto`, `kvStore`).
* **SkyStream `search` passes the query and nothing else.** The SDK's
  signature is `search(query, cb)`; sending `[query, page]` put the page number
  where the plugin expects its callback, so callback-style plugins threw instead
  of answering.
* **A mega-repository's children keep their ecosystem.** `repos` is how
  SkyStream publishes its own mega-repository, and the child lists were read
  with a CloudStream hint; a SkyStream entry parses either way, so its `.sky`
  URL ended up installed as if it were a DEX. The entries now decide.
* **Callback entry points no longer depend on declared arity.** A plugin
  written as `getHome(cb = () => {})` or `(...args)` has `length === 0`, so the
  arity guess handed it no callback and the call hung until it timed out. The
  callback is appended to every call, which is what SkyStream's engine does, and
  a promise or a plain return is still accepted.

### Verification
* `tool/live_check.mjs` runs the three real inputs against the real network —
  the shortcode, the repository (whose `.sky` is downloaded, unpacked, and asked
  for its home screen), and both Vega source names — and the CI workflow runs it
  as **Live ecosystem check**. A runner without internet is reported as a skip,
  not a failure, so an upstream outage is not mistaken for a broken build.

## 0.2.0 — released 2026-11-19

Sections, detection fixes and a new coat of paint. `v0.1.0` was the first
release; this is the first one where all three ecosystems' sources add
correctly.

### Extensions
* **Three ecosystems, three sections.** Extensions is now a hub of SkyStream
  Providers, CloudStream Extensions and Vega Providers — the split SkyStream and
  CloudStream use — and each section has its own *Installed / Browse / Sources*
  pages, its own add-repository sheet, its own accents and its own status. All
  three are also listed under **Settings › Extensions** with their source and
  install counts.
* **Adding a repository works for every ecosystem.** A URL that publishes the
  plugin array itself (a `plugins.json`, not a `repo.json`) is now classified
  from its entries instead of being assumed to be Vega, which is why CloudStream
  and SkyStream lists used to add to the wrong section and list nothing. Folder
  inputs try `manifest.json`, `repo.json` and `plugins.json` in turn, and a
  guessed ecosystem is corrected by reading the list without the guess.
* **CloudStream is honest about the host.** The section manages `.cs3`
  extensions everywhere but says, on the page, why they cannot run on a build
  without the native Kotlin host.

### UI
* **A new frame.** Tighter headings, one radius family, tinted surfaces instead
  of borders, a gradient brand mark, restyled dialogs, sheets, menus and tabs,
  and per-platform page transitions left to Material rather than overridden.
* **Settings is grouped cards**: a chip row for the palette, a sheet for the
  quality choice, and an Extensions group with the three ecosystem pages.
* **Search** moved its field into the body, counts what it found, and badges
  each group with its ecosystem. Library, Downloads and Search share one empty
  state.
* **First run** offers the three ecosystems directly instead of pointing at a
  menu, and details fades its backdrop into the page.

## 0.1.0 — released 2026-11-19

First complete pass of the app: foundation through playback, history and
offline downloads, with every repository-add and plugin-install path audited
against SkyStream, Vega and CloudStream as they actually publish.

### Plugins

* **Repository input** accepts every convention the three ecosystems use:
  full manifest URLs, folder URLs, `cloudstreamrepo://…` / `https://cs.repo/?…`
  deep links, `cutt.ly` / `py.md` shortcodes, bare Vega authors,
  `author@gh|cb|bb|gl`, and the raw URLs for GitHub, Codeberg, Bitbucket and
  GitLab. Redirects are followed exactly one hop and `/404` targets are refused.
* **SkyStream mirrors and sub-providers** (`domains`, `providers`) are parsed,
  selectable per plugin in Extensions, and injected as `manifest.baseUrl` /
  `manifest.providerId` — the plugin never learns the user switched.
* **Host helpers**: real AES-CBC decryption (`crypto.decryptAES`), P.A.C.K.E.R
  unpacking (`getAndUnpack`), `http_parallel`, and a `solveCaptcha` that explains
  why it cannot work instead of hanging.
* **Vega** installs `episodes.js`, `headers.js` and `providerContext.js`,
  requires the four modules Vega itself requires, and cache-busts module URLs
  with `?v=&t=` like Vega does.
* **CloudStream** listings honour `status` (down / ok / slow / beta) and
  `fileHash`, and repositories newer than this build are refused by name.

### App

* Home, search, details, episodes, library, history, downloads, settings.
* libmpv playback through `media_kit`, with source picking, headers, subtitles
  and per-episode resume.
* Downloads: serial queue, cancel/retry, `file://` playback; progressive HTTP
  only, and the button says so for HLS/DASH.
* **Settings › Your data**: clear history, clear saved titles, remove finished
  downloads, delete every value plugins stored. All of them confirm first.
* **Settings › Platform**: the support matrix per device, including the case
  where Android is present but the CloudStream host is not part of the build.

### Platform

* Android, iOS, macOS, Windows, Linux. Runners are generated by
  `scripts/scaffold_platforms.sh`, which also allows cleartext HTTP for plugin
  sources.
* No web target: `dart:io`, FFI and libmpv are all required.

### Known limits

See the "Not implemented" table in `docs/PLUGIN_SPEC.md`. In short: one plugin
endpoint at a time, plugin `settings` are stored but not editable, no DRM, no
byte proxy, and the CloudStream Kotlin host is a contract rather than an
implementation.
