import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/download.dart';
import '../../domain/entities/stream_source.dart';
import '../common/ui_kit.dart';
import '../player/watch_screen.dart';
import 'download_providers.dart';

/// The download queue, with the two states that matter: moving, and done.
class DownloadsView extends ConsumerWidget {
  const DownloadsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadsProvider);
    final theme = Theme.of(context);

    if (tasks.isEmpty) {
      return const EmptyState(
        icon: Icons.download_outlined,
        title: 'Nothing downloaded',
        body: 'Open a title, pick a source and tap the download icon. '
            'AeroStream saves progressive HTTP links; playlist formats '
            '(HLS, DASH) play directly instead.',
      );
    }

    final finished = tasks.where((task) => task.isPlayable);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tasks.length + (finished.isEmpty ? 0 : 1),
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == tasks.length) {
          return ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('Delete finished downloads'),
            subtitle: Text(
              '${finished.length} file'
              '${finished.length == 1 ? '' : 's'} on this device',
            ),
            onTap: () => _confirmDeleteFinished(context, ref),
          );
        }
        return _DownloadTile(task: tasks[index]);
      },
    );
  }

  Future<void> _confirmDeleteFinished(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete finished downloads?'),
        content: const Text(
          'The files are removed from this device. You can download them again '
          'from the title page.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await ref.read(downloadsProvider.notifier).removeFinished();
    }
  }
}

class _DownloadTile extends ConsumerWidget {
  const _DownloadTile({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(downloadsProvider.notifier);
    final progress = task.progress;

    return InkWell(
      onTap: task.isPlayable
          ? () => context.push('/downloads/play', extra: task)
          : null,
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
                child: _Thumbnail(task: task),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _statusLine(task),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: task.status == DownloadStatus.failed
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (task.isActive ||
                      task.status == DownloadStatus.paused) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ..._actions(context, ref, controller),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(
    BuildContext context,
    WidgetRef ref,
    DownloadsController controller,
  ) {
    switch (task.status) {
      case DownloadStatus.queued:
      case DownloadStatus.running:
        return [
          IconButton(
            tooltip: 'Cancel download',
            onPressed: () => controller.cancel(task.id),
            icon: const Icon(Icons.close),
          ),
        ];
      case DownloadStatus.paused:
        return [
          IconButton(
            tooltip: 'Resume download',
            onPressed: () => controller.startDownload(task.id),
            icon: const Icon(Icons.play_arrow),
          ),
          IconButton(
            tooltip: 'Remove download',
            onPressed: () => controller.remove(task.id),
            icon: const Icon(Icons.delete_outline),
          ),
        ];
      case DownloadStatus.failed:
        return [
          IconButton(
            tooltip: 'Try again',
            onPressed: () => controller.startDownload(task.id),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Remove download',
            onPressed: () => controller.remove(task.id),
            icon: const Icon(Icons.delete_outline),
          ),
        ];
      case DownloadStatus.complete:
        return [
          IconButton(
            tooltip: 'Play',
            onPressed: () => context.push('/downloads/play', extra: task),
            icon: const Icon(Icons.play_circle_outline),
          ),
          IconButton(
            tooltip: 'Delete file',
            onPressed: () => controller.remove(task.id),
            icon: const Icon(Icons.delete_outline),
          ),
        ];
    }
  }

  static String _statusLine(DownloadTask task) {
    final received = _megabytes(task.receivedBytes);
    final total = task.totalBytes == null ? null : _megabytes(task.totalBytes!);
    switch (task.status) {
      case DownloadStatus.queued:
        return 'Waiting…';
      case DownloadStatus.running:
        return total == null
            ? '$received MB downloaded'
            : '$received of $total MB';
      case DownloadStatus.paused:
        return 'Paused — tap play to restart from the beginning';
      case DownloadStatus.failed:
        return task.error ?? 'The download failed';
      case DownloadStatus.complete:
        return 'Saved · $received MB · ${task.fileName}';
    }
  }

  static String _megabytes(int bytes) =>
      (bytes / (1024 * 1024)).toStringAsFixed(bytes < 1024 * 1024 ? 1 : 0);
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      ),
    );
    final url = task.item.posterUrl;
    if (url == null || url.isEmpty) return placeholder;
    return Image.network(
      url,
      fit: BoxFit.cover,
      headers: task.item.headers.isEmpty ? null : task.item.headers,
      errorBuilder: (context, error, stack) => placeholder,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : placeholder,
    );
  }
}

/// Plays a file that is already on disk.
///
/// Deliberately not the normal watch flow: there is nothing to resolve here, so
/// the screen is handed the one source and never touches a plugin.
class DownloadedPlayerScreen extends ConsumerWidget {
  const DownloadedPlayerScreen({required this.task, super.key});

  final DownloadTask task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(downloadsProvider.notifier);
    final source = controller.playableSource(task);
    return WatchScreen(
      request: (item: task.item, episode: task.episode),
      resolved: StreamResult(sources: <StreamSource>[source]),
    );
  }
}
