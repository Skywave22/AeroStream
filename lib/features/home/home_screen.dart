import 'package:flutter/material.dart';

/// The screen shown when the app has no extensions at all.
///
/// AeroStream ships no content, so this is the true first-run experience: it
/// explains the model and points at the one action that changes it.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, this.onBrowseExtensions});

  final VoidCallback? onBrowseExtensions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('AeroStream'),
        actions: [
          IconButton(
            tooltip: 'Search',
            onPressed: () {},
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                  'AeroStream has no built-in catalogue. Add a repository and '
                  'install an extension — SkyStream, Vega or CloudStream — and '
                  'its home rows, search and streams appear here.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 28),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: onBrowseExtensions,
                      icon: const Icon(Icons.add_link_rounded),
                      label: const Text('Add a repository'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
