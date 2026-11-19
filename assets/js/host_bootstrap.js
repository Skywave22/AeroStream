/*
 * AeroStream JavaScript host bootstrap.
 *
 * Injected into every plugin context before the plugin's own code runs. It
 * gives plugins the surface the ecosystems assume (SkyStream's `MultimediaItem`,
 * `http_get`, `parseHtml`, …) and turns every host interaction into a queued
 * call that the Dart side services. Nothing here touches the network, the
 * filesystem or timers directly: the host owns all of that, applies policy and
 * can kill the context.
 *
 * Protocol (driven entirely by the host, so it works on any engine):
 *   __aeroInvoke(fn, argsJson)  -> starts a plugin call
 *   __aeroPoll()                -> next queued host call, the result, or null
 *   __aeroResolve(id, json, err) -> answers a host call
 *   __aeroDrainLogs()           -> console output collected since last drain
 */
(function () {
  'use strict';

  var state = {
    seq: 0,
    calls: [],
    pending: {},
    timers: {},
    logs: [],
    done: null,
    error: null
  };

  globalThis.__aero = state;

  // ---- console ----------------------------------------------------------

  function record(level, args) {
    var text = [];
    for (var i = 0; i < args.length; i++) {
      var value = args[i];
      if (typeof value === 'string') {
        text.push(value);
      } else {
        try {
          text.push(JSON.stringify(value));
        } catch (e) {
          text.push(String(value));
        }
      }
    }
    state.logs.push({ level: level, message: text.join(' ') });
    // Bound the buffer so a logging loop cannot exhaust the sandbox memory.
    if (state.logs.length > 500) state.logs.splice(0, state.logs.length - 500);
  }

  globalThis.console = {
    log: function () { record('info', arguments); },
    info: function () { record('info', arguments); },
    warn: function () { record('warn', arguments); },
    error: function () { record('error', arguments); },
    debug: function () { record('debug', arguments); }
  };

  // ---- host bridge ------------------------------------------------------

  globalThis.sendMessage = function (channel, payload) {
    var id = 'c' + (++state.seq);
    return new Promise(function (resolve, reject) {
      state.pending[id] = { resolve: resolve, reject: reject };
      state.calls.push({
        id: id,
        channel: channel,
        payload: typeof payload === 'string' ? payload : JSON.stringify(payload)
      });
    });
  };

  globalThis.__aeroInvoke = function (fnName, argsJson) {
    state.done = null;
    state.error = null;
    var fn = globalThis[fnName];
    if (typeof fn !== 'function') {
      state.error = { message: 'Plugin does not implement ' + fnName, kind: 'unsupported' };
      return '{"started":false}';
    }

    var args = [];
    try {
      args = JSON.parse(argsJson || '[]');
    } catch (e) {
      args = [];
    }

    function settle(ok, payload) {
      if (state.done || state.error) return;
      if (ok) {
        state.done = { value: payload === undefined ? null : payload };
      } else {
        state.error = payload;
      }
    }

    // SkyStream plugins are callback-based: `getHome(cb)`. Vega providers
    // return promises. Support both without the caller caring.
    var callback = function (res) {
      if (res && typeof res === 'object' && 'success' in res) {
        if (res.success === false) {
          settle(false, {
            message: res.message || res.errorCode || 'plugin reported an error',
            code: res.errorCode,
            kind: 'plugin'
          });
        } else {
          settle(true, res.data);
        }
      } else {
        settle(true, res);
      }
    };

    try {
      var result = fn.length > args.length
        ? fn.apply(null, args.concat([callback]))
        : fn.apply(null, args);
      if (result && typeof result.then === 'function') {
        result.then(function (value) { settle(true, value); },
                    function (error) { settle(false, describe(error)); });
      }
    } catch (error) {
      settle(false, describe(error));
    }
    return '{"started":true}';
  };

  function describe(error) {
    if (!error) return { message: 'unknown error', kind: 'plugin' };
    if (typeof error === 'string') return { message: error, kind: 'plugin' };
    return {
      message: String(error.message || error),
      stack: error.stack ? String(error.stack) : undefined,
      kind: 'plugin'
    };
  }

  globalThis.__aeroPoll = function () {
    if (state.calls.length > 0) {
      return JSON.stringify(state.calls.shift());
    }
    if (state.error) {
      var error = state.error;
      state.error = null;
      return JSON.stringify({ done: true, error: error });
    }
    if (state.done) {
      var value = state.done.value;
      state.done = null;
      return JSON.stringify({ done: true, value: value === undefined ? null : value });
    }
    return 'null';
  };

  globalThis.__aeroResolve = function (id, json, isError) {
    var entry = state.pending[id];
    if (!entry) return '{"ok":false}';
    delete state.pending[id];
    var value;
    try {
      value = json === undefined || json === null ? null : JSON.parse(json);
    } catch (e) {
      value = json;
    }
    if (isError) {
      entry.reject(new Error(typeof value === 'object' && value && value.message ? value.message : String(value)));
    } else {
      entry.resolve(value);
    }
    return '{"ok":true}';
  };

  globalThis.__aeroDrainLogs = function () {
    var drained = state.logs;
    state.logs = [];
    return JSON.stringify(drained);
  };

  globalThis.__aeroCancelAll = function (reason) {
    var keys = Object.keys(state.pending);
    for (var i = 0; i < keys.length; i++) {
      try {
        state.pending[keys[i]].reject(new Error(reason || 'cancelled'));
      } catch (e) {
        // ignore
      }
    }
    state.calls = [];
    state.pending = {};
  };

  // ---- timers -----------------------------------------------------------
  // QuickJS has no event loop, so timer callbacks are queued as host calls and
  // fired by the host after the delay, on this context's thread.

  globalThis.setTimeout = function (fn, ms) {
    var id = 't' + (++state.seq);
    state.timers[id] = fn;
    state.calls.push({
      id: 'timer:' + id,
      channel: 'timer',
      payload: JSON.stringify({ ms: ms || 0, timerId: id })
    });
    return id;
  };

  globalThis.clearTimeout = function (id) {
    if (id) delete state.timers[id];
  };

  globalThis.setInterval = function () {
    // Intervals are not supported: a repeating timer keeps a plugin alive
    // forever and there is no cancellation path that a plugin respects.
    return 'interval-unsupported';
  };

  globalThis.clearInterval = function () {};

  globalThis.__aeroFireTimer = function (id) {
    var fn = state.timers[id];
    delete state.timers[id];
    if (typeof fn === 'function') {
      try {
        fn();
      } catch (e) {
        record('error', ['timer callback failed: ' + e]);
      }
    }
    return '{"ok":true}';
  };

  // ---- SkyStream model classes -----------------------------------------

  function model(name) {
    var ctor = function (props) {
      if (props && typeof props === 'object') {
        for (var key in props) {
          if (Object.prototype.hasOwnProperty.call(props, key)) this[key] = props[key];
        }
      }
    };
    try {
      Object.defineProperty(ctor, 'name', { value: name });
    } catch (e) {
      // older engines: the name is cosmetic
    }
    return ctor;
  }

  globalThis.MultimediaItem = model('MultimediaItem');
  globalThis.StreamResult = model('StreamResult');
  globalThis.Episode = model('Episode');
  globalThis.Actor = model('Actor');
  globalThis.Trailer = model('Trailer');
  globalThis.NextAiring = model('NextAiring');
  globalThis.Season = model('Season');

  // ---- HTTP (SkyStream + generic) --------------------------------------

  globalThis.http_get = function (url, headers) {
    return sendMessage('http:get', JSON.stringify({ url: url, headers: headers || {} }));
  };

  globalThis.http_post = function (url, headers, body) {
    return sendMessage('http:post', JSON.stringify({ url: url, headers: headers || {}, body: body }));
  };

  globalThis.http_batch = function (requests) {
    return sendMessage('http:batch', JSON.stringify({ requests: requests || [] }));
  };

  globalThis.fetch = function (url, options) {
    var opts = options || {};
    var headers = opts.headers || {};
    if (opts.method && String(opts.method).toUpperCase() === 'POST') {
      return http_post(String(url), headers, opts.body);
    }
    return http_get(String(url), headers);
  };

  // ---- HTML -------------------------------------------------------------

  globalThis.parseHtml = function (html) {
    return sendMessage('html:parse', JSON.stringify({ html: html }));
  };

  globalThis.parse_html = function (html, selector, attribute) {
    return sendMessage('html:select', JSON.stringify({
      html: html,
      selector: selector,
      attribute: attribute
    }));
  };

  globalThis.select = function (doc, selector, attribute) {
    return sendMessage('html:query', JSON.stringify({
      doc: doc,
      selector: selector,
      attribute: attribute
    }));
  };

  globalThis.attr = function (doc, selector, attribute) {
    return sendMessage('html:attr', JSON.stringify({
      doc: doc,
      selector: selector,
      attribute: attribute
    }));
  };

  globalThis.text = function (doc, selector) {
    return sendMessage('html:text', JSON.stringify({ doc: doc, selector: selector }));
  };

  // ---- crypto / encoding ------------------------------------------------

  globalThis.crypto = {
    md5: function (input) { return sendMessage('crypto:md5', JSON.stringify({ input: String(input) })); },
    sha256: function (input) { return sendMessage('crypto:sha256', JSON.stringify({ input: String(input) })); },
    hmac: function (algorithm, key, message) {
      return sendMessage('crypto:hmac', JSON.stringify({
        algorithm: algorithm, key: key, message: message
      }));
    },
    aesDecrypt: function (payload) {
      return sendMessage('crypto:aes', JSON.stringify(payload || {}));
    },
    base64Encode: function (input) {
      return sendMessage('text:b64encode', JSON.stringify({ input: input }));
    },
    base64Decode: function (input) {
      return sendMessage('text:b64decode', JSON.stringify({ input: String(input) }));
    }
  };

  globalThis.atob = function (input) {
    return sendMessage('text:b64decode', JSON.stringify({ input: String(input) }));
  };

  globalThis.btoa = function (input) {
    return sendMessage('text:b64encode', JSON.stringify({ input: String(input) }));
  };

  // ---- storage ----------------------------------------------------------

  globalThis.storage = {
    get: function (key, fallback) {
      return sendMessage('storage:get', JSON.stringify({ key: key, fallback: fallback === undefined ? null : fallback }));
    },
    set: function (key, value) {
      return sendMessage('storage:set', JSON.stringify({ key: key, value: value }));
    },
    remove: function (key) {
      return sendMessage('storage:remove', JSON.stringify({ key: key }));
    }
  };

  // ---- polyfills --------------------------------------------------------

  function pad(value, width) {
    var text = String(value);
    while (text.length < width) text = '0' + text;
    return text;
  }

  globalThis.TextEncoder = function () {};
  globalThis.TextEncoder.prototype.encode = function (input) {
    var text = String(input === undefined ? '' : input);
    var codes = [];
    for (var i = 0; i < text.length; i++) {
      var code = text.charCodeAt(i);
      if (code < 0x80) {
        codes.push(code);
      } else if (code < 0x800) {
        codes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else {
        codes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      }
    }
    var bytes = new Uint8Array(codes.length);
    for (var j = 0; j < codes.length; j++) bytes[j] = codes[j];
    return bytes;
  };

  if (typeof globalThis.URL === 'undefined') {
    globalThis.URL = function (url, base) {
      var full = String(url);
      if (base && full.indexOf('://') < 0) {
        full = String(base).replace(/\/+$/, '') + '/' + full.replace(/^\/+/, '');
      }
      var match = /^([a-z]+):\/\/([^/?#]+)([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(full);
      this.href = full;
      this.protocol = match ? match[1] + ':' : '';
      this.host = match ? match[2] : '';
      this.hostname = match ? match[2].split(':')[0] : '';
      this.pathname = match ? (match[3] || '/') : '';
      this.search = match && match[4] ? match[4] : '';
      this.hash = match && match[5] ? match[5] : '';
      this.searchParams = new globalThis.URLSearchParams(this.search);
    };
    globalThis.URL.prototype.toString = function () { return this.href; };
  }

  if (typeof globalThis.URLSearchParams === 'undefined') {
    globalThis.URLSearchParams = function (init) {
      var pairs = [];
      var text = String(init || '').replace(/^\?/, '');
      if (text.length) {
        var parts = text.split('&');
        for (var i = 0; i < parts.length; i++) {
          if (!parts[i].length) continue;
          var kv = parts[i].split('=');
          pairs.push([decodeURIComponent(kv[0]), decodeURIComponent(kv.slice(1).join('='))]);
        }
      }
      this._pairs = pairs;
      var self = this;
      this.get = function (key) {
        for (var i = 0; i < self._pairs.length; i++) {
          if (self._pairs[i][0] === key) return self._pairs[i][1];
        }
        return null;
      };
      this.append = function (key, value) { self._pairs.push([String(key), String(value)]); };
      this.set = function (key, value) {
        for (var i = 0; i < self._pairs.length; i++) {
          if (self._pairs[i][0] === key) { self._pairs[i][1] = String(value); return; }
        }
        self._pairs.push([String(key), String(value)]);
      };
      this.toString = function () {
        var out = [];
        for (var i = 0; i < self._pairs.length; i++) {
          out.push(encodeURIComponent(self._pairs[i][0]) + '=' + encodeURIComponent(self._pairs[i][1]));
        }
        return out.join('&');
      };
      this.has = function (key) { return self.get(key) !== null; };
    };
  }

  // A deterministic PRNG: plugins use Math.random for request jitter, and a
  // seedable generator keeps golden tests reproducible.
  var seed = 0x2f6e2b1;
  globalThis.Math.random = function () {
    seed ^= seed << 13;
    seed ^= seed >>> 17;
    seed ^= seed << 5;
    seed &= 0xffffffff;
    return ((seed >>> 0) % 1000000) / 1000000;
  };

  globalThis.pad2 = function (value) { return pad(value, 2); };
})();
