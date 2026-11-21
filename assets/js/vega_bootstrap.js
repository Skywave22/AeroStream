/*
 * AeroStream Vega host bootstrap.
 *
 * Vega providers are CommonJS bundles exporting `getPosts`, `getSearchPosts`,
 * `getMeta`, `getStream`, `getCatalog` and friends. They expect a cheerio-like
 * DOM, an axios-like client and an injected `providerContext`.
 *
 * Everything they expect is provided here, inside the sandbox, on top of the
 * same host bridge SkyStream plugins use - so a Vega provider has exactly the
 * same permissions as a SkyStream plugin: none of its own.
 */
(function (global) {
  'use strict';

  var modules = {};
  global.__vega = { modules: modules };

  // ---- axios-like client -------------------------------------------------

  function readBody(response, config) {
    var body = response && response.body;
    var wantsJson = config && (config.responseType === 'json');
    if (!wantsJson && config && config.transformResponse) wantsJson = true;
    if (!wantsJson && body && typeof body === 'string') {
      var trimmed = body.replace(/^\s+/, '');
      if (trimmed.charAt(0) === '{' || trimmed.charAt(0) === '[') wantsJson = true;
    }
    if (wantsJson && typeof body === 'string') {
      try {
        return JSON.parse(body);
      } catch (e) {
        return body;
      }
    }
    return body;
  }

  // The origin a provider last reached. Providers publish links relative to
  // their own site (`/download-the-good-doctor-.../`), and the extraction step
  // that follows is handed that path rather than an absolute URL. Without an
  // origin the request shim refuses it ("Scheme "" is not allowed"), which is
  // how a working provider failed at the last step. Vega's own context exposes
  // this as `getBaseUrl`.
  var lastOrigin = null;

  function absoluteUrl(url) {
    var text = String(url || '');
    if (!text) return text;
    if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(text)) return text;
    if (text.charAt(0) === '/' && lastOrigin) return lastOrigin + text;
    return text;
  }

  // Providers hand links around as paths; the adapter turns them back into
  // absolute URLs with this, so the extraction step receives a real URL.
  global.__vegaOrigin = function () { return lastOrigin || null; };

  function rememberOrigin(url) {
    var match = /^(https?:\/\/[^/]+)/i.exec(String(url || ''));
    if (match) lastOrigin = match[1];
  }

  // Query parameters, the axios way: scalars only, null/undefined dropped,
  // arrays repeated. Appended before the request leaves, so the host never
  // sees a half-built query string.
  function appendParams(url, params) {
    if (!params || typeof params !== 'object') return url;
    var parts = [];
    for (var key in params) {
      if (!Object.prototype.hasOwnProperty.call(params, key)) continue;
      var value = params[key];
      if (value === undefined || value === null) continue;
      if (Array.isArray(value)) {
        for (var i = 0; i < value.length; i++) {
          parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(value[i])));
        }
      } else {
        parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(value)));
      }
    }
    if (!parts.length) return url;
    var query = parts.join('&');
    return url + (url.indexOf('?') === -1 ? '?' : (url.endsWith('&') || url.endsWith('?') ? '' : '&')) + query;
  }

  function request(config) {
    var options = config || {};
    var headers = options.headers || {};
    var method = String(options.method || 'GET').toUpperCase();
    var url = String(options.url || options.baseURL || '');
    if (options.baseURL && options.url && url.indexOf('://') < 0) {
      url = String(options.baseURL).replace(/\/+$/, '') + '/' + String(options.url).replace(/^\/+/, '');
    }

    url = appendParams(url, options.params);
    url = absoluteUrl(url);
    var channel = method === 'POST' ? 'http:post' : (method === 'HEAD' ? 'http:head' : 'http:get');
    var payload = JSON.stringify({
      url: url,
      headers: headers,
      body: options.data,
      // Providers read redirects themselves (`maxRedirects: 0` + the Location
      // header, or validateStatus over 3xx). The host honours the flag per
      // request; everything else keeps the default safe following.
      followRedirects: options.maxRedirects === 0 ? false : undefined
    });

    return sendMessage(channel, payload).then(function (response) {
      rememberOrigin(url);
      var status = response && response.status;
      var result = {
        data: readBody(response, options),
        status: status,
        statusText: status === 200 ? 'OK' : '',
        headers: (response && response.headers) || {},
        config: options,
        request: {}
      };
      if (options.validateStatus ? !options.validateStatus(status) : status >= 400) {
        var error = new Error('Request failed with status code ' + status);
        error.response = result;
        error.config = options;
        throw error;
      }
      return result;
    });
  }

  function createInstance(defaults) {
    var base = defaults || {};
    function instance(config) {
      var merged = {};
      var key;
      for (key in base) {
        if (Object.prototype.hasOwnProperty.call(base, key)) merged[key] = base[key];
      }
      for (key in config || {}) {
        if (Object.prototype.hasOwnProperty.call(config, key)) merged[key] = config[key];
      }
      merged.headers = Object.assign({}, base.headers || {}, (config && config.headers) || {});
      return request(merged);
    }
    instance.request = request;
    instance.get = function (url, config) {
      return instance(Object.assign({}, config || {}, { url: url, method: 'GET' }));
    };
    instance.delete = instance.get;
    instance.head = function (url, config) {
      return instance(Object.assign({}, config || {}, { url: url, method: 'HEAD' }));
    };
    instance.post = function (url, data, config) {
      return instance(Object.assign({}, config || {}, { url: url, method: 'POST', data: data }));
    };
    instance.put = instance.post;
    instance.patch = instance.post;
    instance.create = createInstance;
    instance.defaults = base;

    instance.interceptors = {
      request: { use: function () {} },
      response: { use: function () {} }
    };
    return instance;
  }

  var axios = createInstance({ headers: {} });
  global.axios = axios;

  // ---- crypto / utils ----------------------------------------------------

  function digest(channel, input) {
    return sendMessage(channel, JSON.stringify({ input: String(input) }));
  }

  var cryptoShim = {
    md5: function (input) { return digest('crypto:md5', input); },
    sha256: function (input) { return digest('crypto:sha256', input); },
    hmac: function (algorithm, key, message) {
      return sendMessage('crypto:hmac', JSON.stringify({
        algorithm: algorithm, key: key, message: message
      }));
    },
    createHash: function (algorithm) {
      var chunks = [];
      return {
        update: function (value) { chunks.push(String(value)); return this; },
        digest: function () {
          return digest(algorithm === 'sha256' ? 'crypto:sha256' : 'crypto:md5', chunks.join(''));
        }
      };
    }
  };

  var utils = {
    base64Encode: function (input) {
      return sendMessage('text:b64encode', JSON.stringify({ input: input }));
    },
    base64Decode: function (input) {
      return sendMessage('text:b64decode', JSON.stringify({ input: String(input) }));
    },
    sleep: function (ms) {
      return new Promise(function (resolve) { setTimeout(resolve, ms); });
    },
    md5: function (input) { return digest('crypto:md5', input); },
    sha256: function (input) { return digest('crypto:sha256', input); }
  };

  // ---- provider context --------------------------------------------------
  // Vega providers receive this as `providerContext`. It is the documented
  // AeroStream surface: HTTP, DOM, crypto, and nothing else.

  function providerContext(providerValue) {
    return {
      axios: axios,
      cheerio: global.cheerioLite,
      crypto: cryptoShim,
      // Vega's own context names the crypto module `Crypto` and the shared
      // platform headers `commonHeaders`; providers destructure those names.
      Crypto: cryptoShim,
      commonHeaders: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9'
      },
      utils: utils,
      providerValue: providerValue === undefined ? null : providerValue,
      getBaseUrl: function () { return Promise.resolve(lastOrigin); },
      headers: {},
      // Nothing persists between launches on this build, but a provider that
      // calls the key-value surface must not crash on its absence.
      kvStore: {
        get: function () { return Promise.resolve(undefined); },
        set: function () { return Promise.resolve(); },
        remove: function () { return Promise.resolve(); },
        delete: function () { return Promise.resolve(); },
        keys: function () { return Promise.resolve([]); },
        clear: function () { return Promise.resolve(); }
      }
    };
  }

  global.__vegaProviderContext = providerContext;

  // ---- CommonJS module loader -------------------------------------------

  function requireShim(name) {
    var key = String(name);
    if (key === 'axios' || key === 'node-fetch' || key === 'cross-fetch' || key === 'got') {
      return axios;
    }
    if (key === 'cheerio' || key === 'cheerio-htmlparser2') return global.cheerioLite;
    if (key === 'crypto' || key === 'crypto-js') return cryptoShim;
    if (modules[key]) return modules[key];

    var relative = key.replace(/^\.\//, '').replace(/\.js$/, '');
    if (modules[relative]) return modules[relative];
    var base = relative.split('/').pop();
    if (modules[base]) return modules[base];

    // Unknown modules resolve to an empty object: a provider that requires a
    // helper it does not use must not fail to load.
    return {};
  }

  global.__vegaRequire = requireShim;

  /** Loads one provider module source into the sandbox. */
  global.__vegaLoad = function (name, source) {
    var module = { exports: {} };
    try {
      var factory = new Function(
        'module',
        'exports',
        'require',
        'globalThis',
        'console',
        String(source) + '\n//# sourceURL=vega:' + name + '.js'
      );
      factory(module, module.exports, requireShim, global, global.console);
    } catch (error) {
      return JSON.stringify({
        ok: false,
        error: String((error && error.message) || error)
      });
    }
    var exported = module.exports;
    if (!exported || (typeof exported === 'object' && Object.keys(exported).length === 0)) {
      exported = module.exports = exported || {};
    }
    modules[name] = exported;
    return JSON.stringify({ ok: true, keys: Object.keys(exported || {}) });
  };

  /** True when a module is loaded and exports [fnName]. */
  global.__vegaHas = function (name, fnName) {
    var module = modules[name];
    if (!module) return 'false';
    if (typeof module[fnName] === 'function') return 'true';
    if (module.default && typeof module.default[fnName] === 'function') return 'true';
    return 'false';
  };

  /** Keys a module exports, for capability reporting. */
  global.__vegaKeys = function (name) {
    var module = modules[name];
    return JSON.stringify(module ? Object.keys(module) : []);
  };

  /**
   * Calls an exported provider function with a single options object, which is
   * the Vega calling convention.
   */
  global.__vegaCall = function (moduleName, fnName, argsJson) {
    var module = modules[moduleName];
    if (!module) throw new Error('Provider module not loaded: ' + moduleName);
    var fn = module[fnName] || (module.default && module.default[fnName]);
    if (typeof fn !== 'function') {
      throw new Error('Provider does not export ' + fnName);
    }
    var args = {};
    try {
      args = JSON.parse(argsJson || '{}');
    } catch (error) {
      args = {};
    }
    if (!args.providerContext) {
      args.providerContext = providerContext(args.providerValue);
    }
    if (!args.providerValue && args.providerContext.providerValue) {
      args.providerValue = args.providerContext.providerValue;
    }
    return Promise.resolve(fn(args));
  };
})(globalThis);
