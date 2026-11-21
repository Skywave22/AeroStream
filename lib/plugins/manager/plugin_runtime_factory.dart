import 'dart:convert';

import '../../core/errors/plugin_error.dart';
import '../../core/json/json_read.dart';
import '../../core/logging/app_log.dart';
import '../../core/network/http_service.dart';
import '../../core/platform/platform_profile.dart';
import '../../core/result.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/installed_plugin.dart';
import '../../domain/media_provider.dart';
import '../../domain/repositories/extension_store.dart';
import '../adapters/cloudstream/cloudstream_adapter.dart';
import '../adapters/cloudstream/cloudstream_bridge.dart';
import '../adapters/skystream/skystream_adapter.dart';
import '../adapters/vega/vega_adapter.dart';
import '../runtime/js_host_api.dart';
import '../runtime/js_plugin_host.dart';
import '../runtime/js_runtime.dart';
import 'plugin_endpoint_store.dart';

/// Creates a JavaScript engine. Injected so the app can use QuickJS while tests
/// use a scripted runtime.
typedef JsEngineFactory = JsRuntime Function();

/// Builds a runnable [MediaProvider] for an installed plugin.
///
/// This is the one place that knows how each ecosystem is packaged on disk:
/// SkyStream is `plugin.json` + `plugin.js`, Vega is a folder of CommonJS
/// modules, CloudStream is a `.cs3` the native host loads.
final class PluginRuntimeFactory {
  PluginRuntimeFactory({
    required ArtifactStore artifacts,
    required HttpService http,
    required SettingsStore settings,
    required PlatformProfile platform,
    required JsEngineFactory engineFactory,
    required this.hostBootstrap,
    this.vegaBootstrap = '',
    this.cheerioLite = '',
    CloudStreamBridge? cloudStreamBridge,
    this.limits = const RuntimeLimits(),
  })  : _artifacts = artifacts,
        _http = http,
        _settings = settings,
        _platform = platform,
        _engineFactory = engineFactory,
        _cloudStream = cloudStreamBridge;

  final ArtifactStore _artifacts;
  final HttpService _http;
  final SettingsStore _settings;
  final PlatformProfile _platform;
  final JsEngineFactory _engineFactory;
  final CloudStreamBridge? _cloudStream;

  /// `assets/js/host_bootstrap.js`, loaded once at startup.
  final String hostBootstrap;

  /// `assets/js/vega_bootstrap.js`.
  ///
  /// A Vega bundle is CommonJS and is loaded through `__vegaLoad`, which only
  /// this bootstrap defines; running the prelude under the SkyStream bootstrap
  /// threw `ReferenceError: '__vegaLoad' is not defined` on every provider.
  final String vegaBootstrap;

  /// `assets/js/cheerio_lite.js`.
  ///
  /// Vega providers are written against cheerio, which is synchronous, so it
  /// has to live inside the sandbox. Without it `require('cheerio')` fell
  /// through to the empty-object default and the first `cheerio.load(html)`
  /// died with "cannot read property 'load' of undefined".
  final String cheerioLite;

  final RuntimeLimits limits;

  /// Vega modules, in load order.
  ///
  /// `providerContext` is built by `vega_bootstrap.js` inside the sandbox and
  /// `headers.js` is a repo-level file, so neither is expected in an installed
  /// bundle; a module that is not there is simply skipped.
  static const List<String> vegaModules = <String>[
    'posts.js',
    'catalog.js',
    'meta.js',
    'stream.js',
    'episodes.js',
    'settings.js',
  ];

  Future<Result<MediaProvider>> create(InstalledPlugin plugin) async {
    final info = plugin.info;
    if (!_platform.supports(info.ecosystem)) {
      return Err<MediaProvider>(
        PluginUnsupportedError(
          _platform.unsupportedReason(info.ecosystem) ??
              'This plugin cannot run here',
          pluginId: info.id,
          operation: 'start',
        ),
      );
    }

    if (!await _artifacts.exists(plugin.artifactPath)) {
      return Err<MediaProvider>(
        PluginNotFoundError(
          'The plugin files are missing; reinstall it from its repository',
          pluginId: info.id,
        ),
      );
    }

    return switch (info.ecosystem) {
      PluginEcosystem.skystream => _skyStream(plugin),
      PluginEcosystem.vega => _vega(plugin),
      PluginEcosystem.cloudstream => _cloudStreamAdapter(plugin),
    };
  }

  Future<Result<MediaProvider>> _skyStream(InstalledPlugin plugin) async {
    final manifestRaw = await _artifacts.readEntry(
      plugin.artifactPath,
      'plugin.json',
    );
    final source = await _artifacts.readEntry(plugin.artifactPath, 'plugin.js');
    if (source == null) {
      return Err<MediaProvider>(
        PluginParseError(
          'The installed package has no plugin.js',
          pluginId: plugin.info.id,
          field: 'plugin.js',
        ),
      );
    }

    Map<String, Object?> manifest = const <String, Object?>{};
    if (manifestRaw != null) {
      try {
        final decoded = jsonDecode(manifestRaw);
        if (decoded is Map<String, Object?>) manifest = decoded;
      } on FormatException {
        // A broken manifest is survivable: the adapter falls back to the
        // record written at install time.
      }
    }

    // A user-chosen mirror (or sub-provider) is applied here, on the way into
    // the sandbox, so plugin code never has to know it was chosen.
    final effective = PluginEndpointStore(_settings).manifestFor(
      plugin.info,
      manifest.isEmpty ? plugin.info.toJson() : manifest,
    );

    final host = _newHost(
      plugin: plugin,
      pluginSource: source,
      manifestJson: jsonEncode(effective),
    );

    return Ok<MediaProvider>(
      SkyStreamAdapter(
        info: plugin.info,
        host: host,
        baseUrl: readString(manifest['baseUrl']),
      ),
    );
  }

  Future<Result<MediaProvider>> _vega(InstalledPlugin plugin) async {
    if (vegaBootstrap.isEmpty) {
      return Err<MediaProvider>(
        PluginUnsupportedError(
          'The Vega runtime is missing from this build',
          pluginId: plugin.info.id,
          operation: 'start',
        ),
      );
    }
    // The Vega bootstrap defines `__vegaLoad`/`__vegaCall`; the host bootstrap
    // defines the callback plumbing every call goes through (`__aeroInvoke`,
    // `__aeroPoll`, `__aeroResolve`) plus `fetch`. A provider needs both, and
    // the host half goes in the prelude so it is evaluated last: its `fetch`
    // is the one that speaks the sandbox protocol.
    final prelude = <String>[
      if (cheerioLite.isNotEmpty) cheerioLite,
      hostBootstrap,
    ];
    var loaded = 0;
    for (final module in vegaModules) {
      final source = await _artifacts.readEntry(plugin.artifactPath, module);
      if (source == null) continue;
      final name = module.replaceAll('.js', '');
      prelude.add('__vegaLoad(${jsonEncode(name)}, ${jsonEncode(source)})');
      loaded++;
    }
    if (loaded == 0) {
      return Err<MediaProvider>(
        PluginParseError(
          'The provider bundle has no modules',
          pluginId: plugin.info.id,
          field: 'posts.js',
        ),
      );
    }

    final host = _newHost(
      plugin: plugin,
      prelude: prelude,
      bootstrap: vegaBootstrap,
    );
    return Ok<MediaProvider>(
      VegaAdapter(
        info: plugin.info,
        host: host,
        providerValue: plugin.info.id,
      ),
    );
  }

  Future<Result<MediaProvider>> _cloudStreamAdapter(
    InstalledPlugin plugin,
  ) async {
    final bridge = _cloudStream;
    if (bridge == null) {
      return Err<MediaProvider>(
        PluginUnsupportedError(
          'The CloudStream host is not part of this build',
          pluginId: plugin.info.id,
          operation: 'start',
        ),
      );
    }
    if (!await bridge.isAvailable()) {
      return Err<MediaProvider>(
        PluginUnsupportedError(
          'The CloudStream host did not start',
          pluginId: plugin.info.id,
          operation: 'start',
        ),
      );
    }

    final loaded = await bridge.invoke('loadPlugin', <String, Object?>{
      'pluginPath': plugin.artifactPath,
      'pluginId': plugin.info.id,
    });
    if (loaded is Err<Map<String, Object?>>) {
      return Err<MediaProvider>(
        loaded.error.copyWithPlugin(plugin.info.id),
      );
    }
    final providers = readStringList(
      (loaded as Ok<Map<String, Object?>>).value['providers'],
    );
    AppLog.info(
      'CloudStream extension ${plugin.info.id} exposes '
      '${providers.length} provider(s)',
      pluginId: plugin.info.id,
    );

    return Ok<MediaProvider>(
      CloudStreamAdapter(
        info: plugin.info,
        bridge: bridge,
        artifactPath: plugin.artifactPath,
        providerName: providers.isEmpty ? null : providers.first,
      ),
    );
  }

  JsPluginHost _newHost({
    required InstalledPlugin plugin,
    String? pluginSource,
    String? manifestJson,
    List<String> prelude = const <String>[],
    String? bootstrap,
  }) =>
      JsPluginHost(
        runtime: _engineFactory(),
        api: JsHostApi(
          http: _http,
          settings: _settings,
          pluginId: plugin.info.id,
        ),
        pluginId: plugin.info.id,
        bootstrap: bootstrap ?? hostBootstrap,
        pluginSource: pluginSource,
        manifestJson: manifestJson,
        prelude: prelude,
        limits: limits,
      );
}
