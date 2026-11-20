import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/services/catalog_service.dart';
import '../common/media_card.dart';
import '../common/ui_kit.dart';
import '../home/home_providers.dart';

/// Search across every enabled plugin, debounced and grouped by plugin.
///
/// The field lives in the body rather than the app bar: it is the whole screen,
/// and it stays put while results scroll under it.
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
    // Rebuild at once so the clear affordance tracks the field, then debounce
    // the search itself.
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  void _clear() {
    _controller.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final results =
        _query.isEmpty ? null : ref.watch(searchResultsProvider(_query));
    final installed =
        ref.watch(installedPluginsProvider).valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              onPressed: _clear,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: (value) => setState(() => _query = value.trim()),
              decoration: InputDecoration(
                hintText: 'Search films, series, anime…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: _clear,
                      ),
              ),
            ),
          ),
          Expanded(child: _body(results, installed.length)),
        ],
      ),
    );
  }

  Widget _body(AsyncValue<List<SearchGroup>>? results, int pluginCount) {
    if (_query.isEmpty) {
      if (pluginCount == 0) {
        return EmptyState(
          icon: Icons.extension_outlined,
          title: 'Nothing to search yet',
          body: 'Search asks the plugins you installed. Add a repository and '
              'install an extension first.',
          action: FilledButton.icon(
            onPressed: () => context.go('/extensions'),
            icon: const Icon(Icons.add_link),
            label: const Text('Open Extensions'),
          ),
        );
      }
      return EmptyState(
        icon: Icons.travel_explore,
        title: 'Search your extensions',
        body: 'AeroStream asks all $pluginCount installed '
            'plugin${pluginCount == 1 ? '' : 's'} in parallel and groups the '
            'answers, so you can see which source found what.',
      );
    }
    if (results == null) return const SizedBox.shrink();

    return results.when(
      loading: () => const _SearchSkeleton(),
      error: (error, stack) => EmptyState(
        icon: Icons.error_outline,
        title: 'Search failed',
        body: '$error',
      ),
      data: (groups) {
        if (groups.isEmpty) {
          return EmptyState(
            icon: Icons.search_off,
            title: 'No results for “$_query”',
            body: 'No installed plugin found anything. Try a different '
                'spelling, or install another extension.',
          );
        }
        final total =
            groups.fold<int>(0, (sum, group) => sum + group.items.length);
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 32),
          itemCount: groups.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  '$total result${total == 1 ? '' : 's'} from '
                  '${groups.length} plugin${groups.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              );
            }
            return _Group(group: groups[index - 1]);
          },
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
              Flexible(
                child: Text(
                  group.plugin.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 8),
              EcosystemBadge(ecosystem: group.plugin.ecosystem),
              const Spacer(),
              if (group.error == null)
                CountPill(
                  label: '${group.items.length}',
                  icon: Icons.grid_view_outlined,
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
