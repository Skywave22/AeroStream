import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../features/home/home_screen.dart';

/// App-level route table.
///
/// Screens are added here as they land; shell routes keep navigation state
/// across tabs on every form factor.
final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: <RouteBase>[
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) => HomeScreen(
        onBrowseExtensions: () => context.go('/extensions'),
      ),
    ),
  ],
);
