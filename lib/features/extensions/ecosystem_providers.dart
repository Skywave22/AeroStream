import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/errors/plugin_error.dart';
import '../../core/result.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/installed_plugin.dart';
import '../../domain/entities/plugin_info.dart';
import '../../domain/entities/plugin_repository.dart';

/// Everything one ecosystem's repositories offer, plus what could not be read.
///
/// Partial failure is the normal case — one dead mirror must not empty the
/// page — so errors are collected per repository instead of replacing the list.
@immutable
final class EcosystemCatalog {
  const EcosystemCatalog({
    this.listings = const <AvailablePlugin>[],
    this.failures = const <String, PluginError>{},
  });

  /// Every plugin offered by this ecosystem's repositories, one entry per id.
  final List<AvailablePlugin> listings;

  /// Repository id → why it could not be read.
  final Map<String, PluginError> failures;

  bool get isEmpty => listings.isEmpty;

  bool get isComplete => failures.isEmpty;

  /// The listing for [installed], when its repository still offers it.
  AvailablePlugin? listingFor(String id) {
    for (final listing in listings) {
      if (listing.id == id) return listing;
    }
    return null;
  }
}

/// The repositories of one ecosystem, newest first.
final ecosystemRepositoriesProvider =
    Provider.family<List<PluginRepository>, PluginEcosystem>((ref, ecosystem) {
  final repositories = ref.watch(repositoriesProvider).valueOrNull;
  if (repositories == null) return const <PluginRepository>[];
  return repositories
      .where((repository) => repository.ecosystem == ecosystem)
      .toList(growable: false);
});

/// The plugins installed from one ecosystem.
final ecosystemInstalledProvider =
    Provider.family<List<InstalledPlugin>, PluginEcosystem>((ref, ecosystem) {
  final installed = ref.watch(installedPluginsProvider).valueOrNull;
  if (installed == null) return const <InstalledPlugin>[];
  return installed
      .where((plugin) => plugin.info.ecosystem == ecosystem)
      .toList(growable: false);
});

/// Browses every repository of [ecosystem] and merges the results.
///
/// Keyed by ecosystem rather than by repository: the sections are where a user
/// looks for "what can I install from CloudStream", and one request per
/// repository is what that question costs.
final ecosystemCatalogProvider = FutureProvider.autoDispose
    .family<EcosystemCatalog, PluginEcosystem>((ref, ecosystem) async {
  final repositories = await ref.watch(repositoriesProvider.future);
  final mine = repositories
      .where((repository) => repository.ecosystem == ecosystem)
      .toList(growable: false);
  if (mine.isEmpty) return const EcosystemCatalog();

  final service = ref.watch(repositoryServiceProvider);
  final results = await Future.wait(
    mine.map(
      (repository) async =>
          (repository: repository, result: await service.browse(repository)),
    ),
  );

  final failures = <String, PluginError>{};
  final byId = <String, AvailablePlugin>{};
  for (final entry in results) {
    switch (entry.result) {
      case Ok<List<AvailablePlugin>>(:final value):
        for (final plugin in value) {
          final existing = byId[plugin.id];
          // Two mirrors of the same plugin: keep the newer one.
          if (existing == null || plugin.version > existing.version) {
            byId[plugin.id] = plugin;
          }
        }
      case Err<List<AvailablePlugin>>(:final error):
        failures[entry.repository.id] = error;
    }
  }

  final listings = byId.values.toList()
    ..sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

  return EcosystemCatalog(
    listings: List<AvailablePlugin>.unmodifiable(listings),
    failures: Map<String, PluginError>.unmodifiable(failures),
  );
});
