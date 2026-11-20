import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme/theme_providers.dart';
import '../../core/app_info.dart';
import '../downloads/download_providers.dart';
import '../extensions/ecosystem_info.dart';
import '../extensions/ecosystem_providers.dart';
import '../extensions/extension_widgets.dart';
import '../library/history_providers.dart';
import '../library/library_providers.dart';
import 'settings_providers.dart';

/// Settings and diagnostics.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(persistedThemeProvider);
    final prefs = ref.watch(preferencesProvider);
    final platform = ref.watch(platformProfileProvider);
    // The matrix asks the CloudStream host for its handshake, so the rows
    // appear once that answers — a guess in the meantime would be a claim about
    // this build that the build has not made.
    final statuses = ref.watch(ecosystemStatusesProvider).valueOrNull;

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
          const _SectionLabel('Extensions'),
          // Three ecosystems, three destinations — the same split the
          // Extensions tab makes, reachable from Settings the way the other
          // clients put their provider pages here.
          for (final info in EcosystemInfo.all)
            _EcosystemSettingsTile(info: info),
          const Divider(),
          const _SectionLabel('Platform'),
          ListTile(
            leading: const Icon(Icons.devices_other),
            title: const Text('This device'),
            subtitle: Text(
              <String>[
                platform.target.name,
                platform.operatingSystem,
              ].where((part) => part.isNotEmpty).join(' · '),
            ),
          ),
          if (statuses == null)
            const ListTile(
              leading: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text('Checking which plugins can run here…'),
            )
          else
            for (final status in statuses)
              ListTile(
                leading: Icon(
                  status.runs ? Icons.check_circle_outline : Icons.block,
                  color: status.runs
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                ),
                title: Text(status.label),
                subtitle: Text(
                  status.reason ?? 'Runs here, in the JavaScript sandbox',
                ),
              ),
          const Divider(),
          const _SectionLabel('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text(appName),
            subtitle: Text('Version $appVersionLabel · open source'),
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
          const _SectionLabel('Your data'),
          ListTile(
            leading: const Icon(Icons.history_toggle_off),
            title: const Text('Clear watch history'),
            subtitle: const Text(
              'Removes continue-watching entries and resume positions',
            ),
            onTap: () => _clearHistory(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_remove_outlined),
            title: const Text('Clear saved titles'),
            subtitle: const Text('Empties the library; nothing is uninstalled'),
            onTap: () => _clearLibrary(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.download_done_outlined),
            title: const Text('Remove finished downloads'),
            subtitle: const Text('Deletes the files that already downloaded'),
            onTap: () => _removeFinishedDownloads(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.key_off_outlined),
            title: const Text('Delete plugin data'),
            subtitle: Text(
              '${ref.watch(providerPluginDataCount)} stored values: logins, '
              'cached tokens and mirror choices. Plugins stay installed.',
            ),
            onTap: () => _deletePluginData(context, ref),
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

  // ---- "Your data" ---------------------------------------------------------

  /// Every destructive action here is a confirmation first: these are the only
  /// buttons in the app that throw something away without a plugin to blame.
  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String message,
    required String action,
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  void _toast(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _clearHistory(BuildContext context, WidgetRef ref) async {
    final confirmed = await _confirm(
      context,
      title: 'Clear watch history?',
      message: 'Resume positions and continue watching go with it. Saved '
          'titles and downloads are untouched.',
      action: 'Clear',
    );
    if (!confirmed) return;
    await ref.read(historyProvider.notifier).clear();
    if (!context.mounted) return;
    _toast(context, 'Watch history cleared.');
  }

  Future<void> _clearLibrary(BuildContext context, WidgetRef ref) async {
    final confirmed = await _confirm(
      context,
      title: 'Clear saved titles?',
      message: 'The library empties. Plugins, downloads and history stay.',
      action: 'Clear',
    );
    if (!confirmed) return;
    await ref.read(libraryProvider.notifier).clear();
    if (!context.mounted) return;
    _toast(context, 'Library cleared.');
  }

  Future<void> _removeFinishedDownloads(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await _confirm(
      context,
      title: 'Remove finished downloads?',
      message: 'Deletes the downloaded files from this device. Titles that are '
          'still downloading keep going.',
      action: 'Remove',
    );
    if (!confirmed) return;
    await ref.read(downloadsProvider.notifier).removeFinished();
    if (!context.mounted) return;
    _toast(context, 'Finished downloads removed.');
  }

  Future<void> _deletePluginData(BuildContext context, WidgetRef ref) async {
    final store = ref.read(pluginDataStoreProvider);
    final count = store.stored().length;
    if (count == 0) {
      _toast(context, 'No plugin data stored.');
      return;
    }

    final confirmed = await _confirm(
      context,
      title: 'Delete plugin data?',
      message: 'Deletes $count stored values — logins a plugin saved, cached '
          'tokens and mirror choices. Installed plugins stay, and will ask for '
          'credentials again if they need them.',
      action: 'Delete',
    );
    if (!confirmed) return;

    final removed = await store.forgetAll();
    if (!context.mounted) return;
    ref.invalidate(providerPluginDataCount);
    // Providers cache their settings; a plugin whose token just vanished must
    // not keep running on the copy it read at startup.
    ref.invalidate(mediaProvidersProvider);
    _toast(context, 'Deleted $removed plugin values.');
  }
}

/// One ecosystem's row in Settings: counts on the left, its page on tap.
class _EcosystemSettingsTile extends ConsumerWidget {
  const _EcosystemSettingsTile({required this.info});

  final EcosystemInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repositories = ref.watch(ecosystemRepositoriesProvider(info.ecosystem));
    final installed = ref.watch(ecosystemInstalledProvider(info.ecosystem));
    final status = statusOf(context, ref, info.ecosystem);

    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: info.accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(info.icon, color: info.accent, size: 20),
      ),
      title: Text(info.title),
      subtitle: Text(
        <String>[
          '${repositories.length} source${repositories.length == 1 ? '' : 's'}',
          '${installed.length} installed',
          status == null ? null : (status.runs ? 'runs here' : 'unavailable'),
        ].whereType<String>().join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openEcosystem(context, info.ecosystem),
    );
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
