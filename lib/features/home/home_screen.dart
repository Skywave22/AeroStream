import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/home_section.dart';
import '../../domain/entities/media_item.dart';
import '../common/media_card.dart';
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

class _Feed extends StatelessWidget {
  const _Feed({required this.sections});

  final List<HomeSection> sections;

  @override
  Widget build(BuildContext context) {
    final hero = sections.firstWhere(
      (section) => section.layout == HomeSectionLayout.carousel,
      orElse: () => sections.first,
    );
    final rows = sections.where((section) => section != hero).toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
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
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 48),
        Icon(
          Icons.live_tv_rounded,
          size: 56,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 24),
        Text(
          'Nothing installed yet',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'AeroStream has no built-in catalogue. Add a repository and install '
          'an extension — SkyStream, Vega or CloudStream — and its home rows, '
          'search and streams appear here.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 28),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => context.go('/extensions'),
            icon: const Icon(Icons.add_link_rounded),
            label: const Text('Add a repository'),
          ),
        ),
      ],
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
