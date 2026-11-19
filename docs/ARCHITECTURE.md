# Architecture

AeroStream is a runtime, not a catalogue. Everything the user sees is produced
by a plugin; the app's job is to load untrusted plugin code safely, translate
three different plugin formats into one model, and present the result.

```
┌──────────────────────────────────────────────────────────────────┐
│ features/            screens, wired with Riverpod                │
│   shell · home · search · details · player · library ·           │
│   extensions · settings                                          │
├──────────────────────────────────────────────────────────────────┤
│ domain/              entities, MediaProvider, CatalogService     │
│                      (no Flutter, no I/O)                        │
├──────────────────────────────────────────────────────────────────┤
│ plugins/                                                         │
│   manager/    ExtensionManager · RepositoryService ·             │
│               PluginRuntimeFactory                               │
│   adapters/   skystream · vega · cloudstream                     │
│   runtime/    JsRuntime · JsPluginHost · JsHostApi               │
│   manifest/   repository and plugin-list parsers                 │
├──────────────────────────────────────────────────────────────────┤
│ data/         SQLite store · filesystem artifacts · prefs        │
│ core/         Result, PluginError, network, json, logging        │
└──────────────────────────────────────────────────────────────────┘
```

Dependencies point downwards only. `domain` knows nothing about plugins;
`plugins` knows nothing about widgets; `features` knows nothing about SQLite or
QuickJS. The one place that crosses from "installed plugin" to "runnable
provider" is `PluginRuntimeFactory`, and the one place that crosses from "many
providers" to "one feed" is `CatalogService`.

## The four contracts

### 1. `MediaProvider` — what a feature may assume

```dart
abstract interface class MediaProvider {
  PluginInfo get info;
  PluginCapabilities get capabilities;
  Future<Result<List<HomeSection>>> getHome();
  Future<Result<SearchPage>> search(String query, {int page = 1});
  Future<Result<MediaDetails>> getDetails(MediaItem item);
  Future<Result<List<Episode>>> getEpisodes(MediaItem item, {Season? season});
  Future<Result<StreamResult>> getStreams(MediaItem item, {Episode? episode});
  Future<void> dispose();
}
```

`Result` instead of exceptions, because a plugin is untrusted: a failure is
data the UI must render, not a stack trace it must survive. Nothing above this
interface catches an exception from a plugin, because nothing above it can
receive one.

### 2. `JsRuntime` — the engine seam

```dart
abstract interface class JsRuntime {
  Future<void> start();
  Future<String?> evaluate(String script);
  Future<void> dispose();
}
```

The interface is deliberately tiny: evaluate a string, get a string back.
Everything else — the bridge protocol, timers, promises — lives in JavaScript
(`assets/js/host_bootstrap.js`), so a different engine (QuickJS today, anything
tomorrow) needs no Dart-side protocol work. `UnavailableJsRuntime` is the
failsafe used by builds and tests that have no engine: it throws
`JsEvalException`, which the host turns into a typed `PluginUnsupportedError`.

### 3. `JsPluginHost` — one plugin, one context

`JsPluginHost` owns a single plugin's lifetime and budgets:

| Budget | Value | On breach |
| --- | --- | --- |
| call timeout | 25 s | context killed, `PluginTimeoutError` |
| evaluation timeout | 3 s | context killed, `PluginTimeoutError` |
| memory | 64 MB | `PluginSandboxError` |
| host calls per invocation | 250 | `PluginSandboxError` |
| HTTP requests per invocation | 120 | `PluginSandboxError` |
| poll interval | 2 ms | — |
| max timer delay | 10 s | clamped |

Startup order: host bootstrap → `prelude` scripts (Vega's modules) → the
plugin's manifest global → the plugin source. Every violation disposes the
context and bumps `generation`, so a stale callback can never resolve a call
belonging to a newer context.

### 4. `CloudStreamBridge` — the native seam

CloudStream plugins are compiled Kotlin, not JavaScript, so the runtime is a
`MethodChannel` (`dev.aerostream/cloudstream`) to a native host. The interface
is the same shape as everything else — `Future<Result<Map<String, Object?>>>` —
and a missing implementation (`MissingPluginException`) is reported as
"unsupported on this platform", never as a crash.

## The bridge protocol

JavaScript never touches the network or the filesystem directly. It calls
`sendMessage(channel, payload)`, which lands in `JsHostApi._dispatch`:

| Channel | Payload | Reply |
| --- | --- | --- |
| `http:get`, `http:post` | `{url, headers?, body?, …}` | `{status, url, body, headers}` |
| `http:batch` | `{requests: [...]}` | array of the above |
| `html:parse` | `{html}` | `{id}` — a document handle kept host-side |
| `html:select` | `{html, selector, attribute?}` | matched texts/attributes |
| `html:query` | `{doc, selector, attribute?}` | extracted values |
| `html:attr`, `html:text` | `{doc, selector, attribute?}` | one value |
| `crypto:md5`, `crypto:sha256` | `{data}` | hex digest |
| `crypto:hmac` | `{data, key, algorithm?}` | hex digest |
| `crypto:aes` | — | `unsupported` (not implemented) |
| `text:b64encode`, `text:b64decode` | `{data}` | text |
| `storage:get`, `storage:set`, `storage:remove` | `{key, value?, fallback?}` | value |
| `timer` | fired host-side | `__aeroFireTimer(id)` |

Parsing HTML host-side (rather than shipping a DOM into the sandbox) keeps the
engine small: plugin scripts get selectors, not `document`.

Every request passes `NetworkPolicy` first: no `localhost`, no `.local` or
`.internal`, no loopback, link-local, private or CGNAT ranges, and only
`http`/`https`. A plugin cannot ask the app to reach the user's own network.

## Aggregation rules

`CatalogService` is where "many plugins" becomes "one app":

* **Isolation** — a provider that throws, returns an `Err` or hangs past the
  timeout contributes nothing. The feed still renders.
* **Dedupe** — the same title from two plugins appears once, first provider
  wins (priority order), keyed on lowercased title plus year.
* **No empty rows** — a section that lost all its items to dedupe disappears.
* **Search ordering** — plugins that answered come first; failures follow,
  carrying their error so the UI can offer a retry per plugin instead of
  failing the whole search.

## Storage

| What | Where | Why |
| --- | --- | --- |
| Repositories, installed plugins | SQLite (`aerostream.db`), `PRAGMA user_version` migrations | queries, ordering, atomic updates |
| Plugin artifacts | `<appSupport>/plugins/<ecosystem>/<id>/<version>/` | one shape for every ecosystem |
| Preferences, library, plugin settings | `shared_preferences` | small values, no schema |

Installs are staged into a sibling directory and swapped with `rename`, so a
failed update leaves the previous version runnable. `previousArtifactPath`
keeps exactly one rollback available.

## Failure model

| Situation | What the user sees |
| --- | --- |
| plugin hangs | "The plugin took too long to answer", retry |
| plugin throws | "The plugin stopped unexpectedly", retry |
| plugin asks for something outside its box | "The plugin tried to leave its sandbox" |
| ecosystem cannot run here | "not available on this platform", install disabled |
| no plugins installed | an explanation and a link to Extensions |

## What is deliberately absent

* No bundled sources, no default repository, no scraping code. The app is a
  client; the user brings the plugins.
* No `eval` of plugin *manifests* as code: manifests are JSON, parsed by
  `lib/plugins/manifest/`.
* No dynamic code push: the app updates through the store.
