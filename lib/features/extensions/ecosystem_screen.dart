import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/installed_plugin.dart';
import '../../domain/entities/plugin_repository.dart';
import '../common/ecosystem_info.dart';
import 'ecosystem_providers.dart';
import 'extension_widgets.dart';
import 'extensions_providers.dart';

/// One ecosystem's page: what is installed, what its sources offer, and the
/// sources themselves.
///
/// This is the screen the other clients show as "Providers" / "Extensions", and
/// keeping it per-ecosystem is deliberate: a CloudStream shortcode is not a Vega
/// author, and a page that accepts both teaches neither.
class EcosystemScreen extends ConsumerStatefulWidget {
  const EcosystemScreen({required this.info, super.key});

  final EcosystemInfo info;

  @override
  ConsumerState<EcosystemScreen> createState() => _EcosystemScreenState();
}

class _EcosystemScreenState extends ConsumerState<EcosystemScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this)
    ..addListener(() => setState(() {}));

  EcosystemInfo get info => widget.info;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repositories =
        ref.watch(ecosystemRepositoriesProvider(info.ecosystem));
    final installed = ref.watch(ecosystemInstalledProvider(info.ecosystem));
    final catalog = ref.watch(ecosystemCatalogProvider(info.ecosystem));
    final available = catalog.valueOrNull?.listings.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(info.title),
        bottom: TabBar(
          controller: _tabs,
          indicatorSize: TabBarIndicatorSize.label,
          tabs: [
            Tab(text: 'Installed (${installed.length})'),
            Tab(text: available == null ? 'Browse' : 'Browse ($available)'),
            Tab(text: 'Sources (${repositories.length})'),
          ],
        ),
      ),
      body: Column(
        children: [
          _Header(info: info),
          _UnavailableNotice(info: info),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _InstalledTab(ecosystem: info.ecosystem, installed: installed),
                _BrowseTab(info: info),
                _SourcesTab(info: info, repositories: repositories),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: _tabs.index == 2 || repositories.isEmpty
          ? FloatingActionButton.extended(
              onPressed: _addRepository,
              icon: const Icon(Icons.add_link),
              label: const Text('Add repository'),
            )
          : null,
    );
  }

  Future<void> _addRepository() async {
    final added = await showAddRepositorySheet(
      context,
      ref,
      info.ecosystem,
    );
    if (added == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            added.ecosystem == info.ecosystem
                ? 'Added ${added.name}'
                : '${added.name} publishes ${added.ecosystem.label} plugins — '
                    'open that section to see them.',
          ),
        ),
      );
    if (added.ecosystem != info.ecosystem) {
      openEcosystem(context, added.ecosystem);
    }
  }
}

/// A slim, coloured summary above the tabs.
class _Header extends ConsumerWidget {
  const _Header({required this.info});

  final EcosystemInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: info.accent.withValues(alpha: 0.07),
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(info.icon, size: 16, color: info.accent),
          Text(
            info.artifact,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          EcosystemStatusChip(ecosystem: info.ecosystem),
        ],
      ),
    );
  }
}

/// Why a section cannot run its plugins here, when it cannot.
///
/// Shown instead of guessing: the CloudStream host is a native component, and a
/// build without it can still manage .cs3 files but cannot start them.
class _UnavailableNotice extends ConsumerWidget {
  const _UnavailableNotice({required this.info});

  final EcosystemInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = statusOf(context, ref, info.ecosystem);
    if (status == null || status.runs) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.block,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status.reason ??
                  'This device cannot run ${info.shortTitle} plugins.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- installed ------------------------------------------------------------

class _InstalledTab extends ConsumerWidget {
  const _InstalledTab({required this.ecosystem, required this.installed});

  final PluginEcosystem ecosystem;
  final List<InstalledPlugin> installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (installed.isEmpty) {
      return EmptyState(
        icon: Icons.extension_outlined,
        title: 'No ${EcosystemInfo.of(ecosystem).shortTitle} plugins yet',
        body: 'Install one from the Browse tab. Installed plugins appear here '
            'with their settings, mirrors and removal.',
      );
    }
    final enabled = installed.where((plugin) => plugin.info.enabled).length;
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 96),
      itemCount: installed.length + 1,
      separatorBuilder: (context, index) => const SizedBox.shrink(),
      itemBuilder: (context, index) {
        if (index == 0) {
          return ExtensionsSectionHeader(
            title: 'Installed',
            subtitle: '$enabled of ${installed.length} enabled',
          );
        }
        return InstalledPluginTile(plugin: installed[index - 1]);
      },
    );
  }
}

// ---- browse ---------------------------------------------------------------

class _BrowseTab extends ConsumerStatefulWidget {
  const _BrowseTab({required this.info});

  final EcosystemInfo info;

  @override
  ConsumerState<_BrowseTab> createState() => _BrowseTabState();
}

class _BrowseTabState extends ConsumerState<_BrowseTab> {
  final TextEditingController _filter = TextEditingController();
  bool _onlyInstallable = false;

  EcosystemInfo get info => widget.info;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repositories =
        ref.watch(ecosystemRepositoriesProvider(info.ecosystem));
    if (repositories.isEmpty) {
      return EmptyState(
        icon: Icons.travel_explore,
        title: 'No sources yet',
        body: 'Browse fills up once a ${info.shortTitle} repository is added. '
            '${info.addHelp}.',
        action: FilledButton.icon(
          onPressed: () async {
            await showAddRepositorySheet(context, ref, info.ecosystem);
          },
          icon: const Icon(Icons.add_link),
          label: const Text('Add repository'),
        ),
      );
    }

    final catalog = ref.watch(ecosystemCatalogProvider(info.ecosystem));
    final installed = ref.watch(ecosystemInstalledProvider(info.ecosystem));
    final busy = ref.watch(busyPluginsProvider);
    final theme = Theme.of(context);

    return catalog.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => EmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Could not read these sources',
        body: '$error',
        action: FilledButton(
          onPressed: () =>
              ref.invalidate(ecosystemCatalogProvider(info.ecosystem)),
          child: const Text('Try again'),
        ),
      ),
      data: (data) {
        final status =
            ref.watch(ecosystemStatusesProvider).valueOrNull?.firstWhereOrNull(
                  (entry) => entry.ecosystem == info.ecosystem,
                );
        final runsHere = status?.runs ?? true;
        final query = _filter.text.trim().toLowerCase();
        final visible = data.listings.where((plugin) {
          if (_onlyInstallable && !runsHere) return false;
          if (query.isEmpty) return true;
          return plugin.name.toLowerCase().contains(query) ||
              (plugin.description?.toLowerCase().contains(query) ?? false);
        }).toList(growable: false);

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _filter,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Filter ${info.shortTitle} plugins',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        suffixIcon: _filter.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () {
                                  _filter.clear();
                                  setState(() {});
                                },
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: runsHere
                        ? 'Hide what this device cannot run'
                        : 'This device cannot run this ecosystem',
                    isSelected: _onlyInstallable,
                    icon: const Icon(Icons.filter_alt_outlined, size: 20),
                    onPressed: () =>
                        setState(() => _onlyInstallable = !_onlyInstallable),
                  ),
                ],
              ),
            ),
            if (!data.isComplete)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${data.failures.length} source'
                        '${data.failures.length == 1 ? '' : 's'} could not be '
                        'read — the rest are shown.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: visible.isEmpty
                  ? EmptyState(
                      icon: Icons.inbox_outlined,
                      title: query.isEmpty
                          ? 'These sources list nothing'
                          : 'Nothing matches "${_filter.text.trim()}"',
                      body: query.isEmpty
                          ? 'The repository answered, but published no '
                              'readable plugins. Refresh it from Sources.'
                          : 'Try a shorter word, or clear the filter.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(top: 4, bottom: 96),
                      itemCount: visible.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) {
                        final listed = visible[index];
                        final matching = installed
                            .where(
                              (entry) =>
                                  entry.info.id == listed.id &&
                                  entry.info.ecosystem == listed.ecosystem,
                            )
                            .firstOrNull;
                        return AvailablePluginTile(
                          plugin: listed,
                          installed: matching,
                          busy: busy.contains(listed.id),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

// ---- sources --------------------------------------------------------------

class _SourcesTab extends ConsumerWidget {
  const _SourcesTab({required this.info, required this.repositories});

  final EcosystemInfo info;
  final List<PluginRepository> repositories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (repositories.isEmpty) {
      return EmptyState(
        icon: Icons.link_outlined,
        title: 'No ${info.shortTitle} sources',
        body: '${info.addHelp}.\n\nExamples: ${info.examples}',
        action: FilledButton.icon(
          onPressed: () async {
            await showAddRepositorySheet(context, ref, info.ecosystem);
          },
          icon: const Icon(Icons.add_link),
          label: const Text('Add repository'),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async {
        for (final repository in repositories) {
          await ref.read(repositoryServiceProvider).refresh(repository);
        }
        ref.invalidate(repositoriesProvider);
        ref.invalidate(ecosystemCatalogProvider(info.ecosystem));
      },
      child: ListView.separated(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        itemCount: repositories.length,
        separatorBuilder: (context, index) =>
            const Divider(height: 1, indent: 72),
        itemBuilder: (context, index) =>
            RepositoryTile(repository: repositories[index]),
      ),
    );
  }
}
