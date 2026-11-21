import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/network/http_service.dart';
import '../core/platform/ecosystem_status.dart';
import '../core/platform/platform_profile.dart';
import '../domain/entities/installed_plugin.dart';
import '../domain/entities/plugin_repository.dart';
import '../domain/media_provider.dart';
import '../domain/repositories/extension_store.dart';
import '../plugins/adapters/cloudstream/cloudstream_bridge.dart';
import '../plugins/manager/extension_manager.dart';
import '../plugins/manager/plugin_runtime_factory.dart';
import '../plugins/manager/repository_service.dart';
import '../plugins/runtime/js_runtime.dart';
import '../plugins/runtime/unavailable_js_runtime.dart';

/// Providers are wired at bootstrap (in `main`) by overriding the ones marked
/// "overridden at boot". Keeping them as plain `Provider`s means a widget test
/// can substitute any of them without a platform channel.

final platformProfileProvider = Provider<PlatformProfile>(
  (ref) => PlatformProfile.current,
);

final httpServiceProvider = Provider<HttpService>((ref) => DioHttpService());

/// Overridden at boot with the real `shared_preferences` store.
final settingsStoreProvider = Provider<SettingsStore>(
  (ref) => throw StateError('settingsStoreProvider must be overridden'),
);

/// Overridden at boot with the SQLite store.
final extensionStoreProvider = Provider<ExtensionStore>(
  (ref) => throw StateError('extensionStoreProvider must be overridden'),
);

/// Overridden at boot with the filesystem artifact store.
final artifactStoreProvider = Provider<ArtifactStore>(
  (ref) => throw StateError('artifactStoreProvider must be overridden'),
);

/// Overridden at boot with `assets/js/host_bootstrap.js`.
final hostBootstrapProvider = Provider<String>(
  (ref) => throw StateError('hostBootstrapProvider must be overridden'),
);

/// Overridden at boot with `assets/js/vega_bootstrap.js`.
///
/// Empty means "this build has no Vega runtime", which the factory reports as a
/// typed error instead of starting a provider that cannot work.
final vegaBootstrapProvider = Provider<String>((ref) => '');

/// Overridden at boot with `assets/js/cheerio_lite.js`.
final cheerioLiteProvider = Provider<String>((ref) => '');

/// The JavaScript engine for this platform. Overridden at boot by the native
/// engine; the default fails safe with a typed error.
final jsEngineFactoryProvider = Provider<JsEngineFactory>(
  (ref) => UnavailableJsRuntime.new,
);

/// The cross-platform CloudStream engine, when this build has one.
final cloudStreamBridgeProvider = Provider<CloudStreamBridge?>((ref) => null);

/// Whether a native CloudStream host actually answered its handshake.
///
/// Asked once per screen that needs it: the answer is a property of the build,
/// and the bridge caches the result after the first probe.
final cloudStreamHostProvider = FutureProvider<bool>((ref) async {
  final bridge = ref.watch(cloudStreamBridgeProvider);
  if (bridge == null) return false;
  return bridge.isAvailable();
});

/// The platform support matrix for this device, CloudStream host included.
final ecosystemStatusesProvider = FutureProvider<List<EcosystemStatus>>((
  ref,
) async {
  final platform = ref.watch(platformProfileProvider);
  final host = await ref.watch(cloudStreamHostProvider.future);
  return ecosystemStatuses(platform: platform, cloudStreamHost: host);
});

final runtimeFactoryProvider = Provider<PluginRuntimeFactory>((ref) {
  return PluginRuntimeFactory(
    artifacts: ref.watch(artifactStoreProvider),
    http: ref.watch(httpServiceProvider),
    settings: ref.watch(settingsStoreProvider),
    platform: ref.watch(platformProfileProvider),
    engineFactory: ref.watch(jsEngineFactoryProvider),
    hostBootstrap: ref.watch(hostBootstrapProvider),
    vegaBootstrap: ref.watch(vegaBootstrapProvider),
    cheerioLite: ref.watch(cheerioLiteProvider),
    cloudStreamBridge: ref.watch(cloudStreamBridgeProvider),
    cloudStreamRepositoryLoader: ref.watch(extensionStoreProvider).repositories,
    limits: const RuntimeLimits(),
  );
});

final repositoryServiceProvider = Provider<RepositoryService>((ref) {
  return RepositoryService(
    http: ref.watch(httpServiceProvider),
    store: ref.watch(extensionStoreProvider),
  );
});

final extensionManagerProvider = Provider<ExtensionManager>((ref) {
  final factory = ref.watch(runtimeFactoryProvider);
  return ExtensionManager(
    store: ref.watch(extensionStoreProvider),
    artifacts: ref.watch(artifactStoreProvider),
    http: ref.watch(httpServiceProvider),
    platform: ref.watch(platformProfileProvider),
    providerFactory: factory.create,
  );
});

/// Everything installed, in priority order.
final installedPluginsProvider = FutureProvider<List<InstalledPlugin>>((
  ref,
) async {
  return ref.watch(extensionStoreProvider).installedPlugins();
});

/// Every repository the user added.
final repositoriesProvider = FutureProvider<List<PluginRepository>>((
  ref,
) async {
  return ref.watch(extensionStoreProvider).repositories();
});

/// A provider per enabled, supported plugin.
///
/// Rebuilt whenever the install list changes; plugins are disposed by
/// `disposeProviders` in `ExtensionsController`.
final mediaProvidersProvider = FutureProvider<List<MediaProvider>>((ref) async {
  await ref.watch(installedPluginsProvider.future);
  final manager = ref.watch(extensionManagerProvider);
  final providers = await manager.activeProviders();
  ref.onDispose(() {
    for (final provider in providers) {
      provider.dispose();
    }
  });
  return providers;
});
