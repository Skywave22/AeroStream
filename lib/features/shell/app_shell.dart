import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// The adaptive navigation frame.
///
/// One codebase, three layouts: a bottom bar on phones, a rail on tablets and a
/// rail with labels on desktop. TV remotes drive it with the D-pad because
/// every destination is a focusable button.
class AppShell extends ConsumerWidget {
  const AppShell({required this.child, super.key});

  final Widget child;

  static const List<_Destination> _destinations = <_Destination>[
    _Destination('/', 'Home', Icons.home_outlined, Icons.home),
    _Destination('/search', 'Search', Icons.search, Icons.search),
    _Destination('/library', 'Library', Icons.bookmark_border, Icons.bookmark),
    _Destination(
      '/extensions',
      'Extensions',
      Icons.extension_outlined,
      Icons.extension,
    ),
    _Destination(
      '/settings',
      'Settings',
      Icons.settings_outlined,
      Icons.settings,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.path;
    final index = _indexFor(location);
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= 720;

    void navigate(int index) {
      final destination = _destinations[index];
      context.go(destination.path);
    }

    if (useRail) {
      final extended = width >= 1200;
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: navigate,
              extended: extended,
              labelType: extended
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: _Brand(compact: true),
              ),
              destinations: [
                for (final destination in _destinations)
                  NavigationRailDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: Text(destination.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      );
    }

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: navigate,
        destinations: [
          for (final destination in _destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ],
      ),
    );
  }

  static int _indexFor(String location) {
    if (location == '/' || location.isEmpty) return 0;
    for (var i = 1; i < _destinations.length; i++) {
      if (location.startsWith(_destinations[i].path)) return i;
    }
    return 0;
  }
}

class _Destination {
  const _Destination(this.path, this.label, this.icon, this.selectedIcon);

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _Brand extends StatelessWidget {
  const _Brand({this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.play_circle_fill_rounded, color: theme.colorScheme.primary),
        if (!compact) ...[
          const SizedBox(width: 8),
          Text(
            'AeroStream',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }
}
