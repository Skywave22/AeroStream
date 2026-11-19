import '../errors/plugin_error.dart';
import '../result.dart';

/// Per-plugin network rules.
///
/// Every request a plugin makes passes through here before it reaches dio.
/// The default blocks link-local and private addresses: a plugin has no reason
/// to reach the LAN or the loopback interface, and a malicious one would use
/// exactly that to talk to the host's own services.
final class NetworkPolicy {
  const NetworkPolicy({
    this.allowedHosts = const <String>{},
    this.blockPrivateHosts = true,
    this.allowedSchemes = const <String>{'http', 'https'},
  });

  /// When empty, any public host is allowed. When set, only these hosts
  /// (suffix match on the registrable domain, e.g. `example.com` covers
  /// `cdn.example.com`) may be reached.
  final Set<String> allowedHosts;

  final bool blockPrivateHosts;
  final Set<String> allowedSchemes;

  /// Returns the URL to fetch, or a sandbox error explaining the refusal.
  Result<Uri> check(Uri uri) {
    if (!allowedSchemes.contains(uri.scheme)) {
      return Err<Uri>(
        PluginSandboxError(
          'Scheme "${uri.scheme}" is not allowed',
          violation: 'network-scheme',
        ),
      );
    }
    final host = uri.host.toLowerCase();
    if (host.isEmpty) {
      return const Err<Uri>(
        PluginSandboxError('Request has no host', violation: 'network-host'),
      );
    }
    if (blockPrivateHosts && _isPrivateHost(host)) {
      return Err<Uri>(
        PluginSandboxError(
          'Requests to private hosts are blocked ($host)',
          violation: 'network-private-host',
        ),
      );
    }
    if (allowedHosts.isNotEmpty && !_matchesAllowList(host)) {
      return Err<Uri>(
        PluginSandboxError(
          'Host "$host" is not in this plugin\'s allow-list',
          violation: 'network-domain',
        ),
      );
    }
    return Ok<Uri>(uri);
  }

  bool _matchesAllowList(String host) {
    for (final allowed in allowedHosts) {
      final normalized = allowed.toLowerCase();
      if (host == normalized) return true;
      if (host.endsWith('.$normalized')) return true;
    }
    return false;
  }

  static bool _isPrivateHost(String host) {
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal')) {
      return true;
    }
    if (host == '::1' || host == '[::1]' || host == '0.0.0.0') return true;

    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(host);
    if (ipv4 == null) return false;
    final a = int.parse(ipv4.group(1)!);
    final b = int.parse(ipv4.group(2)!);
    if (a == 10) return true;
    if (a == 127) return true;
    if (a == 169 && b == 254) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    return false;
  }
}
