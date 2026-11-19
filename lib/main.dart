import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'core/logging/app_log.dart';
import 'core/platform/platform_profile.dart';
import 'data/storage/file_artifact_store.dart';
import 'data/storage/prefs_settings_store.dart';
import 'data/storage/sqlite_extension_store.dart';

/// Boot order matters: nothing may touch a store before it exists, so the
/// platform-backed implementations are built here and injected as provider
/// overrides. Widgets never construct a store themselves.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        extensionStoreProvider.overrideWithValue(extensionStore),
        artifactStoreProvider.overrideWithValue(artifacts),
        hostBootstrapProvider.overrideWithValue(bootstrap),
        platformProfileProvider.overrideWithValue(platform),
      ],
      child: const AeroStreamApp(),
    ),
  );
}
