import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/result.dart';
import '../../core/utils/version.dart';
import '../../domain/entities/installed_plugin.dart';
import '../../domain/entities/plugin_info.dart';
import '../../domain/entities/plugin_repository.dart';
import 'extensions_providers.dart';

/// Repository and plugin management.
///
/// Three tabs mirror the user's mental model: what is installed, what a
/// repository offers, and which repositories exist.
class ExtensionsScreen extends ConsumerWidget {
  const ExtensionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Extensions'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Installed'),
              Tab(text: 'Browse'),
              Tab(text: 'Repositories'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [_InstalledTab(), _BrowseTab(), _RepositoriesTab()],
        ),
      ),
    );
  }
}

// ---- installed ------------------------------------------------------------

class _InstalledTab extends ConsumerWidget {
  const _InstalledTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = ref.watch(installedPluginsProvider);

    return installed.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('$error')),
      data: (plugins) {
        if (plugins.isEmpty) {
          return const _EmptyState(
            icon: Icons.extension_outlined,
            title: 'No extensions installed',
            body: 'Add a repository in the Repositories tab, then install a '
                'plugin from Browse.',
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 32),
          itemCount: plugins.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (context, index) =>
              _InstalledTile(plugin: plugins[index]),
        );
      },
    );
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

class _InstalledTile extends ConsumerWidget {
  const _InstalledTile({required this.plugin});

  final InstalledPlugin plugin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ExtensionActions(ref);
    final busy = ref.watch(busyPluginsProvider).contains(plugin.info.id);
    final runsHere = actions.runsHere(plugin);
    final theme = Theme.of(context);

    return ListTile(
      isThreeLine: true,
      leading: _PluginIcon(url: plugin.info.iconUrl),
      title: Row(
        children: [
          Flexible(child: Text(plugin.info.name)),
          const SizedBox(width: 8),
          _EcosystemBadge(label: plugin.info.ecosystem.label),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            <String>[
              'v${plugin.info.version.raw}',
              if (plugin.info.language != null) plugin.info.language!,
              if (!runsHere) 'not available on this platform',
            ].join(' · '),
          ),
          if (!runsHere)
            Text(
              actions.platform.unsupportedReason(plugin.info.ecosystem) ?? '',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
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
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (runsHere && plugin.info.endpoints.isNotEmpty)
                  IconButton(
                    tooltip: 'Mirrors and providers',
                    icon: const Icon(Icons.tune),
                    onPressed: () => _showEndpoints(context, ref, plugin),
                  ),
                if (runsHere)
                  Switch(
                    value: plugin.info.enabled,
                    onChanged: (value) =>
                        actions.setEnabled(plugin, enabled: value),
                  ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmRemove(context, ref, plugin),
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

// ---- browse ---------------------------------------------------------------

class _BrowseTab extends ConsumerWidget {
  const _BrowseTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repositories = ref.watch(repositoriesProvider);

    return repositories.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(child: Text('$error')),
      data: (items) {
        if (items.isEmpty) {
          return const _EmptyState(
            icon: Icons.travel_explore,
            title: 'No repositories yet',
            body: 'Add a repository URL in the Repositories tab to see what it '
                'offers.',
          );
        }
        return _RepositoryBrowser(repositories: items);
      },
    );
  }
}

class _RepositoryBrowser extends ConsumerStatefulWidget {
  const _RepositoryBrowser({required this.repositories});

  final List<PluginRepository> repositories;

  @override
  ConsumerState<_RepositoryBrowser> createState() => _RepositoryBrowserState();
}

class _RepositoryBrowserState extends ConsumerState<_RepositoryBrowser> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final selected = _selected ?? widget.repositories.first.id;
    final plugins = ref.watch(repositoryPluginsProvider(selected));
    final installed =
        ref.watch(installedPluginsProvider).valueOrNull ?? const [];
    final busy = ref.watch(busyPluginsProvider);

    return Column(
      children: [
        SizedBox(
          height: 56,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount: widget.repositories.length,
            separatorBuilder: (context, index) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final repository = widget.repositories[index];
              return ChoiceChip(
                label: Text(repository.name),
                selected: repository.id == selected,
                onSelected: (_) => setState(() => _selected = repository.id),
              );
            },
          ),
        ),
        Expanded(
          child: plugins.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not read this repository: $error'),
              ),
            ),
            data: (available) {
              if (available.isEmpty) {
                return const _EmptyState(
                  icon: Icons.inbox_outlined,
                  title: 'Nothing in this repository',
                  body: 'It published no plugins. Try refreshing it from the '
                      'Repositories tab.',
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.only(bottom: 32),
                itemCount: available.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final listed = available[index];
                  final matching = installed
                      .where(
                        (entry) =>
                            entry.info.id == listed.id &&
                            entry.info.ecosystem == listed.ecosystem,
                      )
                      .firstOrNull;
                  return _AvailableTile(
                    plugin: listed,
                    installed: matching,
                    busy: busy.contains(listed.id),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AvailableTile extends ConsumerWidget {
  const _AvailableTile({
    required this.plugin,
    required this.installed,
    required this.busy,
  });

  final AvailablePlugin plugin;
  final InstalledPlugin? installed;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ExtensionActions(ref);
    final reason = actions.unsupportedReason(plugin);
    final installedVersion = installed?.info.version;

    return ListTile(
      isThreeLine: true,
      leading: _PluginIcon(url: plugin.iconUrl),
      title: Row(
        children: [
          Flexible(child: Text(plugin.name)),
          const SizedBox(width: 8),
          _EcosystemBadge(label: plugin.ecosystem.label),
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
              if (installedVersion != null)
                'installed v${installedVersion.raw}',
              // CloudStream repositories flag providers as slow or beta; the
              // user should see that before installing, not after.
              if (plugin.statusNote case final note?) note,
              if (reason != null) reason,
            ].join(' · '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _InstallButton(
              installed: installedVersion,
              listed: plugin.version,
              enabled: reason == null,
              onInstall: () => _install(context, ref),
            ),
    );
  }

  Future<void> _install(BuildContext context, WidgetRef ref) async {
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

class _InstallButton extends StatelessWidget {
  const _InstallButton({
    required this.installed,
    required this.listed,
    required this.enabled,
    required this.onInstall,
  });

  final PluginVersion? installed;
  final PluginVersion listed;
  final bool enabled;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final isInstalled = installed != null;
    final isNewer = isInstalled && listed > installed!;
    final label = isNewer ? 'Update' : (isInstalled ? 'Reinstall' : 'Install');
    return FilledButton.tonal(
      onPressed: enabled ? onInstall : null,
      child: Text(label),
    );
  }
}

// ---- repositories ---------------------------------------------------------

class _RepositoriesTab extends ConsumerWidget {
  const _RepositoriesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repositories = ref.watch(repositoriesProvider);

    return Scaffold(
      body: repositories.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(child: Text('$error')),
        data: (items) {
          if (items.isEmpty) {
            return const _EmptyState(
              icon: Icons.link_outlined,
              title: 'No repositories',
              body: 'AeroStream has no built-in sources. Add the URL of a '
                  'SkyStream, Vega or CloudStream repository to begin.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: items.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) => _RepositoryTile(
              repository: items[index],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddDialog(context, ref),
        icon: const Icon(Icons.add_link),
        label: const Text('Add repository'),
      ),
    );
  }

  Future<void> _showAddDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    String? error;
    var busy = false;

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('Add repository'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Repo URL, shortcode or Vega author',
                    helperText: 'A URL, a CloudStream/SkyStream shortcode '
                        '(abc123), or a Vega author (name, name@gl)',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'AeroStream reads the manifest and detects whether this is a '
                  'SkyStream, Vega or CloudStream repository.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() {
                          busy = true;
                          error = null;
                        });
                        final result = await ExtensionActions(
                          ref,
                        ).addRepository(controller.text);
                        if (!context.mounted) return;
                        switch (result) {
                          case Ok<PluginRepository>(:final value):
                            Navigator.of(context).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Added ${value.name} '
                                  '(${value.ecosystem.label})',
                                ),
                              ),
                            );
                          case Err<PluginRepository>(error: final failure):
                            setState(() {
                              busy = false;
                              error = failure.userMessage;
                            });
                        }
                      },
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Add'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
  }
}

class _RepositoryTile extends ConsumerWidget {
  const _RepositoryTile({required this.repository});

  final PluginRepository repository;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final actions = ExtensionActions(ref);
    return ListTile(
      leading: _PluginIcon(url: repository.iconUrl),
      title: Row(
        children: [
          Flexible(child: Text(repository.name)),
          const SizedBox(width: 8),
          _EcosystemBadge(label: repository.ecosystem.label),
        ],
      ),
      subtitle: Text(
        repository.description ?? repository.url,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) async {
          switch (value) {
            case 'refresh':
              await actions.refreshRepository(repository);
            case 'remove':
              await actions.removeRepository(repository);
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'refresh', child: Text('Refresh')),
          PopupMenuItem(value: 'remove', child: Text('Remove')),
        ],
      ),
    );
  }
}

// ---- shared bits ----------------------------------------------------------

class _PluginIcon extends StatelessWidget {
  const _PluginIcon({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final fallback = CircleAvatar(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: const Icon(Icons.extension, size: 20),
    );
    if (url == null || url!.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url!,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => fallback,
      ),
    );
  }
}

class _EcosystemBadge extends StatelessWidget {
  const _EcosystemBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
