import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme/app_theme.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/home_section.dart';
import '../../domain/entities/media_item.dart';
import '../common/ecosystem_info.dart';
import '../common/media_card.dart';
import '../extensions/extension_widgets.dart';
import '../library/history_providers.dart';
import 'home_providers.dart';

/// The home feed.
///
/// Three states that matter: no plugins at all (the honest first run), plugins
/// but no rows (a plugin that has nothing to show), and the feed itself.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plugins = ref.watch(installedPluginsProvider).valueOrNull ?? const [];
    final feed = ref.watch(homeFeedProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AeroStream'),
        actions: [
          IconButton(
            tooltip: 'Search',
            onPressed: () => context.go('/search'),
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(homeFeedProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(installedPluginsProvider);
          ref.invalidate(homeFeedProvider);
          await ref.read(homeFeedProvider.future);
        },
        child: plugins.isEmpty
            ? const _FirstRun()
            : feed.when(
                loading: () => const _FeedSkeleton(),
                error: (error, stack) => _FeedError(error: error, ref: ref),
                data: (sections) => sections.isEmpty
                    ? const _EmptyFeed()
                    : _Feed(sections: sections),
              ),
      ),
    );
  }
}

class _Feed extends ConsumerWidget {
  const _Feed({required this.sections});

  final List<HomeSection> sections;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hero = sections.firstWhere(
      (section) => section.layout == HomeSectionLayout.carousel,
      orElse: () => sections.first,
    );
    final rows = sections.where((section) => section != hero).toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        const _ContinueWatching(),
        if (hero.items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                if (width < 640) {
                  return MediaHeroCard(
                    item: hero.items.first,
                    onTap: () => _open(context, hero.items.first),
                  );
                }
                // Wide layouts show three hero cards side by side.
                return SizedBox(
                  height: 260,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: hero.items.take(5).length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final item = hero.items[index];
                      return SizedBox(
                        width: 420,
                        child: MediaHeroCard(
                          item: item,
                          onTap: () => _open(context, item),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        for (final section in rows)
          if (section.items.isNotEmpty) _SectionRow(section: section),
      ],
    );
  }

  static void _open(BuildContext context, MediaItem item) {
    context.push('/details', extra: item);
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({required this.section});

  final HomeSection section;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: section.title),
        SizedBox(
          height: 252,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: section.items.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = section.items[index];
              return MediaPosterCard(
                item: item,
                onTap: () => context.push('/details', extra: item),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FirstRun extends StatelessWidget {
  const _FirstRun();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 40),
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: <Color>[AppTheme.seed, AppTheme.accent],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            size: 36,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          'Nothing installed yet',
          style: theme.textTheme.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'AeroStream has no built-in catalogue. Pick the ecosystem your sources '
          'belong to, add a repository there, and install what it offers.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 26),
        for (final info in EcosystemInfo.all) ...[
          _FirstRunEcosystem(info: info),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 6),
        Text(
          'Extensions live under Extensions and in Settings at any time.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// One ecosystem, offered as the first step of a fresh install.
class _FirstRunEcosystem extends StatelessWidget {
  const _FirstRunEcosystem({required this.info});

  final EcosystemInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        onTap: () => openEcosystem(context, info.ecosystem),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: info.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(info.icon, color: info.accent, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.title,
                      style: theme.textTheme.titleMedium,
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
        ),
      ),
    );
  }
}

class _EmptyFeed extends StatelessWidget {
  const _EmptyFeed();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 64),
        Icon(
          Icons.inbox_outlined,
          size: 48,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 16),
        Text(
          'Your extensions returned nothing',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'The plugins are installed, but none of them produced a home row. '
          'Pull down to refresh, or open Extensions to check them.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        SkeletonBox(height: 200, radius: 18),
        SizedBox(height: 24),
        SkeletonBox(height: 20, width: 160),
        SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: Row(
            children: [
              SkeletonBox(height: 200, width: 130),
              SizedBox(width: 12),
              SkeletonBox(height: 200, width: 130),
              SizedBox(width: 12),
              SkeletonBox(height: 200, width: 130),
            ],
          ),
        ),
      ],
    );
  }
}

class _FeedError extends StatelessWidget {
  const _FeedError({required this.error, required this.ref});

  final Object error;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 48),
        PluginErrorBanner(
          message: 'The feed could not be built: $error',
          onRetry: () => ref.invalidate(homeFeedProvider),
        ),
      ],
    );
  }
}

/// A shelf of half-watched titles, above everything else.
///
/// This is the one row that is about the user rather than the plugin, so it
/// comes first — and it disappears entirely on a fresh install instead of
/// showing an empty header.
class _ContinueWatching extends ConsumerWidget {
  const _ContinueWatching();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(continueWatchingProvider);
    if (entries.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: 'Continue watching',
          onSeeAll: () => context.go('/library'),
        ),
        SizedBox(
          height: 252,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: entries.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return MediaPosterCard(
                item: entry.item,
                progress: entry.progress,
                onTap: () => context.push(
                  '/watch',
                  extra: (item: entry.item, episode: entry.episode),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
