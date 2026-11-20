import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/platform/ecosystem_status.dart';
import '../../core/result.dart';
import '../../core/utils/version.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/installed_plugin.dart';
import '../../domain/entities/plugin_info.dart';
import '../../domain/entities/plugin_repository.dart';
import '../common/ecosystem_info.dart';
import '../common/ui_kit.dart';
import 'ecosystem_providers.dart';
import 'extensions_providers.dart';

// Re-exported: a screen that manages extensions almost always needs the badge,
// the pill and the empty state too.
export '../common/ui_kit.dart'
    show CountPill, EcosystemBadge, EmptyState, PluginIcon;

// ---- shared visuals -------------------------------------------------------

/// Install / Update / Reinstall, in one button that says which it is.
class InstallButton extends StatelessWidget {
  const InstallButton({
    required this.installed,
    required this.listed,
    required this.enabled,
    required this.onInstall,
    super.key,
  });

  final PluginVersion? installed;
  final PluginVersion listed;
  final bool enabled;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final isInstalled = installed != null;
    final isNewer = isInstalled && listed > installed!;
    if (!enabled) {
      return const Icon(Icons.block, size: 20);
    }
    if (isNewer) {
      return FilledButton.icon(
        onPressed: onInstall,
        icon: const Icon(Icons.upgrade, size: 16),
        label: const Text('Update'),
      );
    }
    if (isInstalled) {
      return OutlinedButton(
        onPressed: onInstall,
        child: const Text('Reinstall'),
      );
    }
    return FilledButton(
      onPressed: onInstall,
      child: const Text('Install'),
    );
  }
}

// ---- add repository -------------------------------------------------------

/// "Add repository", scoped to one ecosystem.
///
/// The scope is the point: a list added from the CloudStream page is read as a
/// CloudStream list, so an entry that a heuristic could read either way cannot
/// land in the wrong section. The repository's own entries still have the last
/// word — if it publishes another ecosystem's plugins, the message says so.
Future<PluginRepository?> showAddRepositorySheet(
  BuildContext context,
  WidgetRef ref,
  PluginEcosystem ecosystem,
) {
  return showModalBottomSheet<PluginRepository>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _AddRepositorySheet(ecosystem: ecosystem),
  );
}

class _AddRepositorySheet extends ConsumerStatefulWidget {
  const _AddRepositorySheet({required this.ecosystem});

  final PluginEcosystem ecosystem;

  @override
  ConsumerState<_AddRepositorySheet> createState() =>
      _AddRepositorySheetState();
}

class _AddRepositorySheetState extends ConsumerState<_AddRepositorySheet> {
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = EcosystemInfo.of(widget.ecosystem);
    final insets = MediaQuery.viewInsetsOf(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + insets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(info.icon, color: info.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Add ${info.shortTitle} repository',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            info.addHelp,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enabled: !_busy,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: 'Repository URL or code',
              prefixIcon: const Icon(Icons.link),
              helperText: info.examples,
              helperMaxLines: 2,
              errorText: _error,
              errorMaxLines: 4,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  'AeroStream ships no sources and installs nothing by itself.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Add'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final input = _controller.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Enter a URL or a repository code');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    final result = await ExtensionActions(ref).addRepository(
      input,
      expect: widget.ecosystem,
    );
    if (!mounted) return;

    switch (result) {
      case Ok<PluginRepository>(:final value):
        Navigator.of(context).pop(value);
      case Err<PluginRepository>(:final error):
        setState(() {
          _busy = false;
          _error = error.userMessage;
        });
    }
  }
}

// ---- installed ------------------------------------------------------------

/// One installed plugin, with its switches and its removal.
class InstalledPluginTile extends ConsumerWidget {
  const InstalledPluginTile({required this.plugin, super.key});

  final InstalledPlugin plugin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ExtensionActions(ref);
    final busy = ref.watch(busyPluginsProvider).contains(plugin.info.id);
    // The support matrix knows about the CloudStream host, which the platform
    // alone does not: an Android build without it can install .cs3 files and
    // never start them.
    final status = actions.statusFor(
      ref.watch(ecosystemStatusesProvider).valueOrNull,
      plugin.info.ecosystem,
    );
    final runsHere = status?.runs ?? actions.runsHere(plugin);
    final theme = Theme.of(context);
    final update = ref.watch(ecosystemCatalogProvider(plugin.info.ecosystem));
    final upgrade = update.valueOrNull == null
        ? null
        : actions.upgradeFor(plugin, update.valueOrNull!.listings);

    return ListTile(
      isThreeLine: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: PluginIcon(url: plugin.info.iconUrl),
      title: Row(
        children: [
          Flexible(
            child: Text(
              plugin.info.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          if (upgrade != null)
            const CountPill(label: 'Update', icon: Icons.upgrade),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            <String>[
              'v${plugin.info.version.raw}',
              if (plugin.info.language != null) plugin.info.language!,
              if (!plugin.info.enabled) 'disabled',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          if (!runsHere)
            Text(
              status?.reason ??
                  actions.platform.unsupportedReason(plugin.info.ecosystem) ??
                  '',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
        ],
      ),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (value) async {
                switch (value) {
                  case 'toggle':
                    await actions.setEnabled(
                      plugin,
                      enabled: !plugin.info.enabled,
                    );
                  case 'endpoints':
                    await _showEndpoints(context, ref, plugin);
                  case 'remove':
                    await _confirmRemove(context, ref, plugin);
                }
              },
              itemBuilder: (context) => <PopupMenuEntry<String>>[
                if (runsHere)
                  PopupMenuItem(
                    value: 'toggle',
                    child: Text(
                      plugin.info.enabled ? 'Disable' : 'Enable',
                    ),
                  ),
                if (runsHere && plugin.info.endpoints.isNotEmpty)
                  const PopupMenuItem(
                    value: 'endpoints',
                    child: Text('Mirrors and providers'),
                  ),
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('Remove'),
                ),
              ],
            ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    InstalledPlugin plugin,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${plugin.info.name}?'),
        content: const Text(
          'The plugin and its files are deleted from this device. Titles it '
          'provided stay in your library, marked as unavailable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ExtensionActions(ref).uninstall(plugin);
    }
  }
}

/// Mirrors and sub-providers, as one list.
///
/// SkyStream declares both in `plugin.json`; the app injects the chosen value as
/// `manifest.baseUrl` (a mirror) or `manifest.providerId` (a sub-provider), so
/// the plugin's own code does not change when the user switches.
Future<void> _showEndpoints(
  BuildContext context,
  WidgetRef ref,
  InstalledPlugin plugin,
) async {
  final actions = ExtensionActions(ref);
  final selected = actions.selectedEndpoint(plugin);
  final chosen = await showModalBottomSheet<Object?>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(
            title: Text('Mirrors and providers'),
            subtitle: Text(
              'Where this plugin connects. The plugin sees the choice as its '
              'base URL; nothing else changes.',
            ),
          ),
          const Divider(height: 1),
          RadioListTile<String?>(
            value: null,
            groupValue: selected?.id,
            onChanged: (value) => Navigator.of(context).pop('__default__'),
            title: const Text('Plugin default'),
          ),
          for (final endpoint in plugin.info.endpoints)
            RadioListTile<String?>(
              value: endpoint.id,
              groupValue: selected?.id,
              onChanged: (value) => Navigator.of(context).pop(endpoint),
              title: Text(endpoint.name),
              subtitle: endpoint.baseUrl == null
                  ? const Text('resolved by the plugin at runtime')
                  : Text(endpoint.baseUrl!),
            ),
        ],
      ),
    ),
  );

  if (chosen == null) return;
  await actions.selectEndpoint(
    plugin,
    chosen is PluginEndpoint ? chosen : null,
  );
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        chosen is PluginEndpoint
            ? 'Using ${chosen.name}. Reload the feed to see it.'
            : 'Back to the plugin default.',
      ),
    ),
  );
}

// ---- available ------------------------------------------------------------

/// One plugin a repository offers.
class AvailablePluginTile extends ConsumerWidget {
  const AvailablePluginTile({
    required this.plugin,
    required this.installed,
    required this.busy,
    super.key,
  });

  final AvailablePlugin plugin;
  final InstalledPlugin? installed;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ExtensionActions(ref);
    final status = actions.statusFor(
      ref.watch(ecosystemStatusesProvider).valueOrNull,
      plugin.ecosystem,
    );
    final reason = status?.reason ?? actions.unsupportedReason(plugin);
    final installedVersion = installed?.info.version;
    final theme = Theme.of(context);

    return ListTile(
      isThreeLine: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: PluginIcon(url: plugin.iconUrl),
      title: Row(
        children: [
          Flexible(
            child: Text(
              plugin.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          if (installedVersion != null)
            CountPill(
              label: 'v${installedVersion.raw}',
              icon: Icons.check,
              color: theme.colorScheme.primary,
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (plugin.description?.isNotEmpty ?? false)
            Text(
              plugin.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            <String>[
              'v${plugin.version.raw}',
              // CloudStream repositories flag providers as slow or beta; the
              // user should see that before installing, not after.
              if (plugin.statusNote case final note?) note,
              if (reason != null) reason,
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: reason != null ? theme.colorScheme.error : null,
            ),
          ),
        ],
      ),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : InstallButton(
              installed: installedVersion,
              listed: plugin.version,
              enabled: reason == null,
              onInstall: () => _install(context, ref),
            ),
    );
  }

  Future<void> _install(BuildContext context, WidgetRef ref) async {
    // One path for install, update and reinstall: the manager keeps the old
    // artifact as a rollback target either way.
    final result = await ExtensionActions(ref).install(plugin);
    if (!context.mounted) return;
    switch (result) {
      case Ok<InstalledPlugin>(:final value):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Installed ${value.info.name}')),
        );
      case Err<InstalledPlugin>(:final error):
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Install failed: ${error.userMessage}')),
        );
    }
  }
}

// ---- repositories ---------------------------------------------------------

/// One source, with its refresh and its removal.
class RepositoryTile extends ConsumerWidget {
  const RepositoryTile({
    required this.repository,
    this.showEcosystem = false,
    super.key,
  });

  final PluginRepository repository;

  /// The hub lists sources across ecosystems, so it needs the badge.
  final bool showEcosystem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ExtensionActions(ref);
    final theme = Theme.of(context);
    final count = ref
        .watch(ecosystemCatalogProvider(repository.ecosystem))
        .valueOrNull
        ?.listings
        .where((plugin) => plugin.repositoryId == repository.id)
        .length;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: PluginIcon(url: repository.iconUrl, size: 40),
      title: Row(
        children: [
          Flexible(
            child: Text(
              repository.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          if (showEcosystem) EcosystemBadge(ecosystem: repository.ecosystem),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (repository.description?.isNotEmpty ?? false)
            Text(
              repository.description!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            count == null
                ? repository.url
                : '$count plugin${count == 1 ? '' : 's'} · ${repository.url}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        onSelected: (value) async {
          switch (value) {
            case 'refresh':
              await actions.refreshRepository(repository);
            case 'remove':
              await actions.removeRepository(repository);
          }
        },
        itemBuilder: (context) => const <PopupMenuEntry<String>>[
          PopupMenuItem(value: 'refresh', child: Text('Refresh')),
          PopupMenuItem(value: 'remove', child: Text('Remove')),
        ],
      ),
    );
  }
}

/// A section heading that matches the rest of the app.
///
/// Named apart from the media shelves' `SectionHeader` so a screen can import
/// both.
class ExtensionsSectionHeader extends StatelessWidget {
  const ExtensionsSectionHeader({
    required this.title,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// The support-matrix row for a section, shown next to its header.
class EcosystemStatusChip extends ConsumerWidget {
  const EcosystemStatusChip({required this.ecosystem, super.key});

  final PluginEcosystem ecosystem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statuses = ref.watch(ecosystemStatusesProvider).valueOrNull;
    final status = statuses?.firstWhereOrNull(
      (candidate) => candidate.ecosystem == ecosystem,
    );
    final theme = Theme.of(context);
    if (status == null) {
      return const CountPill(label: 'checking…', icon: Icons.hourglass_empty);
    }
    return CountPill(
      label: status.runs ? 'runs here' : 'not on this device',
      icon: status.runs ? Icons.check_circle : Icons.block,
      color: status.runs ? theme.colorScheme.primary : theme.colorScheme.error,
    );
  }
}

/// Opens a section of the Extensions hub from anywhere (Settings included).
///
/// Pushed, not switched to: a section is a destination with its own back arrow,
/// and the tab bar keeps saying Extensions because that is where it lives.
void openEcosystem(BuildContext context, PluginEcosystem ecosystem) {
  context.push('/extensions/${ecosystem.wire}');
}

/// The one place "which status does this ecosystem have" is answered.
EcosystemStatus? statusOf(
  BuildContext context,
  WidgetRef ref,
  PluginEcosystem ecosystem,
) {
  final statuses = ref.watch(ecosystemStatusesProvider).valueOrNull;
  return statuses?.firstWhereOrNull(
    (candidate) => candidate.ecosystem == ecosystem,
  );
}
