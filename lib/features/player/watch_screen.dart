import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/download.dart';
import '../../domain/entities/stream_source.dart';
import '../details/details_providers.dart';
import '../downloads/download_providers.dart';
import '../library/history_providers.dart';
import '../settings/settings_providers.dart';
import 'playback_engine.dart';

/// Source selection and playback.
///
/// The source list comes first, because with user-supplied extensions one title
/// often has several links of different qualities and container types — showing
/// the choice is more honest than silently picking one.
class WatchScreen extends ConsumerStatefulWidget {
  const WatchScreen({required this.request, this.resolved, super.key});

  final StreamRequest request;

  /// Links that are already known — a file on disk, for instance. When set the
  /// screen plays them and never asks a plugin for anything.
  final StreamResult? resolved;

  @override
  ConsumerState<WatchScreen> createState() => _WatchScreenState();
}

class _WatchScreenState extends ConsumerState<WatchScreen> {
  StreamSource? _selected;
  bool _showSources = true;

  @override
  Widget build(BuildContext context) {
    final resolved = widget.resolved;
    final streams = resolved == null
        ? ref.watch(streamsProvider(widget.request))
        : AsyncValue<StreamResult>.data(resolved);
    final engine = ref.watch(playerEngineProvider);
    // The user's quality choice is applied here, once, so the surface and the
    // picker below it agree on which link is first.
    final preferences = ref.watch(preferencesProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.request.episode == null
              ? widget.request.item.title
              : '${widget.request.item.title} · '
                  'S${widget.request.episode!.seasonNumber}'
                  'E${widget.request.episode!.number}',
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(
            tooltip: 'Sources',
            onPressed: () => setState(() => _showSources = !_showSources),
            icon: Icon(_showSources ? Icons.dns : Icons.dns_outlined),
          ),
          if (resolved == null)
            IconButton(
              tooltip: 'Reload links',
              onPressed: () => ref.invalidate(streamsProvider(widget.request)),
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: streams.when(
        loading: () => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'Resolving links…',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
        error: (error, stack) => _StreamError(
          message: '$error',
          onRetry: () => ref.invalidate(streamsProvider(widget.request)),
        ),
        data: (result) {
          final request = widget.request;
          final history = ref.read(historyProvider.notifier);
          return _Body(
            result: result,
            sources: result.preferredSources(
              preferredQuality: preferences.preferredQuality,
              preferHls: preferences.preferHls,
            ),
            selected: _selected,
            showSources: _showSources,
            onSelect: (source) => setState(() => _selected = source),
            engine: engine,
            request: widget.request,
            canDownload: resolved == null,
            // Resume where the user left off, and keep the record current
            // while they watch.
            startAt: history.resumePosition(
              request.item,
              episode: request.episode,
            ),
            onProgress: (position, duration) => unawaited(
              history.record(
                item: request.item,
                episode: request.episode,
                position: position,
                duration: duration,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.result,
    required this.sources,
    required this.selected,
    required this.showSources,
    required this.onSelect,
    required this.engine,
    required this.startAt,
    required this.onProgress,
    required this.request,
    required this.canDownload,
  });

  final StreamResult result;
  final List<StreamSource> sources;
  final StreamSource? selected;
  final bool showSources;
  final ValueChanged<StreamSource> onSelect;
  final PlaybackEngine? engine;
  final Duration? startAt;
  final ProgressCallback onProgress;
  final StreamRequest request;
  final bool canDownload;

  @override
  Widget build(BuildContext context) {
    final source = selected ?? (sources.isEmpty ? null : sources.first);
    final engineSurface = source == null || !(engine?.supports(source) ?? false)
        ? null
        : engine!.buildSurface(
            context,
            source,
            subtitles: result.subtitles,
            startAt: startAt,
            onProgress: onProgress,
          );

    return Column(
      children: [
        Expanded(
          child: Center(
            child:
                engineSurface ?? _EngineMissing(source: source, result: result),
          ),
        ),
        if (showSources)
          SizedBox(
            height: 240,
            child: _SourceList(
              sources: sources,
              subtitles: result.subtitles,
              selected: source,
              onSelect: onSelect,
              request: request,
              canDownload: canDownload,
            ),
          ),
      ],
    );
  }
}

extension on _SourceList {
  /// Queues [source], and says what happened either way.
  Future<void> _download(
    BuildContext context,
    WidgetRef ref,
    StreamSource source,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(downloadsProvider.notifier)
          .enqueue(
            item: request.item,
            episode: request.episode,
            source: source,
          );
      messenger.showSnackBar(
        SnackBar(
          content: Text('Saving ${source.label} — see Library › Downloads'),
        ),
      );
    } on DownloadRejected catch (rejection) {
      messenger.showSnackBar(SnackBar(content: Text(rejection.message)));
    }
  }
}

class _EngineMissing extends StatelessWidget {
  const _EngineMissing({required this.source, required this.result});

  final StreamSource? source;
  final StreamResult result;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.movie_filter_outlined,
              size: 44, color: Colors.white38),
          const SizedBox(height: 16),
          Text(
            source == null ? 'No playable links' : 'No player in this build',
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            source == null
                ? 'The extension returned no sources for this title.'
                : 'The links resolved, but this build has no video engine '
                    'attached. Copy the link into a player that supports '
                    '${source!.isHls ? 'HLS' : source!.isDash ? 'DASH' : 'this format'}.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, height: 1.4),
          ),
          if (source != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: source!.url));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Link copied')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy link'),
            ),
          ],
          if (result.sources.length > 1) ...[
            const SizedBox(height: 12),
            Text(
              '${result.sources.length} sources available',
              style: const TextStyle(color: Colors.white38),
            ),
          ],
        ],
      ),
    );
  }
}

class _SourceList extends ConsumerWidget {
  const _SourceList({
    required this.sources,
    required this.subtitles,
    required this.selected,
    required this.onSelect,
    required this.request,
    required this.canDownload,
  });

  final List<StreamSource> sources;
  final List<SubtitleTrack> subtitles;
  final StreamSource? selected;
  final ValueChanged<StreamSource> onSelect;
  final StreamRequest request;

  /// False when these links already *are* local files.
  final bool canDownload;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: subtitles.isEmpty ? 1 : 2,
      child: Column(
        children: [
          TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            indicatorColor: Theme.of(context).colorScheme.primary,
            tabs: [
              Tab(text: 'Sources (${sources.length})'),
              if (subtitles.isNotEmpty)
                Tab(text: 'Subtitles (${subtitles.length})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView.builder(
                  itemCount: sources.length,
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    final isSelected = source == selected;
                    return ListTile(
                      selected: isSelected,
                      selectedTileColor: Colors.white10,
                      leading: Icon(
                        source.isHls
                            ? Icons.stream
                            : source.isDash
                                ? Icons.dynamic_feed
                                : Icons.movie,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white54,
                      ),
                      title: Text(
                        source.label,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        <String>[
                          if (source.quality != null) source.quality!,
                          if (source.isHls)
                            'HLS'
                          else if (source.isDash)
                            'DASH',
                          if (source.extractorName != null)
                            source.extractorName!,
                          if (source.headers.isNotEmpty) 'needs headers',
                        ].join(' · '),
                        style: const TextStyle(color: Colors.white38),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isSelected)
                            const Icon(Icons.check, color: Colors.white),
                          if (canDownload)
                            IconButton(
                              tooltip: isDownloadableLink(
                                source.url,
                                isHls: source.isHls,
                                isDash: source.isDash,
                              )
                                  ? 'Download'
                                  : 'Playlists cannot be downloaded',
                              onPressed: () => _download(context, ref, source),
                              icon: Icon(
                                Icons.download_outlined,
                                color: isDownloadableLink(
                                  source.url,
                                  isHls: source.isHls,
                                  isDash: source.isDash,
                                )
                                    ? Colors.white70
                                    : Colors.white24,
                              ),
                            ),
                        ],
                      ),
                      onTap: () => onSelect(source),
                    );
                  },
                ),
                ListView.builder(
                  itemCount: subtitles.length,
                  itemBuilder: (context, index) {
                    final subtitle = subtitles[index];
                    return ListTile(
                      leading: const Icon(
                        Icons.subtitles_outlined,
                        color: Colors.white54,
                      ),
                      title: Text(
                        subtitle.displayName,
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        subtitle.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white38),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamError extends StatelessWidget {
  const _StreamError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link_off, size: 44, color: Colors.white38),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.pop(),
              child: const Text('Back to details'),
            ),
          ],
        ),
      ),
    );
  }
}
