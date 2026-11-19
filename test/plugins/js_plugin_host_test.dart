import 'dart:convert';

import 'package:aerostream/core/network/network_policy.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/plugins/runtime/js_host_api.dart';
import 'package:aerostream/plugins/runtime/js_plugin_host.dart';
import 'package:aerostream/plugins/runtime/js_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_js_runtime.dart';
import '../support/fakes.dart';

const String _httpRoute = 'https://example.com/page';

JsPluginHost buildHost({
  required ScriptedJsRuntime runtime,
  FakeHttpService? http,
  RuntimeLimits limits = const RuntimeLimits(),
  String? pluginSource,
}) =>
    JsPluginHost(
      runtime: runtime,
      api: JsHostApi(
        http: http ?? FakeHttpService(<String, Object>{_httpRoute: '<html/>'}),
        settings: InMemorySettingsStore(),
        pluginId: 'dev.example.plugin',
      ),
      pluginId: 'dev.example.plugin',
      bootstrap: '/* bootstrap */',
      pluginSource: pluginSource,
      limits: limits,
    );

void main() {
  group('JsPluginHost call protocol', () {
    test('starts the context once and returns the plugin value', () async {
      final plugin = FakePlugin(value: 42);
      final runtime = ScriptedJsRuntime(onEvaluate: plugin.onEvaluate);
      final host = buildHost(runtime: runtime, pluginSource: '// plugin');

      final first = await host.call('getHome');
      final second = await host.call('getHome');

      expect(first.isOk, isTrue);
      expect(first.valueOrNull, 42);
      expect(second.valueOrNull, 42);
      expect(runtime.starts, 1, reason: 'the context is reused across calls');
      expect(plugin.invocations, hasLength(2));

      await host.dispose();
      expect(runtime.disposes, 1);
    });

    test('injects the bootstrap, the manifest and the plugin source', () async {
      final runtime = ScriptedJsRuntime(
        onEvaluate: FakePlugin(value: null).onEvaluate,
      );
      final host = JsPluginHost(
        runtime: runtime,
        api: JsHostApi(
          http: FakeHttpService(),
          settings: InMemorySettingsStore(),
          pluginId: 'dev.example.plugin',
        ),
        pluginId: 'dev.example.plugin',
        bootstrap: '/* bootstrap */',
        pluginSource: 'globalThis.getHome = (cb) => cb({success:true,data:[]});',
        manifestJson: '{"packageName":"dev.example.plugin"}',
      );

      await host.call('getHome');

      expect(runtime.scripts.first, '/* bootstrap */');
      final withManifest = runtime
          .scriptsStartingWith('var manifest =')
          .single;
      expect(withManifest, contains('dev.example.plugin'));
      expect(withManifest, contains('globalThis.getHome'));
      await host.dispose();
    });

    test('services a host call and resolves it with the reply', () async {
      final plugin = FakePlugin(
        value: 'done',
        hostCalls: const <FakeHostCall>[
          FakeHostCall(
            channel: 'http:get',
            payload: '{"url":"$_httpRoute","headers":{}}',
          ),
        ],
      );
      final runtime = ScriptedJsRuntime(onEvaluate: plugin.onEvaluate);
      final http = FakeHttpService(<String, Object>{
        _httpRoute: '<html>hello</html>',
      });
      final host = buildHost(runtime: runtime, http: http);

      final result = await host.call('search', args: <Object?>['dune']);

      expect(result.valueOrNull, 'done');
      expect(http.requested, <String>[_httpRoute]);
      expect(plugin.resolved, hasLength(1));
      expect(
        plugin.resolved.single,
        contains('hello'),
        reason: 'the reply body reaches the plugin',
      );
      await host.dispose();
    });

    test('rejects the promise when a host call fails', () async {
      final plugin = FakePlugin(
        value: 'ok',
        hostCalls: const <FakeHostCall>[
          FakeHostCall(
            channel: 'http:get',
            payload: '{"url":"https://example.com/missing"}',
          ),
        ],
      );
      final runtime = ScriptedJsRuntime(onEvaluate: plugin.onEvaluate);
      final host = buildHost(runtime: runtime, http: FakeHttpService());

      await host.call('search');

      expect(plugin.rejected, hasLength(1));
      await host.dispose();
    });

    test('maps a plugin-reported error to a typed failure', () async {
      final plugin = FakePlugin(error: const FakeError('scrape failed'));
      final runtime = ScriptedJsRuntime(onEvaluate: plugin.onEvaluate);
      final host = buildHost(runtime: runtime);

      final result = await host.call('getHome');

      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'unknown');
      expect(result.errorOrNull!.message, 'scrape failed');
      expect(result.errorOrNull!.pluginId, 'dev.example.plugin');
      await host.dispose();
    });

    test('an unimplemented entry point is reported as unsupported', () async {
      final runtime = ScriptedJsRuntime(
        onEvaluate: (script) async =>
            script.startsWith('__aeroPoll(')
                ? '{"done":true,"error":{"message":"no getHome","kind":"unsupported"}}'
                : script.startsWith('__aeroInvoke(')
                    ? '{"started":false}'
                    : '[]',
      );
      final host = buildHost(runtime: runtime);

      final result = await host.call('getHome');
      expect(result.errorOrNull!.kind, 'unsupported');
      await host.dispose();
    });
  });

  group('JsPluginHost budgets', () {
    test('kills a plugin that never finishes, and reports a timeout', () async {
      final runtime = ScriptedJsRuntime(
        onEvaluate: (script) async {
          if (script.startsWith('__aeroDrainLogs') ||
              script.startsWith('__aeroResolve') ||
              script.startsWith('__aeroFireTimer')) {
            return '[]';
          }
          return null; // never done
        },
      );
      final host = buildHost(
        runtime: runtime,
        limits: const RuntimeLimits(
          callTimeout: Duration(milliseconds: 120),
          pollInterval: Duration(milliseconds: 1),
        ),
      );

      final result = await host.call('getHome');

      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'timeout');
      expect(result.errorOrNull!.isRetryable, isTrue);
      expect(runtime.disposes, 1, reason: 'the hung context is destroyed');
    });

    test('kills a plugin that floods the host with calls', () async {
      final calls = List<FakeHostCall>.generate(
        30,
        (index) => FakeHostCall(
          id: 'c$index',
          channel: 'storage:get',
          payload: '{"key":"k$index"}',
        ),
      );
      final plugin = FakePlugin(value: 'done', hostCalls: calls);
      final runtime = ScriptedJsRuntime(onEvaluate: plugin.onEvaluate);
      final host = buildHost(
        runtime: runtime,
        limits: const RuntimeLimits(
          maxHostCallsPerInvocation: 5,
          callTimeout: Duration(seconds: 5),
        ),
      );

      final result = await host.call('getHome');

      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.kind, 'sandbox');
      expect(
        (result.errorOrNull! as dynamic).violation,
        'host-call-budget',
      );
      expect(runtime.disposes, 1);
    });

    test('kills a plugin that floods the network', () async {
      final calls = List<FakeHostCall>.generate(
        5,
        (index) => FakeHostCall(
          id: 'c$index',
          channel: 'http:get',
          payload: '{"url":"$_httpRoute"}',
        ),
      );
      final plugin = FakePlugin(value: 'done', hostCalls: calls);
      final runtime = ScriptedJsRuntime(onEvaluate: plugin.onEvaluate);
      final host = buildHost(
        runtime: runtime,
        limits: const RuntimeLimits(maxHttpRequestsPerInvocation: 2),
      );

      final result = await host.call('getHome');

      expect(result.errorOrNull!.kind, 'sandbox');
      expect((result.errorOrNull! as dynamic).violation, 'request-budget');
      expect(runtime.disposes, 1);
    });
  });

  group('JsPluginHost robustness', () {
    test('a dead engine surfaces as a crash and is restarted next call',
        () async {
      var fail = true;
      final runtime = ScriptedJsRuntime(
        onEvaluate: (script) async {
          if (fail && script.startsWith('__aeroPoll(')) {
            throw const JsEvalException('QuickJS aborted');
          }
          if (script.startsWith('__aeroInvoke(')) return '{"started":true}';
          if (script.startsWith('__aeroPoll(')) return '{"done":true,"value":1}';
          return '[]';
        },
      );
      final host = buildHost(runtime: runtime);

      final failed = await host.call('getHome');
      expect(failed.errorOrNull!.kind, 'crash');
      expect(runtime.disposes, 1);

      fail = false;
      final recovered = await host.call('getHome');
      expect(recovered.valueOrNull, 1);
      expect(runtime.starts, 2, reason: 'a fresh context is created');
      await host.dispose();
    });

    test('timers are fired by the host, not by the engine', () async {
      final plugin = FakePlugin(
        value: 'after timer',
        hostCalls: const <FakeHostCall>[
          FakeHostCall(
            id: 'timer:t1',
            channel: 'timer',
            payload: '{"ms":5,"timerId":"t1"}',
          ),
        ],
      );
      final runtime = ScriptedJsRuntime(onEvaluate: plugin.onEvaluate);
      final host = buildHost(runtime: runtime);

      final result = await host.call('getHome');

      expect(result.valueOrNull, 'after timer');
      expect(
        runtime.scriptsStartingWith('__aeroFireTimer("t1")'),
        hasLength(1),
      );
      expect(plugin.resolved, hasLength(1));
      await host.dispose();
    });

    test('healthCheck reports a dead context as unhealthy', () async {
      final runtime = ScriptedJsRuntime(
        onEvaluate: (script) async {
          if (script == '1 + 1') throw const JsEvalException('dead');
          return null;
        },
      );
      final host = buildHost(runtime: runtime);
      expect(await host.healthCheck(), isFalse);
      await host.dispose();
    });

    test('generation increases on every restart', () async {
      final runtime = ScriptedJsRuntime(
        onEvaluate: (script) async {
          if (script.startsWith('__aeroPoll(')) {
            throw const JsEvalException('dead');
          }
          if (script.startsWith('__aeroInvoke(')) return '{"started":true}';
          return '[]';
        },
      );
      final host = buildHost(runtime: runtime);
      final before = host.generation;
      await host.call('getHome');
      expect(host.generation, greaterThan(before));
      await host.dispose();
    });
  });

  group('JsHostApi', () {
    late InMemorySettingsStore settings;
    late FakeHttpService http;
    late JsHostApi api;

    setUp(() {
      settings = InMemorySettingsStore();
      http = FakeHttpService(<String, Object>{
        'https://example.com/a': 'body-a',
      });
      api = JsHostApi(
        http: http,
        settings: settings,
        pluginId: 'p',
      );
    });

    Future<Object?> invoke(String channel, Object? payload) async {
      final reply = await api.handle(
        JsHostCall(id: 'c1', channel: channel, payload: jsonEncode(payload)),
      );
      if (reply.isError) return Err<Object?>(reply.json);
      return reply.json == 'null' ? null : jsonDecode(reply.json);
    }

    test('parses HTML and extracts by CSS selector', () async {
      const html = '''
        <div class="card"><a href="/one" title="One">First</a></div>
        <div class="card"><a href="/two">Second</a></div>
      ''';
      final hrefs = await invoke('html:select', <String, Object?>{
        'html': html,
        'selector': '.card a',
        'attribute': 'href',
      });
      expect(hrefs, <String>['/one', '/two']);

      final texts = await invoke('html:select', <String, Object?>{
        'html': html,
        'selector': 'a',
      });
      expect((texts as List).first, containsPair('text', 'First'));

      final parsed = await invoke('html:parse', <String, Object?>{'html': html});
      final docId = (parsed as Map)['id'];
      final firstText = await invoke('html:text', <String, Object?>{
        'doc': docId,
        'selector': 'a',
      });
      expect(firstText, 'First');
      final title = await invoke('html:attr', <String, Object?>{
        'doc': docId,
        'selector': 'a',
        'attribute': 'title',
      });
      expect(title, 'One');
    });

    test('hashes, encodes and decodes', () async {
      expect(
        await invoke('crypto:md5', <String, Object?>{'input': 'abc'}),
        '900150983cd24fb0d6963f7d28e17f72',
      );
      expect(
        await invoke('crypto:sha256', <String, Object?>{'input': 'abc'}),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        await invoke('text:b64encode', <String, Object?>{'input': 'aero'}),
        'YWVybw==',
      );
      expect(
        await invoke('text:b64decode', <String, Object?>{'input': 'YWVybw=='}),
        'aero',
      );
    });

    test('keeps per-plugin storage namespaced', () async {
      await api.handle(
        const JsHostCall(
          id: 'c1',
          channel: 'storage:set',
          payload: '{"key":"token","value":"abc"}',
        ),
      );
      expect(settings.values.keys.single, 'plugin.p.token');

      final stored = await invoke('storage:get', <String, Object?>{'key': 'token'});
      expect(stored, 'abc');

      final missing = await invoke('storage:get', <String, Object?>{
        'key': 'nope',
        'fallback': 'fallback',
      });
      expect(missing, 'fallback');
    });

    test('refuses private hosts and unknown channels', () async {
      final reply = await api.handle(
        const JsHostCall(
          id: 'c1',
          channel: 'http:get',
          payload: '{"url":"http://192.168.1.1/admin"}',
        ),
      );
      expect(reply.isError, isTrue);
      expect(reply.json, contains('private'));

      final unknown = await api.handle(
        const JsHostCall(id: 'c2', channel: 'fs:read', payload: '{}'),
      );
      expect(unknown.isError, isTrue);
      expect(unknown.json, contains('Unknown host channel'));
      expect(http.requested, isEmpty);
    });

    test('an allow-list limits which hosts a plugin may reach', () async {
      final scoped = JsHostApi(
        http: http,
        settings: settings,
        pluginId: 'p',
        policy: const NetworkPolicy(allowedHosts: <String>{'allowed.com'}),
      );
      final blocked = await scoped.handle(
        const JsHostCall(
          id: 'c1',
          channel: 'http:get',
          payload: '{"url":"https://other.com/x"}',
        ),
      );
      expect(blocked.isError, isTrue);
      expect(blocked.json, contains('allow-list'));
    });
  });

  group('NetworkPolicy', () {
    test('blocks loopback, link-local and RFC1918 addresses', () {
      const policy = NetworkPolicy();
      for (final host in <String>[
        'localhost',
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '192.168.0.1',
        '169.254.1.1',
        'printer.local',
      ]) {
        expect(
          policy.check(Uri.parse('http://$host/x')).isErr,
          isTrue,
          reason: host,
        );
      }
      expect(policy.check(Uri.parse('https://example.com/x')).isOk, isTrue);
      expect(policy.check(Uri.parse('https://1.1.1.1/x')).isOk, isTrue);
    });

    test('rejects non-http schemes', () {
      const policy = NetworkPolicy();
      expect(policy.check(Uri.parse('file:///etc/passwd')).isErr, isTrue);
      expect(policy.check(Uri.parse('ftp://example.com/x')).isErr, isTrue);
    });
  });
}
