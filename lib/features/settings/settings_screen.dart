import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme/theme_providers.dart';
import '../../domain/entities/enums.dart';

/// Playback and network preferences that plugins honour.
final class AppPreferences {
  const AppPreferences({
    required this.preferredQuality,
    required this.autoplayNext,
    required this.preferHls,
    required this.allowUntrustedCertificates,
  });

  final String preferredQuality;
  final bool autoplayNext;
  final bool preferHls;
  final bool allowUntrustedCertificates;
}

final preferencesProvider =
    NotifierProvider<PreferencesController, AppPreferences>(
  PreferencesController.new,
);

class PreferencesController extends Notifier<AppPreferences> {
  static const String _qualityKey = 'playback.preferredQuality';
  static const String _autoplayKey = 'playback.autoplayNext';
  static const String _hlsKey = 'playback.preferHls';
  static const String _certsKey = 'network.allowUntrustedCertificates';

  @override
  AppPreferences build() {
    final settings = ref.read(settingsStoreProvider);
    return AppPreferences(
      preferredQuality: settings.getString(_qualityKey) ?? 'Auto',
      autoplayNext: settings.getBool(_autoplayKey, fallback: true),
      preferHls: settings.getBool(_hlsKey, fallback: true),
      allowUntrustedCertificates: settings.getBool(_certsKey),
    );
  }

  Future<void> setQuality(String quality) async {
    state = AppPreferences(
      preferredQuality: quality,
      autoplayNext: state.autoplayNext,
      preferHls: state.preferHls,
      allowUntrustedCertificates: state.allowUntrustedCertificates,
    );
    await ref.read(settingsStoreProvider).setString(_qualityKey, quality);
  }

  Future<void> setAutoplayNext({required bool value}) async {
    state = AppPreferences(
      preferredQuality: state.preferredQuality,
      autoplayNext: value,
      preferHls: state.preferHls,
      allowUntrustedCertificates: state.allowUntrustedCertificates,
    );
    await ref.read(settingsStoreProvider).setBool(_autoplayKey, value: value);
  }

  Future<void> setPreferHls({required bool value}) async {
    state = AppPreferences(
      preferredQuality: state.preferredQuality,
      autoplayNext: state.autoplayNext,
      preferHls: value,
      allowUntrustedCertificates: state.allowUntrustedCertificates,
    );
    await ref.read(settingsStoreProvider).setBool(_hlsKey, value: value);
  }
}

/// Settings and diagnostics.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(persistedThemeProvider);
    final prefs = ref.watch(preferencesProvider);
    final platform = ref.watch(platformProfileProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const _SectionLabel('Appearance'),
          RadioListTile<AppThemeVariant>(
            value: AppThemeVariant.system,
            groupValue: theme,
            onChanged: (value) => _setTheme(ref, value),
            title: const Text('Follow system'),
          ),
          RadioListTile<AppThemeVariant>(
            value: AppThemeVariant.light,
            groupValue: theme,
            onChanged: (value) => _setTheme(ref, value),
            title: const Text('Light'),
          ),
          RadioListTile<AppThemeVariant>(
            value: AppThemeVariant.dark,
            groupValue: theme,
            onChanged: (value) => _setTheme(ref, value),
            title: const Text('Dark'),
          ),
          RadioListTile<AppThemeVariant>(
            value: AppThemeVariant.amoled,
            groupValue: theme,
            onChanged: (value) => _setTheme(ref, value),
            title: const Text('AMOLED black'),
            subtitle: const Text('Pure black for OLED panels'),
          ),
          const Divider(),
          const _SectionLabel('Playback'),
          ListTile(
            title: const Text('Preferred quality'),
            subtitle: Text(prefs.preferredQuality),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _chooseQuality(context, ref, prefs.preferredQuality),
          ),
          SwitchListTile(
            title: const Text('Play next episode'),
            subtitle:
                const Text('Continue with the next episode automatically'),
            value: prefs.autoplayNext,
            onChanged: (value) => ref
                .read(preferencesProvider.notifier)
                .setAutoplayNext(value: value),
          ),
          SwitchListTile(
            title: const Text('Prefer HLS streams'),
            subtitle: const Text(
              'Pick adaptive HLS links when a source offers several formats',
            ),
            value: prefs.preferHls,
            onChanged: (value) => ref
                .read(preferencesProvider.notifier)
                .setPreferHls(value: value),
          ),
          const Divider(),
          const _SectionLabel('Platform'),
          ListTile(
            leading: const Icon(Icons.devices_other),
            title: const Text('This device'),
            subtitle: Text(
              <String>[
                platform.target.name,
                for (final ecosystem in PluginEcosystem.values)
                  '${ecosystem.label}: '
                      '${platform.supports(ecosystem) ? 'yes' : 'no'}',
              ].join(' · '),
            ),
          ),
          const Divider(),
          const _SectionLabel('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('AeroStream'),
            subtitle: Text('Version 0.1.0 · open source'),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Licences'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'AeroStream',
            ),
          ),
          const Divider(),
          const _SectionLabel('Diagnostics'),
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('Installed extensions'),
            subtitle: Text(
              '${ref.watch(installedPluginsProvider).valueOrNull?.length ?? 0} '
              'installed on this device',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setTheme(WidgetRef ref, AppThemeVariant? variant) async {
    if (variant == null) return;
    await ref.read(persistedThemeProvider.notifier).select(variant);
  }

  Future<void> _chooseQuality(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    const options = <String>['Auto', '1080p', '720p', '480p', '360p'];
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Preferred quality'),
        children: [
          for (final option in options)
            RadioListTile<String>(
              value: option,
              groupValue: current,
              title: Text(option),
              onChanged: (value) => Navigator.of(context).pop(value),
            ),
        ],
      ),
    );
    if (choice != null) {
      await ref.read(preferencesProvider.notifier).setQuality(choice);
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
