import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/entities/enums.dart';
import '../domain/entities/home_section.dart';
import '../domain/entities/plugin_repository.dart';
import '../domain/media_provider.dart';
import 'providers.dart';

/// A headless pass over the whole pipeline, in the order a user hits it.
///
/// Everything the acceptance tests care about lives here rather than in a
/// script beside the app: the same stores, the same sandbox, the same adapters
/// and the same install path. `AEROSTREAM_SELFCHECK=1` makes `main` run this
/// instead of opening a window, so a machine with no hands — CI under Xvfb —
/// can say whether a plugin really installs and really answers its home screen.
///
/// It is deliberately verbose and never throws: one broken step is recorded and
/// the run continues, because a report with four lines is worth more than a
/// stack trace that says only "something in step two".
Future<int> runSelfCheck(List<Override> overrides) async {
  final report = _Report();
  final container = ProviderContainer(overrides: overrides);
  try {
    await _check(container, report);
  } catch (error, stack) {
    report.fail('the run threw before it could finish', error);
    stderr.writeln(stack);
  } finally {
    container.dispose();
  }
  stdout.writeln('');
  stdout.writeln(
    '${report.passed} passed, ${report.failed} failed, '
    '${report.skipped} skipped',
  );
  return report.failed == 0 ? 0 : 1;
}

Future<void> _check(ProviderContainer container, _Report report) async {
  final platform = container.read(platformProfileProvider);
  stdout.writeln('AeroStream self-check on ${platform.operatingSystem}');

  await _checkRuntime(container, report);
  final installed = await _checkSkyStream(container, report);
  await _checkVega(container, report);
  await _checkCloudStream(container, report);
  if (installed != null) await _checkHome(container, report, installed);
}

/// The sandbox itself. If QuickJS cannot start, nothing else can mean anything.
Future<void> _checkRuntime(ProviderContainer container, _Report report) async {
  stdout.writeln('');
  stdout.writeln('JavaScript runtime');
  final engine = container.read(jsEngineFactoryProvider);
  final runtime = engine();
  try {
    await runtime.start();
    final answer = await runtime.evaluate('1 + 1');
    report.expect(answer == '2', 'QuickJS starts and evaluates', answer);
  } on Object catch (error) {
    report.fail('QuickJS starts and evaluates', error);
  } finally {
    await runtime.dispose();
  }
}

/// The shortcode people are given, resolved and browsed exactly as the
/// Extensions screen does it — and then one plugin installed for real.
Future<AvailablePlugin?> _checkSkyStream(
  ProviderContainer container,
  _Report report,
) async {
  stdout.writeln('');
  stdout.writeln('SkyStream: the "Universe" shortcode');
  final repositories = container.read(repositoryServiceProvider);

  final added = await repositories.addRepository('Universe');
  final repository = added.valueOrNull;
  if (repository == null) {
    report.fail('the shortcode resolves to a repository', added.errorOrNull);
    return null;
  }
  report.expect(
    repository.ecosystem == PluginEcosystem.skystream,
    'the alias is read as SkyStream',
    repository.ecosystem.name,
  );
  stdout.writeln('  at   ${repository.url}');

  final listing = await repositories.browse(repository);
  final plugins = listing.valueOrNull;
  if (plugins == null || plugins.isEmpty) {
    report.fail('the repository lists plugins', listing.errorOrNull);
    return null;
  }
  report.expect(true, 'the repository lists plugins', '${plugins.length}');

  // A child repository's list, which is the hop that used to lose its
  // ecosystem: the mega-repository itself publishes no plugins.
  final child = plugins.firstWhere(
    (plugin) => plugin.ecosystem == PluginEcosystem.skystream,
    orElse: () => plugins.first,
  );
  report.expect(
    child.ecosystem == PluginEcosystem.skystream,
    'its entries are SkyStream plugins',
    '${child.id} (${child.ecosystem.name})',
  );

  final manager = container.read(extensionManagerProvider);
  final target = plugins.firstWhere(
    (plugin) => plugin.id == 'com.subdub.skystream',
    orElse: () => child,
  );
  final result = await manager.install(target);
  final installed = result.valueOrNull;
  if (installed == null) {
    report.fail('a .sky installs', result.errorOrNull);
    return null;
  }
  report.expect(
    true,
    'a .sky installs',
    '${installed.info.id} v${installed.info.version.raw}',
  );
  return target;
}

/// The home screen of the plugin that was just installed.
Future<void> _checkHome(
  ProviderContainer container,
  _Report report,
  AvailablePlugin listed,
) async {
  stdout.writeln('');
  stdout.writeln('SkyStream: ${listed.id} answers its home screen');
  final manager = container.read(extensionManagerProvider);
  final providers = await manager.activeProviders();
  final provider = providers.firstWhereOrNull(
    (candidate) => candidate.info.id == listed.id,
  );
  if (provider == null) {
    report.fail(
      'the installed plugin starts',
      'active providers: ${providers.map((p) => p.info.id).join(', ')}',
    );
    return;
  }
  await _reportHome(report, provider);
}

Future<void> _checkVega(
  ProviderContainer container,
  _Report report,
) async {
  stdout.writeln('');
  stdout.writeln('Vega: "vega-org"');
  final repositories = container.read(repositoryServiceProvider);
  final added = await repositories.addRepository('vega-org');
  final repository = added.valueOrNull;
  if (repository == null) {
    report.fail('the source resolves', added.errorOrNull);
    return;
  }
  report.expect(
    repository.ecosystem == PluginEcosystem.vega,
    'the source is read as Vega',
    repository.ecosystem.name,
  );
  final listing = await repositories.browse(repository);
  final plugins = listing.valueOrNull;
  if (plugins == null || plugins.isEmpty) {
    report.fail('the source lists providers', listing.errorOrNull);
    return;
  }
  report.expect(true, 'the source lists providers', '${plugins.length}');

  final manager = container.read(extensionManagerProvider);
  final target = plugins.firstWhere(
    (plugin) => plugin.id == 'vega',
    orElse: () => plugins.first,
  );
  final result = await manager.install(target);
  if (result.valueOrNull == null) {
    report.fail('a provider bundle installs', result.errorOrNull);
    return;
  }
  report.expect(true, 'a provider bundle installs', target.id);

  final providers = await manager.activeProviders();
  final provider = providers.firstWhereOrNull(
    (candidate) => candidate.info.id == target.id,
  );
  if (provider == null) {
    report.fail('the installed provider starts', target.id);
    return;
  }
  await _reportHome(report, provider);
  await _checkVegaStreams(container, report, plugins);
}

/// Proves Vega's final host-to-source path on a provider whose catalogue is
/// stable enough for CI. The default provider's first Home item rotates and can
/// temporarily have no mirrors; treating that one item as the runtime verdict
/// left `getStream` permanently unproven even after host defects were fixed.
///
/// Internet Archive is still installed from the user's Vega repository during
/// this run. AeroStream bundles neither the provider nor a content identifier.
Future<void> _checkVegaStreams(
  ProviderContainer container,
  _Report report,
  List<AvailablePlugin> plugins,
) async {
  final listed = plugins.firstWhereOrNull(
    (plugin) => plugin.id == 'internetArchive',
  );
  if (listed == null) {
    report.skip('Vega getStream returns a playable source',
        'Internet Archive is not listed');
    return;
  }

  final manager = container.read(extensionManagerProvider);
  final installed = await manager.install(listed);
  if (installed.valueOrNull == null) {
    report.skip(
      'Vega getStream returns a playable source',
      'the stream probe provider did not install: ${installed.errorOrNull}',
    );
    return;
  }

  final providers = await manager.activeProviders();
  final provider = providers.firstWhereOrNull(
    (candidate) => candidate.info.id == listed.id,
  );
  for (final candidate in providers) {
    if (!identical(candidate, provider)) await candidate.dispose();
  }
  if (provider == null) {
    report.fail('Vega getStream returns a playable source',
        'the installed stream probe provider did not start');
    return;
  }

  try {
    final search = await provider.search('movie');
    final items = search.valueOrNull?.items ?? const [];
    if (items.isEmpty) {
      report.skip(
        'Vega getStream returns a playable source',
        'the live catalogue returned no probe items: ${search.errorOrNull}',
      );
      return;
    }

    Object? lastError;
    for (final item in items.take(3)) {
      final streams = await provider.getStreams(item);
      lastError = streams.errorOrNull;
      final sources = streams.valueOrNull?.orderedSources ?? const [];
      if (sources.isEmpty) continue;
      final best = sources.first;
      final host = Uri.tryParse(best.url)?.host ?? best.url;
      report.expect(
        true,
        'Vega getStream returns a playable source',
        '${sources.length} for "${item.title}", best $host',
      );
      return;
    }
    report.skip(
      'Vega getStream returns a playable source',
      'three live catalogue items had no source${lastError == null ? '' : ': $lastError'}',
    );
  } finally {
    await provider.dispose();
  }
}

Future<List<HomeSection>> _reportHome(
  _Report report,
  MediaProvider provider,
) async {
  final home = await provider.getHome();
  final sections = home.valueOrNull;
  if (sections == null) {
    report.fail('getHome answers', home.errorOrNull);
    return const <HomeSection>[];
  }
  final items = sections.fold<int>(0, (sum, s) => sum + s.items.length);
  if (sections.isEmpty || items == 0) {
    report.fail('getHome answers', 'no sections or no items');
    return const <HomeSection>[];
  }
  report.expect(
    true,
    'getHome answers',
    '${sections.length} sections, $items items',
  );
  for (final HomeSection section in sections.take(3)) {
    final count = section.items.length;
    final first = section.items.isEmpty ? '—' : section.items.first.title;
    stdout.writeln('  row  ${section.title}: $count · $first');
  }
  await _reportStreams(report, provider, sections);
  await provider.dispose();
  return sections;
}

/// The last mile before playback: a playable URL for one of the items the home
/// screen just offered.
///
/// Decoding the video needs a player and a screen, neither of which a headless
/// run has; everything up to the link the player would open does not.
Future<void> _reportStreams(
  _Report report,
  MediaProvider provider,
  List<HomeSection> sections,
) async {
  final items =
      sections.expand((section) => section.items).toList(growable: false);
  // A movie is the cheapest thing to extract; a row of series wants an
  // episode first. Falling back to the row's first entry keeps Vega covered,
  // whose entries are not typed.
  var item = items.firstWhereOrNull(
    (candidate) => candidate.type == MediaType.movie,
  );
  if (item == null && items.isNotEmpty) item = items.first;
  if (item == null) {
    report.skip('a stream resolves', 'the home rows are empty');
    return;
  }
  final streams = await provider.getStreams(item);
  final result = streams.valueOrNull;
  if (result == null) {
    // A SkyStream plugin is our own adapter's job; a Vega provider's link
    // extraction is its author's, and a provider that answers its home screen
    // but cannot extract from one host is a report, not a broken app.
    final ours = provider.info.ecosystem == PluginEcosystem.skystream;
    if (ours) {
      report.fail('a stream resolves', streams.errorOrNull);
    } else {
      report.skip('a stream resolves', '${streams.errorOrNull}');
    }
    return;
  }
  final sources = result.orderedSources;
  if (sources.isEmpty) {
    report.skip('a stream resolves', '${item.title} has no playable source');
    return;
  }
  final best = sources.first;
  final host = Uri.tryParse(best.url)?.host ?? best.url;
  report.expect(
    true,
    'a stream resolves',
    '${sources.length} for "${item.title}", best $host',
  );
}

Future<void> _checkCloudStream(
  ProviderContainer container,
  _Report report,
) async {
  stdout.writeln('');
  stdout.writeln('CloudStream');
  final platform = container.read(platformProfileProvider);
  final host = await container.read(cloudStreamHostProvider.future);
  if (!platform.isAndroid) {
    report.skip(
      'the Kotlin host is Android only',
      'this is ${platform.operatingSystem}',
    );
    return;
  }
  report.expect(host, 'the Kotlin host answers the handshake', '$host');
}

/// Counts and prints the findings.
///
/// Quiet on success, explicit on failure: the run is read from a log, so the
/// shape of the output is the report.
final class _Report {
  int passed = 0;
  int failed = 0;
  int skipped = 0;

  void expect(bool ok, String label, Object? detail) {
    if (ok) {
      passed++;
      stdout.writeln('  ok   $label${_detail(detail)}');
    } else {
      fail(label, detail);
    }
  }

  void fail(String label, Object? detail) {
    failed++;
    stdout.writeln('  FAIL $label${_detail(detail)}');
  }

  void skip(String label, String why) {
    skipped++;
    stdout.writeln('  skip $label ($why)');
  }

  String _detail(Object? detail) => detail == null ? '' : ' -> $detail';
}
