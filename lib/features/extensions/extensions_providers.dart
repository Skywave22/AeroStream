import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/errors/plugin_error.dart';
import '../../core/platform/platform_profile.dart';
import '../../core/result.dart';
import '../../domain/entities/installed_plugin.dart';
import '../../domain/entities/plugin_repository.dart';

/// Plugins a repository offers.
final repositoryPluginsProvider = FutureProvider.autoDispose
    .family<List<AvailablePlugin>, String>((ref, repositoryId) async {
  final repositories = await ref.watch(repositoriesProvider.future);
  final repository = repositories
      .where((candidate) => candidate.id == repositoryId)
      .firstOrNull;
  if (repository == null) return const <AvailablePlugin>[];
  final result = await ref.watch(repositoryServiceProvider).browse(repository);
  return switch (result) {
    Ok<List<AvailablePlugin>>(:final value) => value,
    Err<List<AvailablePlugin>>(:final error) => throw error,
  };
});

/// Ids of plugins currently being installed or updated, for progress UI.
final busyPluginsProvider = StateProvider<Set<String>>((ref) => <String>{});

/// Actions the Extensions screen performs.
///
/// Kept out of the widgets so the same flows are usable from a deep link or a
/// background update check.
final class ExtensionActions {
  const ExtensionActions(this._ref);

  final WidgetRef _ref;

  PlatformProfile get platform => _ref.read(platformProfileProvider);

  Future<Result<PluginRepository>> addRepository(String url) async {
    final result =
        await _ref.read(repositoryServiceProvider).addRepository(url);
    _ref.invalidate(repositoriesProvider);
    return result;
  }

  Future<void> removeRepository(PluginRepository repository) async {
    await _ref.read(repositoryServiceProvider).remove(repository);
    _ref.invalidate(repositoriesProvider);
    _ref.invalidate(repositoryPluginsProvider);
  }

  Future<void> refreshRepository(PluginRepository repository) async {
    await _ref.read(repositoryServiceProvider).refresh(repository);
    _ref.invalidate(repositoriesProvider);
    _ref.invalidate(repositoryPluginsProvider);
  }

  Future<Result<InstalledPlugin>> install(AvailablePlugin plugin) async {
    _markBusy(plugin.id, true);
    try {
      final result = await _ref.read(extensionManagerProvider).install(plugin);
      _refreshInstalled();
      return result;
    } finally {
      _markBusy(plugin.id, false);
    }
  }

  Future<Result<InstalledPlugin>> update(
    InstalledPlugin installed,
    AvailablePlugin upgrade,
  ) async {
    _markBusy(installed.info.id, true);
    try {
      final result =
          await _ref.read(extensionManagerProvider).update(installed, upgrade);
      _refreshInstalled();
      return result;
    } finally {
      _markBusy(installed.info.id, false);
    }
  }

  Future<void> uninstall(InstalledPlugin plugin) async {
    _markBusy(plugin.info.id, true);
    try {
      await _ref.read(extensionManagerProvider).uninstall(plugin);
      _refreshInstalled();
    } finally {
      _markBusy(plugin.info.id, false);
    }
  }

  Future<void> setEnabled(InstalledPlugin plugin,
      {required bool enabled}) async {
    await _ref
        .read(extensionManagerProvider)
        .setEnabled(plugin, enabled: enabled);
    _refreshInstalled();
  }

  /// Newer listings for what is installed, across every repository.
  Future<List<({InstalledPlugin installed, AvailablePlugin upgrade})>>
      findUpdates() async {
    final repositories = await _ref.read(repositoriesProvider.future);
    final service = _ref.read(repositoryServiceProvider);
    final listings = <AvailablePlugin>[];
    for (final repository in repositories) {
      final result = await service.browse(repository);
      if (result is Ok<List<AvailablePlugin>>) {
        listings.addAll(result.value);
      }
    }
    return _ref.read(extensionManagerProvider).findUpdates(listings);
  }

  void _markBusy(String id, bool busy) {
    final current = _ref.read(busyPluginsProvider);
    _ref.read(busyPluginsProvider.notifier).state =
        busy ? <String>{...current, id} : (current.toSet()..remove(id));
  }

  void _refreshInstalled() {
    _ref.invalidate(installedPluginsProvider);
    _ref.invalidate(mediaProvidersProvider);
  }

  /// Human-readable reason an ecosystem cannot run here, if any.
  String? unsupportedReason(AvailablePlugin plugin) =>
      platform.unsupportedReason(plugin.ecosystem);

  /// Whether an installed plugin can run on this platform.
  bool runsHere(InstalledPlugin plugin) =>
      platform.supports(plugin.info.ecosystem);

  /// Distinguishes "installed at this version" from "update available".
  AvailablePlugin? upgradeFor(
    InstalledPlugin installed,
    List<AvailablePlugin> listings,
  ) {
    for (final listing in listings) {
      if (listing.ecosystem != installed.info.ecosystem) continue;
      if (listing.id != installed.info.id) continue;
      if (listing.version > installed.info.version) return listing;
    }
    return null;
  }

  PluginError? describeFailure(Result<Object?> result) => result.errorOrNull;
}
