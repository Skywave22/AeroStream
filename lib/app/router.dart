import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../domain/entities/download.dart';
import '../domain/entities/media_item.dart';
import '../features/details/details_providers.dart';
import '../features/details/details_screen.dart';
import '../features/downloads/downloads_view.dart';
import '../features/extensions/ecosystem_info.dart';
import '../features/extensions/ecosystem_screen.dart';
import '../features/extensions/extensions_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/player/watch_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/shell/app_shell.dart';

/// App-level route table.
///
/// The five tabs live inside a [ShellRoute] so navigation state and scroll
/// position survive tab switches on every form factor. Detail and player
/// screens are pushed above the shell: they are destinations, not tabs.
final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: <RouteBase>[
    ShellRoute(
      builder: (context, state, child) => AppShell(child: child),
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => const HomeScreen(),
        ),
        GoRoute(
          path: '/search',
          name: 'search',
          builder: (context, state) => const SearchScreen(),
        ),
        GoRoute(
          path: '/library',
          name: 'library',
          builder: (context, state) => const LibraryScreen(),
        ),
        GoRoute(
          path: '/extensions',
          name: 'extensions',
          builder: (context, state) => const ExtensionsScreen(),
          routes: <RouteBase>[
            // One page per ecosystem, named the way that ecosystem names it.
            GoRoute(
              path: ':ecosystem',
              name: 'ecosystem',
              builder: (context, state) {
                final info = EcosystemInfo.fromWire(
                  state.pathParameters['ecosystem'],
                );
                if (info == null) return const _MissingRouteData();
                return EcosystemScreen(info: info);
              },
            ),
          ],
        ),
        GoRoute(
          path: '/settings',
          name: 'settings',
          builder: (context, state) => const SettingsScreen(),
        ),
      ],
    ),
    GoRoute(
      path: '/downloads/play',
      name: 'download-play',
      builder: (context, state) {
        final task = state.extra;
        if (task is! DownloadTask) return const _MissingRouteData();
        return DownloadedPlayerScreen(task: task);
      },
    ),
    GoRoute(
      path: '/details',
      name: 'details',
      builder: (context, state) {
        final item = state.extra;
        if (item is! MediaItem) return const _MissingRouteData();
        return DetailsScreen(item: item);
      },
    ),
    GoRoute(
      path: '/watch',
      name: 'watch',
      builder: (context, state) {
        final extra = state.extra;
        if (extra is! StreamRequest) return const _MissingRouteData();
        return WatchScreen(request: extra);
      },
    ),
  ],
);

/// Shown when a route that needs an argument is opened without one (a deep
/// link, or a hot reload that dropped `extra`).
class _MissingRouteData extends StatelessWidget {
  const _MissingRouteData();

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
              const Icon(Icons.link_off, size: 40),
              const SizedBox(height: 16),
              const Text(
                'This link cannot be opened directly',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                'Open the title from Home or Search so AeroStream knows which '
                'extension to ask.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => context.go('/'),
                child: const Text('Go home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
