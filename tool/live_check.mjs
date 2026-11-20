#!/usr/bin/env node
/*
 * Live ecosystem check.
 *
 * `tool/js_selftest.mjs` proves the sandbox behaves; this proves the three real
 * repositories the app is expected to read still work, using the same files the
 * app would download and the same JavaScript it would run them in:
 *
 *   1. SkyStream shortcode `universe` — the alias people actually type.
 *   2. `https://raw.githubusercontent.com/Skywave22/TJ-Plugins/main/repo.json`
 *      — a SkyStream repository that lists 30+ plugins, one of which is then
 *      downloaded, unpacked and asked for its home screen.
 *   3. Vega providers `vega-org` and `zenda-cross` — two spellings of the same
 *      source (`vega-org` is the old owner name, which GitHub redirects).
 *
 * Everything third-party happens here, at run time: nothing is vendored, and a
 * missing network is reported as a skip rather than as a failure, because "the
 * runner has no internet" is not a bug in AeroStream.
 *
 * Run: node tool/live_check.mjs
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inflateRawSync } from 'node:zlib';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const assets = join(here, '..', 'assets', 'js');

const sources = {
  host: readFileSync(join(assets, 'host_bootstrap.js'), 'utf8'),
  cheerio: readFileSync(join(assets, 'cheerio_lite.js'), 'utf8'),
  vega: readFileSync(join(assets, 'vega_bootstrap.js'), 'utf8'),
};

const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const results = [];
let offline = false;

function report(name, state, detail) {
  results.push({ name, state, detail });
  const tag = state === 'ok' ? 'ok  ' : state === 'skip' ? 'skip' : 'FAIL';
  console.log(`  ${tag} ${name}${detail === undefined ? '' : ` -> ${detail}`}`);
}

function check(name, condition, detail) {
  report(name, condition ? 'ok' : 'fail', detail);
  return condition;
}

class Offline extends Error {}

async function get(url, { headers = {}, redirect = 'follow' } = {}) {
  let response;
  try {
    response = await fetch(url, {
      redirect,
      headers: { 'User-Agent': UA, Accept: '*/*', ...headers },
    });
  } catch (error) {
    offline = true;
    throw new Offline(`${url}: ${error && error.message}`);
  }
  const body = await response.text();
  return {
    status: response.status,
    url: response.url || url,
    body,
    headers: Object.fromEntries(response.headers.entries()),
  };
}

function json(body) {
  try {
    return JSON.parse(body);
  } catch {
    return null;
  }
}

/*
 * Minimal zip reader: a `.sky` is a zip holding plugin.js and plugin.json, and
 * pulling in a dependency to read one would be a bigger surface than the four
 * fields of the central directory that matter here.
 */
function unzip(buffer) {
  let eocd = -1;
  const stop = Math.max(0, buffer.length - 66_000);
  for (let i = buffer.length - 22; i >= stop; i--) {
    if (buffer.readUInt32LE(i) === 0x0605_4b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('not a zip archive');

  const count = buffer.readUInt16LE(eocd + 10);
  let offset = buffer.readUInt32LE(eocd + 16);
  const files = {};
  for (let index = 0; index < count; index++) {
    if (buffer.readUInt32LE(offset) !== 0x0201_4b50) {
      throw new Error('damaged central directory');
    }
    const method = buffer.readUInt16LE(offset + 10);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer.toString('utf8', offset + 46, offset + 46 + nameLength);

    const localNameLength = buffer.readUInt16LE(localOffset + 26);
    const localExtraLength = buffer.readUInt16LE(localOffset + 28);
    const start = localOffset + 30 + localNameLength + localExtraLength;
    const raw = buffer.subarray(start, start + compressedSize);
    files[name] = method === 0 ? Buffer.from(raw) : inflateRawSync(raw);

    offset += 46 + nameLength + extraLength + commentLength;
  }
  return files;
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

function createContext({ vega = false } = {}) {
  const context = vm.createContext({ console: { log() {}, info() {}, debug() {}, warn() {}, error() {} } });
  context.globalThis = context;
  vm.runInContext(sources.host, context, { filename: 'host_bootstrap.js' });
  vm.runInContext(sources.cheerio, context, { filename: 'cheerio_lite.js' });
  if (vega) vm.runInContext(sources.vega, context, { filename: 'vega_bootstrap.js' });
  return context;
}

/** Starts an entry point and services its host calls with [handler]. */
async function invoke(context, fnName, args = [], { handler, steps = 400 } = {}) {
  vm.runInContext(
    `__aeroInvoke(${JSON.stringify(fnName)}, ${JSON.stringify(JSON.stringify(args))})`,
    context,
  );
  for (let step = 0; step < steps; step++) {
    await tick();
    const polled = vm.runInContext('__aeroPoll()', context);
    if (polled === undefined || polled === null || polled === 'null') continue;
    const message = JSON.parse(polled);
    if (!message) continue;
    if (message.done) return message;

    if (message.channel === 'timer') {
      // Fire after the delay it asked for, never at once: plugins race their
      // requests against a timeout, and an instant timer rejects the race
      // before the request can come back. Capped so a long timeout cannot hold
      // the run open, and unref'd so the process can still exit.
      const payload = JSON.parse(message.payload);
      const delay = Math.min(Number(payload.ms) || 0, 5000);
      const timerId = JSON.stringify(payload.timerId);
      setTimeout(() => {
        try {
          vm.runInContext(`__aeroFireTimer(${timerId})`, context);
        } catch {
          // The context is gone; nothing left to fire.
        }
      }, delay).unref?.();
      vm.runInContext(`__aeroResolve(${JSON.stringify(message.id)}, 'null', false)`, context);
      continue;
    }

    let reply = null;
    let isError = false;
    try {
      reply = await handler(message);
    } catch (error) {
      if (error instanceof Offline) throw error;
      reply = { message: String((error && error.message) || error) };
      isError = true;
    }
    const encoded = reply === undefined || reply === null ? 'null' : JSON.stringify(reply);
    vm.runInContext(
      `__aeroResolve(${JSON.stringify(message.id)}, ${JSON.stringify(encoded)}, ${isError})`,
      context,
    );
  }
  throw new Error(`plugin did not finish: ${fnName}`);
}

/** The host side of the bridge: every call becomes a real HTTP request. */
function liveHandler() {
  return async (message) => {
    const payload = JSON.parse(message.payload || '{}');
    switch (message.channel) {
      case 'http:get': {
        const response = await get(payload.url, { headers: payload.headers || {} });
        return {
          status: response.status,
          url: response.url,
          body: response.body,
          headers: response.headers,
        };
      }
      case 'http:post': {
        let body = payload.body;
        const init = {
          method: 'POST',
          headers: { 'User-Agent': UA, ...(payload.headers || {}) },
        };
        if (body !== undefined && body !== null) {
          init.body = typeof body === 'string' ? body : JSON.stringify(body);
        }
        const response = await fetch(payload.url, init);
        const text = await response.text();
        return {
          status: response.status,
          url: response.url || payload.url,
          body: text,
          headers: Object.fromEntries(response.headers.entries()),
        };
      }
      case 'http:batch':
      case 'http:parallel': {
        const requests = payload.requests || [];
        return Promise.all(
          requests.map(async (request) => {
            try {
              const response = await get(request.url, { headers: request.headers || {} });
              return {
                status: response.status,
                url: response.url,
                body: response.body,
                headers: response.headers,
              };
            } catch (error) {
              return { status: 0, body: '', error: String((error && error.message) || error) };
            }
          }),
        );
      }
      case 'timer':
        return null;
      default:
        return null;
    }
  };
}

async function run(name, body) {
  console.log(`\n${name}`);
  try {
    await body();
  } catch (error) {
    if (error instanceof Offline) {
      report(name, 'skip', 'no network from this runner');
      return;
    }
    report(name, 'fail', String((error && error.stack) || error));
  }
}

// ---------------------------------------------------------------------------
// 1. SkyStream shortcode
// ---------------------------------------------------------------------------

const TJ_PLUGINS = 'https://raw.githubusercontent.com/Skywave22/TJ-Plugins/main/repo.json';

/** The candidates `RepositoryInput._shortcodeCandidates` tries, in order. */
function shortcodeCandidates(token) {
  const lower = token.toLowerCase();
  const codes = token === lower ? [token] : [token, lower];
  return [
    ...codes.map((code) => `https://cutt.ly/sky-${code}`),
    ...codes.map((code) => `https://cutt.ly/${code}`),
    ...codes.map((code) => `https://py.md/${code}`),
  ];
}

async function resolveShortcode(token) {
  for (const candidate of shortcodeCandidates(token)) {
    let response;
    try {
      response = await get(candidate, { redirect: 'manual' });
    } catch (error) {
      if (error instanceof Offline) throw error;
      continue;
    }
    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.location;
      if (location) return { candidate, target: new URL(location, candidate).toString() };
    }
  }
  return null;
}

await run('SkyStream shortcode "Universe"', async () => {
  // cutt.ly is case-sensitive, and the repository is published in lower case:
  // this is the exact mismatch the resolver's lower-case candidates exist for.
  const asTyped = await resolveShortcode('Universe');
  check(
    'the code resolves in the spelling people type',
    asTyped !== null && asTyped.target.includes('sky-universe'),
    asTyped === null ? 'no candidate redirected' : asTyped.target,
  );
  if (asTyped === null) return;

  const manifest = json((await get(asTyped.target)).body);
  check(
    'the alias points at a SkyStream mega-repository',
    manifest !== null && Array.isArray(manifest.repos),
    manifest === null ? 'not JSON' : JSON.stringify(Object.keys(manifest)),
  );
  if (manifest && Array.isArray(manifest.repos)) {
    check(
      'it lists the TJ-Plugins repository',
      manifest.repos.some((url) => url.includes('Skywave22/TJ-Plugins')),
      manifest.repos.join(', '),
    );
  }
});

// ---------------------------------------------------------------------------
// 2. TJ-Plugins repository, then a real plugin
// ---------------------------------------------------------------------------

/** What the plugin reported, as opposed to what the sandbox did to it. */
function pluginReported(error) {
  return Boolean(error && error.kind === 'plugin' && error.message);
}

await run('SkyStream repository repo.json', async () => {
  const repo = json((await get(TJ_PLUGINS)).body);
  check(
    'repo.json is a manifest',
    repo !== null && typeof repo.name === 'string',
    repo && repo.name,
  );
  if (!repo) return;

  const lists = Array.isArray(repo.pluginLists) ? repo.pluginLists : [];
  check('it publishes a plugin list', lists.length > 0, lists.join(', '));
  if (lists.length === 0) return;

  const plugins = json((await get(lists[0])).body);
  check(
    'the plugin list parses',
    Array.isArray(plugins),
    Array.isArray(plugins) ? `${plugins.length} plugins` : 'not an array',
  );
  if (!Array.isArray(plugins) || plugins.length === 0) return;

  const first = plugins[0] || {};
  check(
    'entries carry packageName + url (SkyStream shape)',
    typeof first.packageName === 'string' && /\.sky$/i.test(String(first.url)),
    `${first.packageName} -> ${first.url}`,
  );

  // Try a few: one plugin's upstream being down says nothing about the runtime,
  // and this check is about the runtime.
  const candidates = [
    ...plugins.filter((plugin) => /subdub/i.test(plugin.packageName || '')),
    ...plugins.filter((plugin) => !/subdub/i.test(plugin.packageName || '')),
  ].slice(0, 3);

  const notes = [];
  let verified = false;
  let ranAnything = false;

  for (const listed of candidates) {
    const artifact = await fetch(listed.url, { headers: { 'User-Agent': UA } });
    const bytes = Buffer.from(await artifact.arrayBuffer());
    if (artifact.status !== 200 || bytes.length === 0) {
      notes.push(`${listed.packageName}: download answered ${artifact.status}`);
      continue;
    }

    let files;
    try {
      files = unzip(bytes);
    } catch (error) {
      check(`${listed.packageName}: the .sky unpacks`, false, String(error));
      continue;
    }
    const manifest = files['plugin.json'] ? json(files['plugin.json'].toString('utf8')) : null;
    const shapeOk = Boolean(files['plugin.js'] && manifest);
    check(
      `${listed.packageName}: the .sky is a plugin package`,
      shapeOk,
      files['plugin.js'] ? `${bytes.length} bytes, ${manifest && manifest.name}` : Object.keys(files).join(', '),
    );
    if (!shapeOk) continue;

    check(
      `${listed.packageName}: plugin.json names the package the list offered`,
      manifest.packageName === listed.packageName,
      `${manifest.packageName} vs ${listed.packageName}`,
    );

    const context = createContext();
    vm.runInContext(`var manifest = ${JSON.stringify(manifest)};`, context);
    let loadError = null;
    try {
      vm.runInContext(files['plugin.js'].toString('utf8'), context, { filename: 'plugin.js' });
    } catch (error) {
      loadError = error;
    }
    check(
      `${listed.packageName}: the bundle evaluates`,
      loadError === null,
      loadError && String(loadError.message),
    );
    if (loadError) continue;

    const entryPoints = vm.runInContext(
      "['getHome','search','load','loadStreams'].filter(function (name) { return typeof globalThis[name] === 'function'; }).join(',')",
      context,
    );
    check(
      `${listed.packageName}: the entry point is discovered`,
      entryPoints.includes('getHome'),
      entryPoints,
    );
    if (!entryPoints.includes('getHome')) continue;

    let home;
    try {
      home = await invoke(context, 'getHome', [], { handler: liveHandler(), steps: 800 });
    } catch (error) {
      if (error instanceof Offline) throw error;
      check(`${listed.packageName}: getHome completes`, false, String((error && error.message) || error));
      continue;
    }
    ranAnything = true;

    if (home.error) {
      // A plugin that reports "catalog unavailable" is telling us about its
      // upstream, not about the sandbox: the call completed, the callback
      // fired and the error was carried through. Anything else — a throw, a
      // timeout, a missing entry point — is ours, and already failed above.
      notes.push(`${listed.packageName}: ${home.error.message}`);
      check(
        `${listed.packageName}: the plugin's own error is carried through`,
        pluginReported(home.error),
        JSON.stringify(home.error),
      );
      continue;
    }

    const categories = home.value || {};
    const names = Object.keys(categories);
    const items = names.reduce(
      (sum, key) => sum + (Array.isArray(categories[key]) ? categories[key].length : 0),
      0,
    );
    check(
      `${listed.packageName}: getHome returns a category map with items`,
      names.length > 0 && items > 0,
      `${names.length} categories, ${items} items`,
    );
    if (names.length > 0 && items > 0) {
      verified = true;
      break;
    }
  }

  if (!verified && ranAnything) {
    // The runtime ran, the plugins answered, and every upstream refused. Not a
    // defect in this build, so not a red build — but it must be visible.
    report('a plugin served its home screen', 'skip', notes.join(' | ') || 'no candidate answered');
  }
});

// ---------------------------------------------------------------------------
// 3. Vega sources
// ---------------------------------------------------------------------------

const VEGA_MODULES = ['posts.js', 'catalog.js', 'meta.js', 'stream.js', 'episodes.js', 'settings.js'];

async function checkVegaSource(author) {
  const folder = `https://raw.githubusercontent.com/${author}/vega-providers/refs/heads/main`;
  const response = await get(`${folder}/manifest.json`);
  check(`${author}: manifest.json answers`, response.status === 200, `HTTP ${response.status}`);

  const providers = json(response.body);
  if (!Array.isArray(providers)) {
    report(`${author}: manifest is a provider array`, 'fail', 'not an array');
    return;
  }
  check(
    `${author}: manifest is a provider array`,
    providers.length > 0 && typeof providers[0].value === 'string',
    `${providers.length} providers, first = ${providers[0] && providers[0].value}`,
  );

  const provider = providers.find((entry) => entry.value === 'vega') || providers[0];
  if (!provider) return;

  // The modules Vega's loader requires, at <source>/dist/<value>/.
  const files = {};
  for (const module of VEGA_MODULES) {
    const url = `${folder}/dist/${provider.value}/${module}?v=${encodeURIComponent(provider.version || '0')}`;
    let moduleResponse;
    try {
      moduleResponse = await fetch(url, { headers: { 'User-Agent': UA } });
    } catch (error) {
      offline = true;
      throw new Offline(String((error && error.message) || error));
    }
    if (moduleResponse.status === 200) files[module] = await moduleResponse.text();
  }
  check(
    `${author}: the provider modules download`,
    Boolean(files['posts.js'] && files['meta.js'] && files['stream.js'] && files['catalog.js']),
    Object.keys(files).join(', '),
  );
  if (!files['posts.js']) return;

  const context = createContext({ vega: true });
  const loaded = [];
  for (const [module, source] of Object.entries(files)) {
    const result = JSON.parse(
      vm.runInContext(
        `__vegaLoad(${JSON.stringify(module.replace('.js', ''))}, ${JSON.stringify(source)})`,
        context,
      ),
    );
    loaded.push(`${module}:${result.ok ? 'ok' : 'load-error'}`);
  }
  check(`${author}: every module evaluates`, !loaded.some((entry) => entry.endsWith('load-error')), loaded.join(' '));

  // `catalog.js` exports the category list as a value, not as a function.
  let catalogEntries = null;
  try {
    catalogEntries = JSON.parse(
      vm.runInContext("JSON.stringify(__vega.modules['catalog'].catalog || [])", context),
    );
  } catch (error) {
    check(`${author}: the catalog exports categories`, false, String((error && error.message) || error));
  }
  check(
    `${author}: the catalog exports categories`,
    Array.isArray(catalogEntries) && catalogEntries.length > 0,
    `${(catalogEntries || []).length} categories`,
  );

  const filter = Array.isArray(catalogEntries) && catalogEntries[0] ? catalogEntries[0].filter : 'trending';
  const posts = await invoke(
    context,
    '__vegaCall',
    ['posts', 'getPosts', JSON.stringify({ filter, page: 1, providerValue: provider.value })],
    { handler: liveHandler(), steps: 800 },
  );
  const items = posts.error ? null : posts.value;
  check(
    `${author}: getPosts returns posts for "${filter}"`,
    Array.isArray(items) && items.length > 0,
    posts.error ? JSON.stringify(posts.error) : `${(items || []).length} posts`,
  );
}

await run('Vega source "zenda-cross"', async () => {
  await checkVegaSource('Zenda-Cross');
});

await run('Vega source "vega-org" (renamed owner)', async () => {
  // raw.githubusercontent.com answers renamed repositories with a redirect, so
  // the old name keeps working — but only for a client that follows it.
  await checkVegaSource('vega-org');
});

// ---------------------------------------------------------------------------

const passed = results.filter((entry) => entry.state === 'ok').length;
const failed = results.filter((entry) => entry.state === 'fail');
const skipped = results.filter((entry) => entry.state === 'skip').length;

console.log(`\n${passed} passed, ${failed.length} failed, ${skipped} skipped`);
if (offline && failed.length === 0) {
  console.log('No network: the live checks could not run.');
}
process.exit(failed.length === 0 ? 0 : 1);
