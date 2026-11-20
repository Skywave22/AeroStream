import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/installed_plugin.dart';
import '../../domain/entities/plugin_repository.dart';
import 'ecosystem_info.dart';
import 'ecosystem_providers.dart';
import 'extension_widgets.dart';
import 'extensions_providers.dart';

/// The Extensions hub.
///
/// Three ecosystems, three sections. Each one owns its sources, its catalogue
/// and its installed plugins, exactly as the ecosystem it runs does — a user
/// who installs SkyStream providers goes to SkyStream and finds a repository
/// box that only speaks SkyStream.
class ExtensionsScreen extends ConsumerWidget {
  const ExtensionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repositories = ref.watch(repositoriesProvider).valueOrNull ??
        const <PluginRepository>[];
    final installed = ref.watch(installedPluginsProvider).valueOrNull ??
        const <InstalledPlugin>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Extensions'),
        actions: [
          IconButton(
            tooltip: 'Check all sources for updates',
            icon: const Icon(Icons.refresh),
            onPressed: () => _checkUpdates(context, ref),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(repositoriesProvider);
          for (final info in EcosystemInfo.all) {
            ref.invalidate(ecosystemCatalogProvider(info.ecosystem));
          }
          await ref.read(repositoriesProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            const _HubHeader(),
            for (final info in EcosystemInfo.all)
              _EcosystemCard(
                info: info,
                repositories: repositories
                    .where((entry) => entry.ecosystem == info.ecosystem)
                    .toList(growable: false),
                installedCount: installed
                    .where((entry) => entry.info.ecosystem == info.ecosystem)
                    .length,
              ),
            const _HubFooter(),
          ],
        ),
      ),
    );
  }

  Future<void> _checkUpdates(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final updates = await ExtensionActions(ref).findUpdates();
    if (!context.mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            updates.isEmpty
                ? 'Every source is up to date.'
                : '${updates.length} update${updates.length == 1 ? '' : 's'} '
                    'available.',
          ),
        ),
      );
  }
}

class _HubHeader extends StatelessWidget {
  const _HubHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Bring your own sources',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'AeroStream ships with no content. Add a repository in the section '
            'that matches it, then install what it offers.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

/// One ecosystem, as a card that opens its own page.
class _EcosystemCard extends ConsumerWidget {
  const _EcosystemCard({
    required this.info,
    required this.repositories,
    required this.installedCount,
  });

  final EcosystemInfo info;
  final List<PluginRepository> repositories;
  final int installedCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accent = info.accent;
    final title = info.shortTitle;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openEcosystem(context, info.ecosystem),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Colour band: the only place the accent is loud.
              SizedBox(
                height: 4,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: <Color>[
                        accent,
                        accent.withValues(alpha: 0.25),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(info.icon, color: accent, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                info.title,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                info.tagline,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        CountPill(
                          label: _sourceLabel(repositories.length),
                          icon: Icons.link,
                        ),
                        CountPill(
                          label: '$installedCount installed',
                          icon: Icons.extension,
                        ),
                        EcosystemStatusChip(ecosystem: info.ecosystem),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => _add(context, ref),
                          icon: const Icon(Icons.add_link, size: 18),
                          label: const Text('Add repository'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              openEcosystem(context, info.ecosystem),
                          child: Text('Open $title'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _sourceLabel(int count) {
    if (count == 0) return 'no sources yet';
    return '$count source${count == 1 ? '' : 's'}';
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final added = await showAddRepositorySheet(context, ref, info.ecosystem);
    if (added == null || !context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            added.ecosystem == info.ecosystem
                ? '${info.shortTitle} source added: ${added.name}'
                : '${added.name} publishes ${added.ecosystem.label} plugins, so '
                    'it was filed under ${added.ecosystem.label}.',
          ),
        ),
      );
    if (added.ecosystem != info.ecosystem) {
      openEcosystem(context, added.ecosystem);
    }
  }
}

class _HubFooter extends ConsumerWidget {
  const _HubFooter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repositories =
        ref.watch(repositoriesProvider).valueOrNull ?? const [];
    if (repositories.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Nothing is installed yet. Pick an ecosystem above and paste '
                  'the link to a repository you trust.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
