import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/media_item.dart';
import '../common/media_card.dart';
import 'history_providers.dart';
import 'library_providers.dart';

/// Saved titles and watch history.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(libraryProvider);
    final history = ref.watch(historyProvider);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Library'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Saved'),
              Tab(text: 'History'),
            ],
          ),
          actions: [
            if (saved.isNotEmpty)
              IconButton(
                tooltip: 'Clear saved titles',
                onPressed: () => _confirmClearLibrary(context, ref),
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
            if (history.isNotEmpty)
              IconButton(
                tooltip: 'Clear history',
                onPressed: () => _confirmClearHistory(context, ref),
                icon: const Icon(Icons.history_toggle_off),
              ),
          ],
        ),
        body: TabBarView(
          children: [
            _SavedTab(items: saved),
            _HistoryTab(entries: history),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmClearHistory(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear watch history?'),
        content: const Text(
          'Resume points are forgotten. Saved titles and extensions are not '
          'affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(historyProvider.notifier).clear();
    }
  }

  Future<void> _confirmClearLibrary(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear the library?'),
        content: const Text(
          'Saved titles are removed from this device. Your extensions and '
          'history are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(libraryProvider.notifier).clear();
    }
  }
}

class _SavedTab extends StatelessWidget {
  const _SavedTab({required this.items});

  final List<MediaItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _EmptyLibrary();
    return LayoutBuilder(
              builder: (context, constraints) {
                final columns =
                    (constraints.maxWidth / 150).floor().clamp(2, 8);
                return GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.52,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return MediaPosterCard(
                      item: item,
                      width: double.infinity,
                      onTap: () => context.push('/details', extra: item),
                    );
                  },
                );
              },
            ),
    );
  }
}

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab({required this.entries});

  final List<WatchHistoryEntry> entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (entries.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.history,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text('No history yet', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  'Anything you start watching shows up here, so you can pick '
                  'it up where you stopped.',
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

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: entries.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return InkWell(
          onTap: () => context.push(
            '/watch',
            extra: (item: entry.item, episode: entry.episode),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 56,
                  height: 84,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: MediaPoster(item: entry.item),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _subtitleFor(entry),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: entry.progress,
                          minHeight: 3,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Remove from history',
                  onPressed: () =>
                      ref.read(historyProvider.notifier).remove(entry),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// "S1E4 · 34 min left", or just the time left for a film.
  static String _subtitleFor(WatchHistoryEntry entry) {
    final remaining = entry.duration - entry.position;
    final minutes = (remaining.inSeconds / 60).ceil().clamp(0, 1 << 20);
    final episode = entry.episode;
    final label = episode == null
        ? ''
        : 'S${episode.seasonNumber}E${episode.number} · ';
    if (entry.isFinished) return '${label}Finished';
    if (minutes <= 0) return '${label}Watched';
    return '$label$minutes min left';
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bookmark_border,
                size: 48,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text('Nothing saved yet', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                'Tap Save on a title to keep it here. Saved entries stay even '
                'if you remove the extension that provided them.',
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
