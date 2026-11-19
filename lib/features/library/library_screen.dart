import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../common/media_card.dart';
import 'library_providers.dart';

/// Saved titles.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(libraryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              tooltip: 'Clear library',
              onPressed: () => _confirmClear(context, ref),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: items.isEmpty
          ? const _EmptyLibrary()
          : LayoutBuilder(
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

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
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
