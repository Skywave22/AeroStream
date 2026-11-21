#!/usr/bin/env node
/*
 * Self-test for the JavaScript layer that ships with AeroStream.
 *
 * The JS in assets/js/ is as load-bearing as the Dart: it is what plugins
 * actually run against. This harness executes it in a Node VM with a fake host
 * that speaks the same protocol as JsPluginHost, so the bootstrap, the DOM
 * shim and the Vega loader are verified without a Flutter toolchain.
 *
 * Run: node tool/js_selftest.mjs
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const assets = join(here, '..', 'assets', 'js');

const sources = {
  host: readFileSync(join(assets, 'host_bootstrap.js'), 'utf8'),
  cheerio: readFileSync(join(assets, 'cheerio_lite.js'), 'utf8'),
  vega: readFileSync(join(assets, 'vega_bootstrap.js'), 'utf8'),
};

let failures = 0;
let passes = 0;

function check(name, condition, detail) {
  if (condition) {
    passes++;
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.log(`  FAIL ${name}${detail === undefined ? '' : ` -> ${detail}`}`);
  }
}

/** Waits for promise callbacks to run (the sandbox shares this isolate). */
const tick = () => new Promise((resolve) => setImmediate(resolve));

function createContext({ includeVega = true } = {}) {
  const context = vm.createContext({ console });
  context.globalThis = context;
  vm.runInContext(sources.host, context, { filename: 'host_bootstrap.js' });
  vm.runInContext(sources.cheerio, context, { filename: 'cheerio_lite.js' });
  if (includeVega) {
    vm.runInContext(sources.vega, context, { filename: 'vega_bootstrap.js' });
  }
  return context;
}

/**
 * A miniature JsPluginHost: starts a call, then pumps until the plugin is done,
 * servicing each host call with [handler].
 */
async function invoke(context, fn, args = [], handler = () => null, { maxSteps = 200 } = {}) {
  vm.runInContext(
    `__aeroInvoke(${JSON.stringify(fn)}, ${JSON.stringify(JSON.stringify(args))})`,
    context,
  );
  for (let step = 0; step < maxSteps; step++) {
    await tick();
    const polled = vm.runInContext('__aeroPoll()', context);
    if (polled === undefined || polled === null || polled === 'null') continue;
    const message = JSON.parse(polled);
    if (!message) continue;
    if (message.done) return message;
    const reply = await handler(message);
    const json = reply === undefined || reply === null ? 'null' : JSON.stringify(reply);
    vm.runInContext(
      `__aeroResolve(${JSON.stringify(message.id)}, ${JSON.stringify(json)}, false)`,
      context,
    );
  }
  throw new Error('plugin did not finish');
}

async function run(name, body) {
  console.log(`\n${name}`);
  try {
    await body();
  } catch (error) {
    failures++;
    console.log(`  FAIL threw: ${error && error.stack ? error.stack : error}`);
  }
}

// ---------------------------------------------------------------------------

await run('SkyStream callback plugins', async () => {
  const context = createContext();
  vm.runInContext(`
    globalThis.getHome = function (cb) {
      cb({ success: true, data: {
        Trending: [new MultimediaItem({ title: 'Hero', url: 'https://e/1', type: 'movie' })],
        Latest: [new MultimediaItem({ title: 'Two', url: 'https://e/2', type: 'series' })]
      }});
    };
  `, context);

  const result = await invoke(context, 'getHome');
  check('resolves the callback payload', result.value && result.value.Trending.length === 1, JSON.stringify(result));
  check('model constructor keeps fields', result.value.Latest[0].type === 'series');
});

await run('SkyStream promise + error plugins', async () => {
  const context = createContext();
  vm.runInContext(`
    globalThis.search = async function (query, page) {
      return [{ title: 'Result for ' + query, url: 'https://e/q', page: page }];
    };
    globalThis.load = function (url, cb) {
      cb({ success: false, errorCode: 'LOAD_ERROR', message: 'nope' });
    };
  `, context);

  const ok = await invoke(context, 'search', ['dune', 2]);
  check('promise-returning entry point', ok.value && ok.value[0].page === 2, JSON.stringify(ok));

  const failed = await invoke(context, 'load', ['https://e/x']);
  check('callback error becomes an error object',
    failed.error && failed.error.message === 'nope', JSON.stringify(failed));
});

await run('HTTP bridge', async () => {
  const context = createContext();
  vm.runInContext(`
    globalThis.load = async function (url) {
      const response = await http_get('https://example.com/' + url, { Referer: 'https://example.com' });
      return { status: response.status, body: response.body };
    };
  `, context);

  const seen = [];
  const result = await invoke(context, 'load', ['page'], (message) => {
    seen.push(message);
    return { status: 200, body: '<html>ok</html>', headers: {} };
  });

  check('http_get reaches the host', seen.length === 1 && seen[0].channel === 'http:get');
  check('request payload carries headers', JSON.parse(seen[0].payload).headers.Referer === 'https://example.com');
  check('response body returns to the plugin', result.value.body === '<html>ok</html>');
});

await run('fetch() returns a Response', async () => {
  const context = createContext();
  vm.runInContext(`
    globalThis.load = async function (url) {
      const response = await fetch(url, { headers: { Referer: 'https://example.com' } });
      return {
        ok: response.ok,
        status: response.status,
        type: response.headers.get('content-type'),
        text: await response.text()
      };
    };
    globalThis.loadJson = async function (url) {
      const response = await fetch(url);
      const body = await response.json();
      return body.items.map(function (item) { return item.name; });
    };
  `, context);

  const result = await invoke(context, 'load', ['https://example.com/a'], (message) => ({
    status: 200,
    url: 'https://example.com/a',
    body: '<html>ok</html>',
    headers: { 'Content-Type': 'text/html' },
  }));

  // The shape Vega's bundles read: `if (!res.ok) throw`, then `await res.text()`.
  check('ok is a boolean derived from the status', result.value.ok === true, JSON.stringify(result));
  check('status is the response status', result.value.status === 200, JSON.stringify(result));
  check('headers.get is case-insensitive', result.value.type === 'text/html', JSON.stringify(result));
  check('text() resolves the body', result.value.text === '<html>ok</html>', JSON.stringify(result));

  const parsed = await invoke(context, 'loadJson', ['https://example.com/api'], () => ({
    status: 200,
    body: '{"items":[{"name":"one"},{"name":"two"}]}',
    headers: {},
  }));
  check('json() parses the body', parsed.value.join(',') === 'one,two', JSON.stringify(parsed));

  const missing = await invoke(context, 'load', ['https://example.com/missing'], () => ({
    status: 404,
    body: 'nope',
    headers: {},
  }));
  check('a 404 is not ok', missing.value.ok === false && missing.value.status === 404, JSON.stringify(missing));
});

await run('Vega provider using global fetch', async () => {
  const context = createContext();
  // The real bundles call the global `fetch` and read a Response; they do not
  // require axios for every module.
  const posts = `"use strict";
    function posts(baseUrl, url, signal, headers, axios, cheerio) {
      return fetch(url, { headers: headers }).then(function (res) {
        if (!res.ok) throw new Error('HTTP ' + res.status);
        return res.text();
      }).then(function (html) {
        var $ = cheerio.load(html);
        var out = [];
        $('.card').each(function (i, el) {
          out.push({ title: $(el).text().trim(), link: $(el).attr('href') });
        });
        return out;
      });
    }
    exports.getPosts = function (args) {
      var providerContext = args.providerContext;
      return posts(
        'https://example.com',
        'https://example.com/list',
        args.signal,
        {},
        providerContext.axios,
        providerContext.cheerio
      );
    };`;

  const loaded = JSON.parse(vm.runInContext(`__vegaLoad('fetchposts', ${JSON.stringify(posts)})`, context));
  check('module loads', loaded.ok === true, JSON.stringify(loaded));

  const result = await invoke(context, '__vegaCall', ['fetchposts', 'getPosts', '{}'], (message) => ({
    status: 200,
    body: '<div><a class="card" href="/a">One</a><a class="card" href="/b">Two</a></div>',
    headers: {},
  }));

  check('provider reads the fetched page',
    Array.isArray(result.value) && result.value.length === 2, JSON.stringify(result));
  check('provider maps titles', result.value[0].title === 'One', JSON.stringify(result.value));
});

await run('Callback detection does not depend on arity', async () => {
  const context = createContext();
  // A default parameter or a rest parameter makes fn.length 0, so an
  // arity-based guess passes no callback and the invoke never settles.
  vm.runInContext(`
    globalThis.getHome = function (cb = function () {}) {
      cb({ success: true, data: ['default-param'] });
    };
    globalThis.search = function (...args) {
      const cb = args[args.length - 1];
      cb({ success: true, data: ['rest-param'] });
    };
    globalThis.load = function (url, cb) {
      cb({ success: true, data: ['normal'] });
      cb({ success: true, data: ['second-call-is-ignored'] });
    };
  `, context);

  const home = await invoke(context, 'getHome');
  check('a default parameter still gets a callback', home.value && home.value[0] === 'default-param', JSON.stringify(home));

  const search = await invoke(context, 'search', ['dune']);
  check('a rest parameter still gets a callback', search.value && search.value[0] === 'rest-param', JSON.stringify(search));

  const load = await invoke(context, 'load', ['https://e/1']);
  check('the first callback wins', load.value && load.value[0] === 'normal', JSON.stringify(load));
});

await run('Timers', async () => {
  const context = createContext();
  vm.runInContext(`
    globalThis.getHome = async function () {
      await new Promise(function (resolve) { setTimeout(resolve, 5); });
      return 'after-timer';
    };
  `, context);

  let fired = 0;
  const result = await invoke(context, 'getHome', [], (message) => {
    if (message.channel === 'timer') {
      fired++;
      const payload = JSON.parse(message.payload);
      vm.runInContext(`__aeroFireTimer(${JSON.stringify(payload.timerId)})`, context);
      return null;
    }
    return null;
  });

  check('timer call is queued to the host', fired === 1, `fired=${fired}`);
  check('await resumes after the timer', result.value === 'after-timer', JSON.stringify(result));
});

await run('Console capture', async () => {
  const context = createContext();
  vm.runInContext(`
    console.log('hello', { a: 1 });
    console.warn('careful');
  `, context);
  const logs = JSON.parse(vm.runInContext('__aeroDrainLogs()', context));
  check('logs are queued', logs.length === 2, JSON.stringify(logs));
  check('log level is preserved', logs[1].level === 'warn');
  check('objects are serialised', logs[0].message.includes('{"a":1}'));
});

await run('Encoding and crypto shims', async () => {
  const context = createContext();
  vm.runInContext(`
    globalThis.probe = async function () {
      return {
        b64: await btoa('aero'),
        md5: await crypto.md5('abc')
      };
    };
  `, context);

  const result = await invoke(context, 'probe', [], (message) => {
    if (message.channel === 'text:b64encode') return 'YWVybw==';
    if (message.channel === 'crypto:md5') return '900150983cd24fb0d6963f7d28e17f72';
    return null;
  });
  check('btoa goes through the host', result.value.b64 === 'YWVybw==');
  check('md5 goes through the host', result.value.md5.startsWith('900150'));
});

await run('URL and URLSearchParams polyfills', async () => {
  const context = createContext();
  vm.runInContext(`
    globalThis.probe = function () {
      var url = new URL('https://example.com/a/b?x=1&y=2');
      var params = new URLSearchParams('q=dune&page=2');
      return [url.host, url.pathname, params.get('q'), params.get('page')];
    };
  `, context);
  const result = await invoke(context, 'probe');
  check('URL parses host', result.value[0] === 'example.com');
  check('URL parses path', result.value[1] === '/a/b');
  check('URLSearchParams reads values', result.value[2] === 'dune' && result.value[3] === '2');
});

await run('cheerio_lite DOM', async () => {
  const context = createContext();
  const output = vm.runInContext(`
    (function () {
      var html = '<div class="list"><article class="item"><a href="/one" data-id="7">First &amp; One</a>' +
        '<img src="/img/1.jpg"></article><article class="item"><a href="/two">Second</a></article></div>';
      var $ = cheerioLite.load(html);
      var hrefs = [];
      $('.item a').each(function (i, el) { hrefs.push($(el).attr('href')); });
      return JSON.stringify({
        count: $('.item').length,
        hrefs: hrefs,
        firstText: $('.item a').first().text(),
        dataId: $('a[data-id=7]').attr('data-id'),
        img: $('img').attr('src'),
        child: $('.list > article').length,
        missing: $('.nope').length,
        contains: $('a').filter('a[href^="/t"]').text()
      });
    })()
  `, context);
  const dom = JSON.parse(output);
  check('selects by class', dom.count === 2, output);
  check('each() iterates', dom.hrefs.join(',') === '/one,/two', JSON.stringify(dom.hrefs));
  check('text() decodes entities', dom.firstText.trim() === 'First & One', dom.firstText);
  check('attribute selector', dom.dataId === '7', dom.dataId);
  check('void element attribute', dom.img === '/img/1.jpg', dom.img);
  check('child combinator', dom.child === 2, dom.child);
  check('missing selector is empty', dom.missing === 0);
  check('filter by attribute prefix', dom.contains.trim() === 'Second', dom.contains);
});

await run('cheerio_lite edge cases', async () => {
  const context = createContext();
  const output = vm.runInContext(`
    (function () {
      var $ = cheerioLite.load('<ul><li>a</li><!-- comment --><li>b</li><li>c</li></ul>');
      return JSON.stringify({
        items: $('li').length,
        last: $('li').last().text(),
        nth: $('li:nth-child(2)').text(),
        upper: cheerioLite.load('<DIV CLASS="x">hi</DIV>')('.x').length,
        script: cheerioLite.load('<script>var a = "<div>";</' + 'script>')('script').text(),
        unclosed: cheerioLite.load('<p>one<p>two')('p').length
      });
    })()
  `, context);
  const dom = JSON.parse(output);
  check('skips comments', dom.items === 3, output);
  check('last()', dom.last.trim() === 'c', dom.last);
  check('nth-child', dom.nth.trim() === 'b', dom.nth);
  check('class matching is case sensitive on normalised tags', dom.upper === 1);
  check('raw text in script', dom.script.includes('<div>'), dom.script);
  check('unclosed tags nest', dom.unclosed === 2, dom.unclosed);
});

await run('Vega CommonJS providers', async () => {
  const context = createContext();
  const posts = `"use strict";
    var cheerio = require('cheerio');
    var axios = require('axios');
    exports.getPosts = async function (args) {
      var response = await axios.get('https://example.com/list', { headers: { 'User-Agent': 'aero' } });
      var $ = cheerio.load(response.data);
      return $('.card').map(function (i, el) { return { title: $(el).text().trim(), link: $(el).attr('href') }; }).get().filter(Boolean);
    };
    exports.getCallable = async function () {
      var response = await axios('https://example.com/hubcloud', {
        headers: { Referer: 'https://example.com/' }
      });
      return response.data;
    };
    exports.getStream = async function (args) {
      return [{ server: 'Vega', link: 'https://cdn.example/x.m3u8', type: 'm3u8', quality: '1080' }];
    };`;

  const loaded = JSON.parse(
    vm.runInContext(`__vegaLoad('posts', ${JSON.stringify(posts)})`, context),
  );
  check('module loads', loaded.ok === true, JSON.stringify(loaded));
  check('exports are detected', loaded.keys.includes('getPosts'), JSON.stringify(loaded.keys));
  check('has() probes functions', vm.runInContext("__vegaHas('posts','getPosts')", context) === 'true');

  const result = await invoke(context, '__vegaCall', ['posts', 'getPosts', '{}'], (message) => {
    if (message.channel === 'http:get') {
      return {
        status: 200,
        body: '<html><a class="card" href="/a">One</a><a class="card" href="/b">Two</a></html>',
        headers: {},
      };
    }
    return null;
  });

  check('provider runs end to end',
    Array.isArray(result.value) && result.value.length === 2, JSON.stringify(result));
  check('provider sees parsed titles', result.value[0].title === 'One', JSON.stringify(result.value));

  let callableRequest;
  const callable = await invoke(
    context,
    '__vegaCall',
    ['posts', 'getCallable', '{}'],
    (message) => {
      callableRequest = JSON.parse(message.payload);
      return { status: 200, body: 'hubcloud page', headers: {} };
    },
  );
  check(
    'axios(url, config) sends the URL instead of an empty request',
    callableRequest.url === 'https://example.com/hubcloud',
    JSON.stringify(callableRequest),
  );
  check(
    'axios(url, config) keeps request headers',
    callableRequest.headers.Referer === 'https://example.com/',
    JSON.stringify(callableRequest),
  );
  check('axios(url, config) returns response data', callable.value === 'hubcloud page');

  const streams = await invoke(context, '__vegaCall', ['posts', 'getStream', '{}']);
  check('getStream maps through', streams.value[0].quality === '1080', JSON.stringify(streams));
});

await run('Vega provider errors are contained', async () => {
  const context = createContext();
  const loaded = JSON.parse(vm.runInContext(`__vegaLoad('bad', 'exports.getPosts = function(){')`, context));
  check('a syntax error is reported, not thrown', loaded.ok === false && loaded.error.length > 0, JSON.stringify(loaded));

  vm.runInContext(`__vegaLoad('boom', 'exports.getPosts = async function(){ throw new Error("kaboom"); };')`, context);
  const failed = await invoke(context, '__vegaCall', ['boom', 'getPosts', '{}']);
  check('a throwing provider becomes an error result',
    failed.error && String(failed.error.message).includes('kaboom'), JSON.stringify(failed));
});

await run('SkyStream host helpers exist', async () => {
  const context = createContext();
  const types = vm.runInContext(
    "[typeof http_parallel, typeof getAndUnpack, typeof solveCaptcha, typeof crypto.decryptAES].join(',')",
    context,
  );
  check('http_parallel, getAndUnpack, solveCaptcha, crypto.decryptAES are defined',
    types === 'function,function,function,function', types);
});

await run('getAndUnpack strips P.A.C.K.E.R packing', async () => {
  const context = createContext();
  const packed = "eval(function(p,a,c,k,e,d){e=function(c){return c};return p}('0 1 2',62,3,'var|alpha|beta'.split('|'),0,{}))";
  const flat = vm.runInContext(`getAndUnpack(${JSON.stringify(packed)})`, context);
  check('words are substituted', flat === 'var alpha beta', flat);

  const untouched = vm.runInContext("getAndUnpack('var a = 1;')", context);
  check('code that is not packed comes back unchanged', untouched === 'var a = 1;', untouched);
});

await run('solveCaptcha explains itself instead of hanging', async () => {
  const context = createContext();
  const message = vm.runInContext(
    "(function(){ try { solveCaptcha('x'); return 'no error'; } catch (e) { return e.message; } })()",
    context,
  );
  check('it throws with a reason', String(message).includes('browser'), message);
});

await run('State isolation between contexts', async () => {
  const first = createContext();
  const second = createContext();
  vm.runInContext('globalThis.secret = 42;', first);
  check('contexts do not share globals',
    vm.runInContext('typeof globalThis.secret', second) === 'undefined');
});

// ---------------------------------------------------------------------------

console.log(`\n${passes} passed, ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
