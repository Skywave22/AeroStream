import 'package:flutter/material.dart';

import '../../domain/entities/enums.dart';

/// The identity of one plugin ecosystem, as the UI presents it.
///
/// SkyStream, CloudStream and Vega are three *products* with three repositories
/// pages, three plugin formats and three upgrade paths. AeroStream keeps them
/// apart the same way, so this is the one place that decides what each section
/// is called, what it accepts, and how it is drawn.
@immutable
final class EcosystemInfo {
  const EcosystemInfo({
    required this.ecosystem,
    required this.title,
    required this.shortTitle,
    required this.tagline,
    required this.artifact,
    required this.addHelp,
    required this.examples,
    required this.icon,
    required this.accent,
  });

  final PluginEcosystem ecosystem;

  /// The page title, mirroring the ecosystem's own screen ("SkyStream
  /// Providers", "CloudStream Extensions", "Vega Providers").
  final String title;

  /// The tab and card label.
  final String shortTitle;

  /// One sentence on what the section is for.
  final String tagline;

  /// What installing here produces.
  final String artifact;

  /// What may be pasted into "Add repository" in this section.
  final String addHelp;

  /// Concrete examples of accepted input, shown under the field.
  final String examples;

  final IconData icon;

  /// The section's accent. Plugin artwork carries the rest of the colour.
  final Color accent;

  /// Sections in the order upstream lists them: the JavaScript ecosystems
  /// first, the one that needs a native host last.
  static const List<EcosystemInfo> all = <EcosystemInfo>[
    EcosystemInfo(
      ecosystem: PluginEcosystem.skystream,
      title: 'SkyStream Providers',
      shortTitle: 'SkyStream',
      tagline: 'JavaScript providers: home rows, search, titles and streams',
      artifact: '.sky bundles, run in the sandbox',
      addHelp: 'A repository URL, a plugin-list URL, or a cutt.ly code',
      examples: 'github.com/user/repo · …/plugins.json · sky-repo',
      icon: Icons.auto_awesome_outlined,
      accent: Color(0xFF2F87FF),
    ),
    EcosystemInfo(
      ecosystem: PluginEcosystem.cloudstream,
      title: 'CloudStream Extensions',
      shortTitle: 'CloudStream',
      tagline: 'Kotlin extensions packaged as .cs3, from CloudStream repos',
      artifact: '.cs3 extensions, Android host',
      addHelp: 'A repo.json URL, a plugins.json URL, or a shortcode',
      examples: '…/repo.json · …/plugins.json · abc123 · cs.repo/?…',
      icon: Icons.smart_display_outlined,
      accent: Color(0xFFFF8A3D),
    ),
    EcosystemInfo(
      ecosystem: PluginEcosystem.vega,
      title: 'Vega Providers',
      shortTitle: 'Vega',
      tagline: 'Provider modules fetched from a Vega author’s manifest',
      artifact: 'provider modules, run in the sandbox',
      addHelp: 'An author name, an author@gl / author@cb, or a folder URL',
      examples: 'author · author@gl · github.com/author/vega-providers',
      icon: Icons.scatter_plot_outlined,
      accent: Color(0xFF9B6BFF),
    ),
  ];

  static EcosystemInfo of(PluginEcosystem ecosystem) =>
      all.firstWhere((info) => info.ecosystem == ecosystem);

  static EcosystemInfo? fromWire(String? wire) {
    final parsed = PluginEcosystem.tryParse(wire);
    if (parsed == null) return null;
    return of(parsed);
  }
}
