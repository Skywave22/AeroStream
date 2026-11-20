import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/media_details.dart';
import '../../domain/entities/media_item.dart';
import '../../domain/services/catalog_service.dart';
import '../common/media_card.dart';
import '../library/library_providers.dart';
import 'details_providers.dart';

/// Metadata, seasons and episodes for one title.
class DetailsScreen extends ConsumerStatefulWidget {
  const DetailsScreen({required this.item, super.key});

  final MediaItem item;

  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  int? _season;

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(detailsProvider(widget.item));

    return Scaffold(
      body: details.when(
        loading: () => const _DetailsSkeleton(),
        error: (error, stack) => _DetailsError(
          error: error,
          onRetry: () => ref.invalidate(detailsProvider(widget.item)),
        ),
        data: (value) => _DetailsBody(
          details: value,
          season: _season,
          onSeasonChanged: (season) => setState(() => _season = season),
        ),
      ),
      floatingActionButton: details.valueOrNull == null
          ? null
          : _LibraryButton(item: details.valueOrNull!.item),
    );
  }
}

class _DetailsBody extends ConsumerWidget {
  const _DetailsBody({
    required this.details,
    required this.season,
    required this.onSeasonChanged,
  });

  final MediaDetails details;
  final int? season;
  final ValueChanged<int> onSeasonChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final item = details.item;
    final seasons = details.effectiveSeasons;
    final selectedSeason =
        season ?? (seasons.isEmpty ? 1 : seasons.first.number);
    final episodes = details.isEpisodic
        ? details.episodesOf(selectedSeason)
        : const <Episode>[];

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          expandedHeight: 320,
          pinned: true,
          leading: BackButton(onPressed: () => context.pop()),
          flexibleSpace: FlexibleSpaceBar(
            background: _Backdrop(item: item),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (item.originalTitle != null &&
                    item.originalTitle != item.title)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      item.originalTitle!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (item.year != null) _Chip(text: '${item.year}'),
                    if (details.runtimeMinutes != null)
                      _Chip(text: '${details.runtimeMinutes} min'),
                    if (item.rating != null)
                      _Chip(text: '★ ${item.rating!.toStringAsFixed(1)}'),
                    if (details.contentRating != null)
                      _Chip(text: details.contentRating!),
                    if (details.status != null) _Chip(text: details.status!),
                    for (final genre in details.genres.take(4))
                      _Chip(text: genre),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => _play(context, episodes),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        details.isEpisodic ? 'Play first episode' : 'Play',
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: () => _showSources(context, ref),
                      icon: const Icon(Icons.dns_outlined),
                      label: const Text('Sources'),
                    ),
                  ],
                ),
                if (details.description != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    details.description!,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                  ),
                ],
                if (details.cast.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Cast',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    details.cast
                        .take(8)
                        .map(
                          (actor) => actor.role == null
                              ? actor.name
                              : '${actor.name} (${actor.role})',
                        )
                        .join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (seasons.length > 1)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: seasons.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final candidate = seasons[index];
                  return ChoiceChip(
                    label: Text(candidate.displayName),
                    selected: candidate.number == selectedSeason,
                    onSelected: (_) => onSeasonChanged(candidate.number),
                  );
                },
              ),
            ),
          ),
        if (episodes.isNotEmpty)
          SliverList.builder(
            itemCount: episodes.length,
            itemBuilder: (context, index) => _EpisodeTile(
              episode: episodes[index],
              onTap: () => _openEpisode(context, episodes[index]),
            ),
          ),
        if (details.recommendations.isNotEmpty)
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(title: 'More like this'),
                SizedBox(
                  height: 240,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: details.recommendations.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 12),
                    itemBuilder: (context, index) => MediaPosterCard(
                      item: details.recommendations[index],
                      onTap: () => context.push(
                        '/details',
                        extra: details.recommendations[index],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 88)),
      ],
    );
  }

  void _play(BuildContext context, List<Episode> episodes) {
    context.push(
      '/watch',
      extra: (
        item: details.item,
        episode: episodes.isEmpty ? null : episodes.first,
      ),
    );
  }

  void _openEpisode(BuildContext context, Episode episode) {
    context.push(
      '/watch',
      extra: (item: details.item, episode: episode),
    );
  }

  void _showSources(BuildContext context, WidgetRef ref) {
    final providers = ref.read(mediaProvidersProvider).valueOrNull ?? const [];
    final owner = CatalogService.providerFor(providers, details.item);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Provided by',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (owner != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.extension_outlined),
                title: Text(owner.info.name),
                subtitle: Text(
                  '${owner.info.ecosystem.label} · '
                  'v${owner.info.version.raw}',
                ),
              ),
            const SizedBox(height: 8),
            Text(
              details.instantSources.isEmpty
                  ? 'Links are resolved when you press play.'
                  : '${details.instantSources.length} link(s) are ready.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({required this.episode, required this.onTap});

  final Episode episode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '${episode.number}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
      ),
      title: Text(
        episode.title?.isNotEmpty ?? false
            ? episode.title!
            : 'Episode ${episode.number}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: episode.description == null
          ? null
          : Text(
              episode.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: const Icon(Icons.play_circle_outline),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = item.backdropUrl ?? item.posterUrl;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (url != null && url.isNotEmpty)
          Image.network(
            url,
            fit: BoxFit.cover,
            headers: item.headers.isEmpty ? null : item.headers,
            errorBuilder: (context, error, stack) =>
                ColoredBox(color: scheme.surfaceContainerHigh),
          )
        else
          ColoredBox(color: scheme.surfaceContainerHigh),
        // Fades into the page rather than into black: the artwork then sits on
        // the same surface as the text under it, in light and dark themes.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[Colors.transparent, scheme.surface],
              stops: const <double>[0.45, 1],
            ),
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _LibraryButton extends ConsumerWidget {
  const _LibraryButton({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved =
        ref.watch(libraryProvider).any((entry) => entry.id == item.id);
    return FloatingActionButton.extended(
      onPressed: () => ref.read(libraryProvider.notifier).toggle(item),
      icon: Icon(saved ? Icons.bookmark : Icons.bookmark_add_outlined),
      label: Text(saved ? 'Saved' : 'Save'),
    );
  }
}

class _DetailsSkeleton extends StatelessWidget {
  const _DetailsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        SkeletonBox(height: 280, radius: 18),
        SizedBox(height: 20),
        SkeletonBox(height: 24, width: 220),
        SizedBox(height: 12),
        SkeletonBox(height: 16, width: 320),
        SizedBox(height: 24),
        SkeletonBox(height: 44, width: 160),
      ],
    );
  }
}

class _DetailsError extends StatelessWidget {
  const _DetailsError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(leading: const BackButton()),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 16),
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Kept for the details screen's policy banner in phase 10.
extension PlaybackPolicyLabel on PlaybackPolicy {
  String? get warning => switch (this) {
        PlaybackPolicy.none => null,
        PlaybackPolicy.vpnRecommended => 'This source recommends a VPN.',
        PlaybackPolicy.torrent => 'This source streams over BitTorrent.',
        PlaybackPolicy.externalPlayerOnly =>
          'This source must be opened in an external player.',
        PlaybackPolicy.internalPlayerOnly => null,
      };
}
