/*
 * cheerio_lite - a small, dependency-free HTML parser and jQuery-ish selector
 * engine for plugin contexts.
 *
 * Vega providers are written against cheerio, whose API is synchronous. A
 * host-roundtrip implementation cannot be synchronous, so the DOM is parsed
 * here, inside the sandbox, in plain JavaScript. That keeps `$('.item').text()`
 * working as providers expect, and keeps the whole thing inside the plugin's
 * memory budget.
 *
 * Supported: tag, .class, #id, *, [attr], [attr=v], [attr*=v], [attr^=v],
 * [attr$=v], descendant and `>` combinators, comma groups, :first-child,
 * :last-child, :nth-child(n), :not(simple), and the common traversal methods.
 */
(function (global) {
  'use strict';

  var VOID_TAGS = {
    area: 1, base: 1, br: 1, col: 1, embed: 1, hr: 1, img: 1, input: 1,
    link: 1, meta: 1, param: 1, source: 1, track: 1, wbr: 1
  };

  var RAW_TEXT_TAGS = { script: 1, style: 1, textarea: 1, title: 1 };

  var ENTITIES = {
    amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0',
    copy: '\u00a9', reg: '\u00ae', hellip: '\u2026', mdash: '\u2014',
    ndash: '\u2013', rsquo: '\u2019', lsquo: '\u2018', ldquo: '\u201c',
    rdquo: '\u201d'
  };

  function decodeEntities(text) {
    if (text.indexOf('&') < 0) return text;
    return text.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, function (match, body) {
      if (body.charAt(0) === '#') {
        var code = body.charAt(1) === 'x' || body.charAt(1) === 'X'
          ? parseInt(body.slice(2), 16)
          : parseInt(body.slice(1), 10);
        if (!isNaN(code) && code > 0) return String.fromCharCode(code);
        return match;
      }
      var named = ENTITIES[body.toLowerCase()];
      return named === undefined ? match : named;
    });
  }

  function Node(type, name) {
    this.type = type; // 'root' | 'tag' | 'text'
    this.name = name || '';
    this.attributes = {};
    this.children = [];
    this.parent = null;
    this.data = '';
  }

  function appendChild(parent, child) {
    child.parent = parent;
    parent.children.push(child);
    return child;
  }

  function parseAttributes(source) {
    var attributes = {};
    var pattern = /([:@a-zA-Z_][-.:\w]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/g;
    var match;
    while ((match = pattern.exec(source)) !== null) {
      var name = match[1].toLowerCase();
      var value = match[2] !== undefined ? match[2]
        : match[3] !== undefined ? match[3]
          : match[4] !== undefined ? match[4]
            : '';
      attributes[name] = decodeEntities(value);
    }
    return attributes;
  }

  function parse(html) {
    var root = new Node('root', '#root');
    var stack = [root];
    var text = String(html === undefined || html === null ? '' : html);
    var index = 0;

    function current() {
      return stack[stack.length - 1];
    }

    function pushText(raw) {
      if (!raw) return;
      var value = decodeEntities(raw);
      if (!value.length) return;
      var node = new Node('text', '#text');
      node.data = value;
      appendChild(current(), node);
    }

    while (index < text.length) {
      var open = text.indexOf('<', index);
      if (open < 0) {
        pushText(text.slice(index));
        break;
      }
      if (open > index) pushText(text.slice(index, open));

      // Comment
      if (text.substr(open, 4) === '<!--') {
        var commentEnd = text.indexOf('-->', open + 4);
        index = commentEnd < 0 ? text.length : commentEnd + 3;
        continue;
      }
      // Doctype / declaration
      if (text.charAt(open + 1) === '!' || text.charAt(open + 1) === '?') {
        var declEnd = text.indexOf('>', open);
        index = declEnd < 0 ? text.length : declEnd + 1;
        continue;
      }
      // Closing tag
      if (text.charAt(open + 1) === '/') {
        var closeEnd = text.indexOf('>', open);
        if (closeEnd < 0) {
          index = text.length;
          break;
        }
        var closeName = text.slice(open + 2, closeEnd).trim().toLowerCase();
        for (var i = stack.length - 1; i > 0; i--) {
          if (stack[i].name === closeName) {
            stack.length = i;
            break;
          }
        }
        index = closeEnd + 1;
        continue;
      }
      // Opening tag
      var tagEnd = text.indexOf('>', open);
      if (tagEnd < 0) {
        pushText(text.slice(open));
        break;
      }
      var raw = text.slice(open + 1, tagEnd);
      var selfClosing = raw.charAt(raw.length - 1) === '/';
      if (selfClosing) raw = raw.slice(0, -1);
      var spaceAt = raw.search(/[\s/]/);
      var tagName = (spaceAt < 0 ? raw : raw.slice(0, spaceAt)).toLowerCase();
      var attributeSource = spaceAt < 0 ? '' : raw.slice(spaceAt);
      var node = new Node('tag', tagName);
      node.attributes = parseAttributes(attributeSource);
      appendChild(current(), node);
      index = tagEnd + 1;

      if (selfClosing || VOID_TAGS[tagName]) continue;

      if (RAW_TEXT_TAGS[tagName]) {
        var rawEnd = text.toLowerCase().indexOf('</' + tagName, index);
        var rawContent = rawEnd < 0 ? text.slice(index) : text.slice(index, rawEnd);
        if (rawContent.length) {
          var rawNode = new Node('text', '#text');
          rawNode.data = rawContent;
          appendChild(node, rawNode);
        }
        if (rawEnd < 0) {
          index = text.length;
        } else {
          var rawCloseEnd = text.indexOf('>', rawEnd);
          index = rawCloseEnd < 0 ? text.length : rawCloseEnd + 1;
        }
        continue;
      }

      stack.push(node);
    }

    return root;
  }

  // ---- selector engine ---------------------------------------------------

  function parseSimple(token) {
    var simple = { tag: null, classes: [], id: null, attributes: [], pseudos: [] };
    var rest = token;
    var tagMatch = /^[a-zA-Z][-\w]*/.exec(rest);
    if (tagMatch) {
      simple.tag = tagMatch[0].toLowerCase();
      rest = rest.slice(tagMatch[0].length);
    } else if (rest.charAt(0) === '*') {
      rest = rest.slice(1);
    }
    var pattern = /([.#])([-\w]+)|\[\s*([-\w:]+)\s*(?:([~^*$|]?=)\s*("[^"]*"|'[^']*'|[^\]]*))?\s*\]|:([-\w]+)(?:\(([^)]*)\))?/g;
    var match;
    while ((match = pattern.exec(rest)) !== null) {
      if (match[1] === '.') {
        simple.classes.push(match[2]);
      } else if (match[1] === '#') {
        simple.id = match[2];
      } else if (match[3]) {
        var rawValue = match[5];
        if (rawValue !== undefined) {
          rawValue = rawValue.replace(/^['"]|['"]$/g, '');
        }
        simple.attributes.push({
          name: match[3].toLowerCase(),
          operator: match[4] || null,
          value: rawValue
        });
      } else if (match[6]) {
        simple.pseudos.push({ name: match[6].toLowerCase(), argument: match[7] || '' });
      }
    }
    return simple;
  }

  function splitGroups(selector) {
    var parts = [];
    var buffer = '';
    var depth = 0;
    var quote = '';
    var text = String(selector);
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i);
      if (quote) {
        buffer += ch;
        if (ch === quote) quote = '';
        continue;
      }
      if (ch === '"' || ch === "'") { quote = ch; buffer += ch; continue; }
      if (ch === '[' || ch === '(') depth++;
      if (ch === ']' || ch === ')') depth = Math.max(0, depth - 1);
      if (ch === ',' && depth === 0) { parts.push(buffer); buffer = ''; continue; }
      buffer += ch;
    }
    if (buffer.trim()) parts.push(buffer);
    return parts;
  }

  function parseSelector(selector) {
    var groups = [];
    var parts = splitGroups(selector);
    for (var i = 0; i < parts.length; i++) {
      var group = parts[i].trim();
      if (!group) continue;
      var tokens = [];
      var buffer = '';
      var combinator = ' ';
      for (var j = 0; j < group.length; j++) {
        var ch = group.charAt(j);
        if (ch === '>') {
          if (buffer) {
            tokens.push({ combinator: combinator, simple: parseSimple(buffer) });
            buffer = '';
          }
          combinator = '>';
        } else if (/\s/.test(ch)) {
          if (buffer) {
            tokens.push({ combinator: combinator, simple: parseSimple(buffer) });
            buffer = '';
            combinator = ' ';
          }
        } else {
          buffer += ch;
        }
      }
      if (buffer) tokens.push({ combinator: combinator, simple: parseSimple(buffer) });
      if (tokens.length) groups.push(tokens);
    }
    return groups;
  }

  function elementChildren(node) {
    var out = [];
    for (var i = 0; i < node.children.length; i++) {
      if (node.children[i].type === 'tag') out.push(node.children[i]);
    }
    return out;
  }

  function previousElementSibling(node) {
    if (!node.parent) return null;
    var siblings = elementChildren(node.parent);
    var at = siblings.indexOf(node);
    return at > 0 ? siblings[at - 1] : null;
  }

  function matchesSimple(node, simple) {
    if (node.type !== 'tag') return false;
    if (simple.tag && node.name !== simple.tag) return false;
    if (simple.id && node.attributes.id !== simple.id) return false;
    if (simple.classes.length) {
      var classAttr = node.attributes['class'] || '';
      var classes = classAttr.split(/\s+/);
      for (var i = 0; i < simple.classes.length; i++) {
        if (classes.indexOf(simple.classes[i]) < 0) return false;
      }
    }
    for (var a = 0; a < simple.attributes.length; a++) {
      var attribute = simple.attributes[a];
      var value = node.attributes[attribute.name];
      if (value === undefined) return false;
      if (!attribute.operator) continue;
      var expected = attribute.value === undefined ? '' : attribute.value;
      switch (attribute.operator) {
        case '=':
          if (value !== expected) return false;
          break;
        case '*=':
          if (value.indexOf(expected) < 0) return false;
          break;
        case '^=':
          if (value.indexOf(expected) !== 0) return false;
          break;
        case '$=':
          if (value.length < expected.length ||
              value.slice(value.length - expected.length) !== expected) return false;
          break;
        case '~=':
          if ((' ' + value + ' ').indexOf(' ' + expected + ' ') < 0) return false;
          break;
        case '|=':
          if (value !== expected && value.indexOf(expected + '-') !== 0) return false;
          break;
        default:
          break;
      }
    }
    for (var p = 0; p < simple.pseudos.length; p++) {
      var pseudo = simple.pseudos[p];
      switch (pseudo.name) {
        case 'first-child':
          if (previousElementSibling(node) !== null) return false;
          break;
        case 'last-child':
          if (!node.parent) return false;
          var siblings = elementChildren(node.parent);
          if (siblings[siblings.length - 1] !== node) return false;
          break;
        case 'nth-child':
          if (!node.parent) return false;
          var index = elementChildren(node.parent).indexOf(node) + 1;
          if (index !== parseInt(pseudo.argument, 10)) return false;
          break;
        case 'not':
          if (matchesSimple(node, parseSimple(pseudo.argument.trim()))) return false;
          break;
        case 'empty':
          if (elementChildren(node).length) return false;
          break;
        case 'contains':
          if (textOf(node).indexOf(pseudo.argument.replace(/^['"]|['"]$/g, '')) < 0) return false;
          break;
        default:
          break;
      }
    }
    return true;
  }

  function matchesChain(node, tokens) {
    var current = node;
    for (var i = tokens.length - 1; i >= 0; i--) {
      var token = tokens[i];
      if (!matchesSimple(current, token.simple)) return false;
      if (i === 0) return true;
      var next = tokens[i - 1];
      if (token.combinator === '>') {
        current = current.parent;
        if (!current || current.type !== 'tag') return false;
      } else {
        current = current.parent;
        var found = false;
        while (current && current.type === 'tag') {
          if (matchesSimple(current, next.simple)) {
            found = true;
            break;
          }
          current = current.parent;
        }
        if (!found) return false;
        i--; // the ancestor already matched
      }
    }
    return true;
  }

  function selectAll(root, selector) {
    var groups = parseSelector(selector);
    if (!groups.length) return [];
    var results = [];
    var stack = [root];
    while (stack.length) {
      var node = stack.pop();
      for (var g = 0; g < groups.length; g++) {
        if (matchesChain(node, groups[g])) {
          results.push(node);
          break;
        }
      }
      for (var i = node.children.length - 1; i >= 0; i--) {
        if (node.children[i].type === 'tag') stack.push(node.children[i]);
      }
    }
    // Document order
    var ordered = [];
    (function walk(node) {
      for (var i = 0; i < node.children.length; i++) {
        var child = node.children[i];
        if (child.type !== 'tag') continue;
        if (results.indexOf(child) >= 0) ordered.push(child);
        walk(child);
      }
    })(root);
    return ordered;
  }

  function textOf(node) {
    if (node.type === 'text') return node.data;
    var out = '';
    for (var i = 0; i < node.children.length; i++) out += textOf(node.children[i]);
    return out;
  }

  function htmlOf(node) {
    if (node.type === 'text') return node.data;
    var out = '';
    for (var i = 0; i < node.children.length; i++) {
      var child = node.children[i];
      if (child.type === 'text') {
        out += child.data;
        continue;
      }
      out += '<' + child.name;
      for (var name in child.attributes) {
        if (!Object.prototype.hasOwnProperty.call(child.attributes, name)) continue;
        out += ' ' + name + '="' + child.attributes[name] + '"';
      }
      out += '>';
      if (!VOID_TAGS[child.name]) out += htmlOf(child) + '</' + child.name + '>';
    }
    return out;
  }

  function textWithBreaks(node) {
    return textOf(node).replace(/\s+/g, ' ').trim();
  }

  // ---- collection --------------------------------------------------------

  function Collection(nodes, root) {
    this.nodes = nodes;
    this.root = root;
    this.length = nodes.length;
    for (var i = 0; i < nodes.length; i++) this[i] = nodes[i];
  }

  Collection.prototype.each = function (fn) {
    for (var i = 0; i < this.nodes.length; i++) {
      fn.call(this.nodes[i], i, this.nodes[i]);
    }
    return this;
  };

  Collection.prototype.map = function (fn) {
    var out = [];
    for (var i = 0; i < this.nodes.length; i++) out.push(fn.call(this.nodes[i], i, this.nodes[i]));
    return new Collection(out.filter(function (value) { return value !== undefined; }), this.root);
  };

  Collection.prototype.get = function (index) {
    if (index === undefined) return this.nodes.slice();
    return this.nodes[index < 0 ? this.nodes.length + index : index];
  };

  Collection.prototype.toArray = function () { return this.nodes.slice(); };

  Collection.prototype.first = function () {
    return new Collection(this.nodes.slice(0, 1), this.root);
  };

  Collection.prototype.last = function () {
    return new Collection(this.nodes.slice(-1), this.root);
  };

  Collection.prototype.eq = function (index) {
    var at = index < 0 ? this.nodes.length + index : index;
    return new Collection(this.nodes.slice(at, at + 1), this.root);
  };

  Collection.prototype.find = function (selector) {
    var out = [];
    for (var i = 0; i < this.nodes.length; i++) {
      var found = selectAll(this.nodes[i], selector);
      for (var j = 0; j < found.length; j++) out.push(found[j]);
    }
    return new Collection(out, this.root);
  };

  Collection.prototype.filter = function (selector) {
    var groups = parseSelector(selector);
    var out = [];
    for (var i = 0; i < this.nodes.length; i++) {
      for (var g = 0; g < groups.length; g++) {
        if (matchesChain(this.nodes[i], groups[g])) { out.push(this.nodes[i]); break; }
      }
    }
    return new Collection(out, this.root);
  };

  Collection.prototype.is = function (selector) { return this.filter(selector).length > 0; };

  Collection.prototype.children = function () {
    var out = [];
    for (var i = 0; i < this.nodes.length; i++) {
      out = out.concat(elementChildren(this.nodes[i]));
    }
    return new Collection(out, this.root);
  };

  Collection.prototype.parent = function () {
    var out = [];
    for (var i = 0; i < this.nodes.length; i++) {
      var parent = this.nodes[i].parent;
      if (parent && parent.type === 'tag' && out.indexOf(parent) < 0) out.push(parent);
    }
    return new Collection(out, this.root);
  };

  Collection.prototype.next = function () {
    var out = [];
    for (var i = 0; i < this.nodes.length; i++) {
      if (!this.nodes[i].parent) continue;
      var siblings = elementChildren(this.nodes[i].parent);
      var next = siblings[siblings.indexOf(this.nodes[i]) + 1];
      if (next) out.push(next);
    }
    return new Collection(out, this.root);
  };

  Collection.prototype.prev = function () {
    var out = [];
    for (var i = 0; i < this.nodes.length; i++) {
      var previous = previousElementSibling(this.nodes[i]);
      if (previous) out.push(previous);
    }
    return new Collection(out, this.root);
  };

  Collection.prototype.text = function () {
    var out = '';
    for (var i = 0; i < this.nodes.length; i++) out += textWithBreaks(this.nodes[i]);
    return out;
  };

  Collection.prototype.html = function () {
    if (!this.nodes.length) return null;
    return htmlOf(this.nodes[0]);
  };

  Collection.prototype.attr = function (name, value) {
    if (!this.nodes.length) return value === undefined ? undefined : this;
    if (value === undefined) {
      var node = this.nodes[0];
      return node.attributes ? node.attributes[String(name).toLowerCase()] : undefined;
    }
    for (var i = 0; i < this.nodes.length; i++) {
      if (!this.nodes[i].attributes) this.nodes[i].attributes = {};
      this.nodes[i].attributes[String(name).toLowerCase()] = String(value);
    }
    return this;
  };

  Collection.prototype.data = function (name) {
    if (!this.nodes.length) return undefined;
    return this.nodes[0].attributes['data-' + String(name).toLowerCase()];
  };

  Collection.prototype.val = function () { return this.attr('value'); };

  Collection.prototype.hasClass = function (name) {
    return this.filter('.' + name).length > 0;
  };

  Collection.prototype.root = function () {
    return new Collection([this.root], this.root);
  };

  Collection.prototype.toString = function () { return this.text(); };

  // Real cheerio collections are iterable (`for (const el of $(sel))`), and
  // providers rely on it; indexable alone is not enough.
  if (typeof Symbol !== 'undefined' && Symbol.iterator) {
    Collection.prototype[Symbol.iterator] = function () {
      var nodes = this.nodes;
      var index = 0;
      return {
        next: function () {
          if (index < nodes.length) {
            return { value: nodes[index++], done: false };
          }
          return { value: undefined, done: true };
        }
      };
    };
  }

  function load(html) {
    var root = parse(html);
    function $(target) {
      if (target === undefined || target === null) return new Collection([], root);
      if (typeof target === 'string') return new Collection(selectAll(root, target), root);
      if (target instanceof Collection) return target;
      if (target.type) return new Collection([target], root);
      return new Collection([], root);
    }
    $.load = load;
    $.root = function () { return new Collection([root], root); };
    $.html = function () { return htmlOf(root); };
    $.parseHTML = function (source) { return new Collection(elementChildren(parse(source)), root); };
    return $;
  }

  global.cheerioLite = { load: load, parse: parse, select: selectAll, textOf: textOf };
})(globalThis);
