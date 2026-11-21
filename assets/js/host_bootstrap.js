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

  // Plugin return values can be anything, including DOM nodes with parent
  // cycles. Serialising must never take the context down.
  function safeStringify(value) {
    var seen = [];
    try {
      return JSON.stringify(value, function (key, item) {
        if (typeof item === 'function') return undefined;
        if (item && typeof item === 'object') {
          if (seen.indexOf(item) >= 0) return undefined;
          seen.push(item);
        }
        return item;
      });
    } catch (error) {
      return JSON.stringify({ message: 'unserialisable plugin result' });
    }
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
        payload: typeof payload === 'string' ? payload : safeStringify(payload)
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
    //
    // The callback is appended to *every* call, which is what SkyStream's own
    // engine does. Counting declared parameters instead looks equivalent and is
    // not: `getHome()` written with a default (`function (cb = () => {})`) or
    // with a rest parameter reports `fn.length === 0`, so an arity guess hands
    // it no callback at all and the invoke hangs until the host times out.
    // Extra arguments are ignored by functions that do not want them.
    function accept(res) {
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
    }

    var callback = function (res) {
      accept(res);
    };

    try {
      var result = fn.apply(null, args.concat([callback]));
      if (result && typeof result.then === 'function') {
        // Promise-style: the callback may still fire, settle() keeps the first.
        result.then(
          function (value) { accept(value); },
          function (error) { settle(false, describe(error)); }
        );
      } else if (result !== undefined) {
        // Plain synchronous return: no callback will ever come.
        accept(result);
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
      return safeStringify(state.calls.shift());
    }
    if (state.error) {
      var error = state.error;
      state.error = null;
      return safeStringify({ done: true, error: error });
    }
    if (state.done) {
      var value = state.done.value;
      state.done = null;
      return safeStringify({ done: true, value: value === undefined ? null : value });
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

  // SkyStream's name for the same thing: many requests, one round trip.
  globalThis.http_parallel = globalThis.http_batch;

  /**
   * P.A.C.K.E.R. deobfuscation.
   *
   * SkyStream ships this as a native helper; a plugin that scrapes an
   * obfuscated player config calls it and gets readable JS back. The algorithm
   * is the packed payload's own: decode the base-62 dictionary and substitute
   * each word. It is plain string work, so it lives here rather than crossing
   * the sandbox boundary.
   */
  globalThis.getAndUnpack = function (js) {
    return unpack(js);
  };

  function unpack(js) {
    var text = String(js === undefined || js === null ? '' : js);
    // The packed call is the last `}('…', 62, N, '…'.split('|'), 0, {})`.
    var call = /\}\s*\(\s*([\'"])/g;
    var last = null;
    var match;
    while ((match = call.exec(text)) !== null) last = match;
    if (!last) return text;

    var quoteIndex = last.index + last[0].length - 1;
    var payload = readJsString(text, quoteIndex);
    if (!payload) return text;

    var rest = text.slice(payload.end);
    var numbers = /^\s*,\s*(\d+)\s*,\s*(\d+)\s*,/.exec(rest);
    if (!numbers) return text;

    var dictString = readJsString(rest, numbers[0].length);
    if (!dictString) return text;

    var base = parseInt(numbers[1], 10);
    var count = parseInt(numbers[2], 10);
    if (!(base > 1) || !(count >= 0)) return text;

    // The dictionary is a string split on a separator the packer picks.
    var splitCall = /^\s*\.split\(\s*(['"])([\s\S]?)\1/.exec(
      rest.slice(dictString.end)
    );
    var separator = splitCall && splitCall[2] ? splitCall[2] : '|';
    var words = dictString.text.split(separator);

    var decodeWord = function (value) {
      return (value < base ? '' : decodeWord(Math.floor(value / base))) +
        ((value = value % base) > 35
          ? String.fromCharCode(value + 29)
          : value.toString(36));
    };

    var dictionary = {};
    for (var index = 0; index < count; index++) {
      dictionary[decodeWord(index)] = words[index] || decodeWord(index);
    }
    return payload.text.replace(/\b\w+\b/g, function (word) {
      return Object.prototype.hasOwnProperty.call(dictionary, word)
        ? dictionary[word]
        : word;
    });
  }

  /** Reads a JS string literal starting at `index` (which holds the quote). */
  function readJsString(text, index) {
    var quote = text.charAt(index);
    if (quote !== "'" && quote !== '"') return null;
    var out = '';
    for (var i = index + 1; i < text.length; i++) {
      var ch = text.charAt(i);
      if (ch === '\\') {
        var next = text.charAt(i + 1);
        if (next === 'n') out += '\n';
        else if (next === 'r') out += '\r';
        else if (next === 't') out += '\t';
        else if (next === '\\') out += '\\';
        else if (next === quote) out += quote;
        else if (next === '0') out += '\0';
        else out += next;
        i++;
        continue;
      }
      if (ch === quote) return { text: out, end: i + 1 };
      out += ch;
    }
    return null;
  }

  /**
   * Captchas cannot be solved without a browser, and AeroStream does not embed
   * one. Failing loudly with the reason is better than a plugin hanging on a
   * promise that never settles.
   */
  globalThis.solveCaptcha = function () {
    throw new Error(
      'solveCaptcha is not available in AeroStream: it needs a browser widget'
    );
  };

  /**
   * `fetch` as the two ecosystems' bundles use it.
   *
   * Both call sites read a Response, not AeroStream's internal reply object:
   * Vega's provider bundles do `if (!res.ok) throw …; await res.text()`, and
   * SkyStream plugins reach for `res.json()` and `res.headers.get()`. Handing
   * them `{status, url, body}` made `res.ok` undefined, so every Vega provider
   * threw on its first request. This wraps the reply in the fetch surface they
   * expect, with the body kept as text and parsed on demand.
   */
  function aeroResponse(reply) {
    var raw = reply && reply.body !== undefined && reply.body !== null
      ? String(reply.body)
      : '';
    var status = reply && typeof reply.status === 'number' ? reply.status : 0;
    var headerMap = (reply && reply.headers) || {};

    function findHeader(name) {
      var wanted = String(name).toLowerCase();
      for (var key in headerMap) {
        if (Object.prototype.hasOwnProperty.call(headerMap, key) &&
            String(key).toLowerCase() === wanted) {
          return headerMap[key];
        }
      }
      return null;
    }

    var response = {
      ok: status >= 200 && status < 300,
      status: status,
      statusText: '',
      url: (reply && reply.url) || '',
      redirected: false,
      type: 'basic',
      headers: {
        get: function (name) { return findHeader(name); },
        has: function (name) { return findHeader(name) !== null; },
        forEach: function (fn) {
          for (var key in headerMap) {
            if (Object.prototype.hasOwnProperty.call(headerMap, key)) {
              fn(headerMap[key], key, this);
            }
          }
        },
        entries: function () {
          var out = [];
          for (var key in headerMap) {
            if (Object.prototype.hasOwnProperty.call(headerMap, key)) {
              out.push([key, headerMap[key]]);
            }
          }
          return out;
        },
        raw: function () { return headerMap; }
      },
      // Not part of the fetch API (where `body` is a stream), but plugins
      // written against SkyStream's looser `fetch` read the text here.
      body: raw,
      text: function () { return Promise.resolve(raw); },
      json: function () {
        return new Promise(function (resolve, reject) {
          try {
            resolve(JSON.parse(raw));
          } catch (error) {
            reject(error);
          }
        });
      },
      clone: function () {
        return aeroResponse({
          status: status,
          body: raw,
          headers: headerMap,
          url: (reply && reply.url) || ''
        });
      }
    };
    return response;
  }

  globalThis.fetch = function (url, options) {
    var opts = options || {};
    var headers = opts.headers || {};
    var request = opts.method && String(opts.method).toUpperCase() === 'POST'
      ? http_post(String(url), headers, opts.body)
      : http_get(String(url), headers);
    return request.then(aeroResponse);
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
    // SkyStream's SDK signature: crypto.decryptAES(data, key, iv).
    decryptAES: function (data, key, iv) {
      return sendMessage('crypto:aes', JSON.stringify({
        data: data, key: key, iv: iv
      }));
    },
    base64Encode: function (input) {
      return sendMessage('text:b64encode', JSON.stringify({ input: input }));
    },
    base64Decode: function (input) {
      return sendMessage('text:b64decode', JSON.stringify({ input: String(input) }));
    }
  };

  // Base64 the way the web platform defines it — synchronously. The bridge is
  // promise-shaped, so these cannot cross it: SkyStream ships pure-JS
  // implementations for exactly this reason.
  var B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  globalThis.atob = function (input) {
    var text = String(input === undefined || input === null ? '' : input).replace(/\s+/g, '');
    var output = [];
    var buffer = 0, bits = 0;
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i);
      if (ch === '=') break;
      var value = B64_ALPHABET.indexOf(ch);
      if (value < 0) throw new Error("Failed to execute 'atob' on 'Window': The string to be decoded contains characters outside of the Latin1 range.");
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        output.push(String.fromCharCode((buffer >>> bits) & 0xff));
      }
    }
    return output.join('');
  };
  globalThis.btoa = function (input) {
    var text = String(input === undefined || input === null ? '' : input);
    var output = '';
    for (var i = 0; i < text.length; i += 3) {
      var a = text.charCodeAt(i);
      var b = i + 1 < text.length ? text.charCodeAt(i + 1) : NaN;
      var c = i + 2 < text.length ? text.charCodeAt(i + 2) : NaN;
      if (a > 0xff || (b === b && b > 0xff) || (c === c && c > 0xff)) {
        throw new Error("Failed to execute 'btoa' on 'Window': The string to be encoded contains characters outside of the Latin1 range.");
      }
      var n = (a << 16) | ((isNaN(b) ? 0 : b) << 8) | (isNaN(c) ? 0 : c);
      output += B64_ALPHABET.charAt((n >>> 18) & 63) + B64_ALPHABET.charAt((n >>> 12) & 63);
      output += isNaN(b) ? '=' : B64_ALPHABET.charAt((n >>> 6) & 63);
      output += isNaN(c) ? '=' : B64_ALPHABET.charAt(n & 63);
    }
    return output;
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

  function removeDotSegments(path) {
    var segments = String(path).split('/');
    var out = [];
    for (var i = 0; i < segments.length; i++) {
      var segment = segments[i];
      if (segment === '.') continue;
      if (segment === '..') { out.pop(); continue; }
      out.push(segment);
    }
    var joined = out.join('/');
    if (path.charAt(0) === '/' && joined.charAt(0) !== '/') joined = '/' + joined;
    // A trailing slash on input is significant for directories.
    if (path.length > 1 && path.charAt(path.length - 1) === '/' && joined.charAt(joined.length - 1) !== '/') joined += '/';
    return joined;
  }

  function parseUrl(href) {
    var match = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(href);
    if (!match) throw new Error('Invalid URL');
    var authority = match[2];
    var path = match[3] || '/';
    path = removeDotSegments(path);
    if (path.charAt(0) !== '/') path = '/' + path;
    var hostParts = authority.split('@'); // strip userinfo
    var host = hostParts[hostParts.length - 1];
    var port = '';
    var portIndex = host.lastIndexOf(':');
    if (portIndex >= 0 && /^[0-9]+$/.test(host.slice(portIndex + 1))) {
      port = host.slice(portIndex + 1);
      host = host.slice(0, portIndex);
    }
    return {
      protocol: match[1].toLowerCase() + ':',
      host: authority.split('@').pop(),
      hostname: host.toLowerCase(),
      port: port,
      pathname: path,
      search: match[4] || '',
      hash: match[5] || ''
    };
  }

  globalThis.URL = function (url, base) {
    var input = String(url === undefined || url === null ? '' : url).trim();
    if (!input) throw new Error('Invalid URL');

    var baseParts = null;
    if (base !== undefined) {
      var baseHref = String(base === undefined || base === null ? '' : base).trim();
      if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(baseHref)) throw new Error('Invalid URL');
      baseParts = parseUrl(baseHref);
    }

    var href;
    var hasScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(input);
    if (hasScheme) {
      if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(input)) throw new Error('Invalid URL');
      href = input;
    } else if (!baseParts) {
      throw new Error('Invalid URL');
    } else if (input.indexOf('//') === 0) {
      href = baseParts.protocol + input;
    } else if (input.charAt(0) === '/') {
      href = baseParts.protocol + '//' + baseParts.host + removeDotSegments(input);
    } else if (input.charAt(0) === '?') {
      href = baseParts.protocol + '//' + baseParts.host + baseParts.pathname + input;
    } else if (input.charAt(0) === '#') {
      href = baseParts.protocol + '//' + baseParts.host + baseParts.pathname + baseParts.search + input;
    } else {
      var dir = baseParts.pathname.replace(/\/[^/]*$/, '/');
      href = baseParts.protocol + '//' + baseParts.host + dir + input;
    }

    var parts = parseUrl(href);
    this.protocol = parts.protocol;
    this.host = parts.host;
    this.hostname = parts.hostname;
    this.port = parts.port;
    this.pathname = parts.pathname;
    this.search = parts.search;
    this.hash = parts.hash;
    this.origin = this.protocol + '//' + this.host;
    this.href = this.origin + this.pathname + this.search + this.hash;
    this.searchParams = new globalThis.URLSearchParams(this.search);
  };
  globalThis.URL.prototype.toString = function () { return this.href; };
  globalThis.URL.prototype.toJSON = function () { return this.href; };

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
      this.delete = function (key) {
        self._pairs = self._pairs.filter(function (pair) { return pair[0] !== key; });
      };
      this.getAll = function (key) {
        var out = [];
        for (var i = 0; i < self._pairs.length; i++) {
          if (self._pairs[i][0] === key) out.push(self._pairs[i][1]);
        }
        return out;
      };
      this.forEach = function (fn) {
        for (var i = 0; i < self._pairs.length; i++) {
          fn(self._pairs[i][1], self._pairs[i][0], self);
        }
      };
      this.toString = function () {
        var out = [];
        for (var i = 0; i < self._pairs.length; i++) {
          out.push(encodeURIComponent(self._pairs[i][0]) + '=' + encodeURIComponent(self._pairs[i][1]));
        }
        return out.join('&');
      };
    };
  }

  // Providers are written against the DOM. They rarely race requests, but
  // enough of them construct an AbortController at call time that its absence
  // is a crash, not a feature.
  if (typeof globalThis.AbortController === 'undefined') {
    globalThis.AbortController = function () {
      var listeners = [];
      var signal = {
        aborted: false,
        addEventListener: function (type, fn) { listeners.push(fn); },
        removeEventListener: function (type, fn) {
          listeners = listeners.filter(function (entry) { return entry !== fn; });
        },
        onabort: null
      };
      this.signal = signal;
      this.abort = function () {
        if (signal.aborted) return;
        signal.aborted = true;
        var copy = listeners.slice();
        for (var i = 0; i < copy.length; i++) {
          try { copy[i].call(signal); } catch (e) { /* a listener's failure is not ours */ }
        }
        if (typeof signal.onabort === 'function') {
          try { signal.onabort.call(signal, { type: 'abort' }); } catch (e) { /* ditto */ }
        }
      };
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
