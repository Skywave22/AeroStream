import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/services/catalog_service.dart';
import '../common/media_card.dart';
import '../home/home_providers.dart';

/// Search across every enabled plugin, debounced and grouped by plugin.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final results =
        _query.isEmpty ? null : ref.watch(searchResultsProvider(_query));

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (value) => setState(() => _query = value.trim()),
          decoration: InputDecoration(
            hintText: 'Search films, series, anime…',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _controller.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
        ),
      ),
      body: _body(context, results),
    );
  }

  Widget _body(BuildContext context, AsyncValue<List<SearchGroup>>? results) {
    if (_query.isEmpty) {
      return const _Hint(
        icon: Icons.travel_explore,
        title: 'Search your extensions',
        body: 'AeroStream asks every installed plugin in parallel and groups '
            'the answers, so you can see which source found what.',
      );
    }
    if (results == null) return const SizedBox.shrink();

    return results.when(
      loading: () => const _SearchSkeleton(),
      error: (error, stack) => Center(child: Text('Search failed: $error')),
      data: (groups) {
        if (groups.isEmpty) {
          return _Hint(
            icon: Icons.search_off,
            title: 'No results for "$_query"',
            body: 'No installed plugin found anything. Try a different '
                'spelling, or install another extension.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 32),
          itemCount: groups.length,
          itemBuilder: (context, index) => _Group(group: groups[index]),
        );
      },
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.group});

  final SearchGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Row(
            children: [
              Text(
                group.plugin.name,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  group.plugin.ecosystem.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              const Spacer(),
              if (group.error == null)
                Text(
                  '${group.items.length}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
        if (group.error != null)
          PluginErrorBanner(
            message: group.error!.userMessage,
            onRetry: null,
          )
        else
          SizedBox(
            height: 252,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: group.items.length,
              separatorBuilder: (context, index) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = group.items[index];
                return MediaPosterCard(
                  item: item,
                  onTap: () => context.push('/details', extra: item),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                body,
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

class _SearchSkeleton extends StatelessWidget {
  const _SearchSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        SkeletonBox(height: 20, width: 140),
        SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: Row(
            children: [
              SkeletonBox(height: 200, width: 130),
              SizedBox(width: 12),
              SkeletonBox(height: 200, width: 130),
              SizedBox(width: 12),
              SkeletonBox(height: 200, width: 130),
            ],
          ),
        ),
      ],
    );
  }
}
