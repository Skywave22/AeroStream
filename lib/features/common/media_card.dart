import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../../domain/entities/media_item.dart';

/// A poster tile for a grid or a row.
///
/// Artwork is remote and plugin-supplied, so every image has a placeholder and
/// a failure state: a broken URL must never leave a grey hole or an exception.
class MediaPosterCard extends StatelessWidget {
  const MediaPosterCard({
    required this.item,
    this.onTap,
    this.width = 136,
    this.progress,
    super.key,
  });

  final MediaItem item;
  final VoidCallback? onTap;
  final double width;

  /// 0..1 watched fraction; draws a bar along the bottom of the poster.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const radius = BorderRadius.all(Radius.circular(AppTheme.posterRadius));
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: ClipRRect(
                borderRadius: radius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MediaPoster(item: item),
                    // A scrim under the progress bar: a bright poster must not
                    // swallow the only cue that a title was started.
                    if (progress != null)
                      const Align(
                        alignment: Alignment.bottomCenter,
                        child: SizedBox(
                          height: 44,
                          width: double.infinity,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: <Color>[
                                  Colors.transparent,
                                  Color(0x99000000),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (progress != null)
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: LinearProgressIndicator(
                            value: progress!.clamp(0.0, 1.0),
                            minHeight: 4,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            if (item.year != null || item.rating != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  <String>[
                    if (item.year != null) '${item.year}',
                    if (item.rating != null) item.rating!.toStringAsFixed(1),
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Just the artwork, with the placeholder and header handling every screen
/// needs; sized by its parent.
class MediaPoster extends StatelessWidget {
  const MediaPoster({required this.item, super.key});

  final MediaItem item;

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

    final url = item.posterUrl;
    if (url == null || url.isEmpty) return placeholder;

    return Image.network(
      url,
      fit: BoxFit.cover,
      headers: item.headers.isEmpty ? null : item.headers,
      errorBuilder: (context, error, stack) => placeholder,
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : placeholder,
    );
  }
}

/// A wide card for the hero carousel.
class MediaHeroCard extends StatelessWidget {
  const MediaHeroCard({required this.item, this.onTap, super.key});

  final MediaItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = item.backdropUrl?.isNotEmpty ?? false
        ? item.backdropUrl
        : item.posterUrl;

    const radius = BorderRadius.all(Radius.circular(AppTheme.radiusMedium));
    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      child: ClipRRect(
        borderRadius: radius,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url != null && url.isNotEmpty)
                Image.network(
                  url,
                  fit: BoxFit.cover,
                  headers: item.headers.isEmpty ? null : item.headers,
                  errorBuilder: (context, error, stack) =>
                      ColoredBox(color: theme.colorScheme.surfaceContainerHigh),
                )
              else
                ColoredBox(color: theme.colorScheme.surfaceContainerHigh),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Colors.transparent, Color(0xCC000000)],
                    stops: <double>[0.45, 1],
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        shadows: const <Shadow>[
                          Shadow(blurRadius: 12, color: Colors.black54),
                        ],
                      ),
                    ),
                    if (item.description != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          item.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
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
}

/// A section header with an optional "see all" affordance.
class SectionHeader extends StatelessWidget {
  const SectionHeader({required this.title, this.onSeeAll, super.key});

  final String title;
  final VoidCallback? onSeeAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (onSeeAll != null)
            TextButton(onPressed: onSeeAll, child: const Text('See all')),
        ],
      ),
    );
  }
}

/// Shown when a plugin fails but the screen still has content.
class PluginErrorBanner extends StatelessWidget {
  const PluginErrorBanner({
    required this.message,
    this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// A skeleton block used while a feed loads.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    this.height = 200,
    this.width = double.infinity,
    this.radius = 12,
    super.key,
  });

  final double height;
  final double width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
