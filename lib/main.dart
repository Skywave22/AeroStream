import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'app/self_check.dart';
import 'core/logging/app_log.dart';
import 'core/platform/platform_profile.dart';
import 'data/storage/file_artifact_store.dart';
import 'data/storage/prefs_settings_store.dart';
import 'data/storage/sqlite_extension_store.dart';
import 'features/downloads/download_providers.dart';
import 'plugins/adapters/cloudstream/cloudstream_bridge.dart';
import 'plugins/runtime/engine_factory.dart';

/// Boot order matters: nothing may touch a store before it exists, so the
/// platform-backed implementations are built here and injected as provider
/// overrides. Widgets never construct a store themselves.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // libmpv, before any player is constructed.
  MediaKit.ensureInitialized();
  AppLog.info('AeroStream starting');

  final platform = PlatformProfile.current;
  AppLog.info('Platform: ${platform.target.name}');

  final settings = await PrefsSettingsStore.open();
  final support = await getApplicationSupportDirectory();
  final extensionStore = SqliteExtensionStore.openFile(
    '${support.path}/aerostream.db',
  );
  final artifacts = FileArtifactStore('${support.path}/plugins');
  final bootstrap = await rootBundle.loadString('assets/js/host_bootstrap.js');
  final vegaBootstrap = await rootBundle.loadString(
    'assets/js/vega_bootstrap.js',
  );
  final cheerioLite = await rootBundle.loadString('assets/js/cheerio_lite.js');

  // One CloudStream engine protocol, three host strategies: Android executes
  // DEX in-process, iOS uses the embedded OpenJDK Zero VM, and desktop starts
  // the bundled Java sidecar. Startup stays lazy inside the bridge so an engine
  // problem never prevents the rest of AeroStream from opening.
  final cloudStream = Cs3EngineBridge(
    dataDir: '${support.path}/cloudstream/engine',
    language: WidgetsBinding.instance.platformDispatcher.locale.toLanguageTag(),
  );

  final overrides = <Override>[
    settingsStoreProvider.overrideWithValue(settings),
    extensionStoreProvider.overrideWithValue(extensionStore),
    artifactStoreProvider.overrideWithValue(artifacts),
    hostBootstrapProvider.overrideWithValue(bootstrap),
    vegaBootstrapProvider.overrideWithValue(vegaBootstrap),
    cheerioLiteProvider.overrideWithValue(cheerioLite),
    platformProfileProvider.overrideWithValue(platform),
    jsEngineFactoryProvider.overrideWithValue(createPlatformEngineFactory()),
    downloadDirectoryProvider.overrideWithValue(
      Directory('${support.path}/downloads'),
    ),
    cloudStreamBridgeProvider.overrideWith((ref) {
      ref.onDispose(() => unawaited(cloudStream.dispose()));
      return cloudStream;
    }),
  ];

  // A run nobody has to look at: same stores, same sandbox, same install path,
  // verdict on stdout. This is how the app is exercised on a machine with no
  // display (CI under Xvfb) and how a phone can be asked what is wrong with it.
  if (Platform.environment['AEROSTREAM_SELFCHECK'] == '1') {
    exit(await runSelfCheck(overrides));
  }

  runApp(ProviderScope(overrides: overrides, child: const AeroStreamApp()));
}
