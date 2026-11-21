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

  /// Whether [host] is a loopback, private, link-local or otherwise
  /// non-public address.
  ///
  /// Public so the HTTP layer, the downloader and the repository resolver can
  /// apply the same rules to *every* hop of a redirect instead of only the
  /// first request. What this cannot see is the answer a DNS lookup would
  /// give, so a public name that resolves to a private address still passes;
  /// closing that needs a resolver-side check and is tracked in the docs.
  static bool isPrivateHost(String host) =>
      _isPrivateHost(host.toLowerCase().trim());

  static bool _isPrivateHost(String host) {
    var normalized = host;
    // IPv6 literals appear bracketed in URLs; strip for the check.
    if (normalized.length > 2 &&
        normalized.startsWith('[') &&
        normalized.endsWith(']')) {
      normalized = normalized.substring(1, normalized.length - 1);
    }
    if (normalized == 'localhost' ||
        normalized.endsWith('.localhost') ||
        normalized.endsWith('.local') ||
        normalized.endsWith('.internal') ||
        normalized.endsWith('.lan') ||
        normalized.endsWith('.home')) {
      return true;
    }
    if (normalized == '0.0.0.0' || normalized == '::' || normalized == '::1') {
      return true;
    }

    // IPv4 in every historical spelling: dotted quad (1.2.3.4), and the
    // short forms (1.2.3, 0x7f.1, 2130706433) where trailing parts fill
    // whole bytes. A plugin writing 2130706433 reaches 127.0.0.1 just the
    // same as the dotted form.
    final ipv4 = _parseIPv4(normalized);
    if (ipv4 != null) {
      final a = ipv4[0];
      final b = ipv4[1];
      if (a == 0) return true; // 0.0.0.0/8 "this network"
      if (a == 10) return true;
      if (a == 127) return true;
      if (a == 169 && b == 254) return true; // link-local
      if (a == 172 && b >= 16 && b <= 31) return true;
      if (a == 192 && b == 168) return true;
      if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT
      if (a == 192 && b == 0) return true; // IETF protocol assignments
      if (a == 198 && (b == 18 || b == 19)) return true; // benchmarking
      if (a >= 224) return true; // multicast and reserved
      return false;
    }

    if (normalized.contains(':') && _isPrivateIPv6(normalized)) return true;
    return false;
  }

  /// Parses any IPv4 spelling into four octets, or null when [host] is not
  /// an IPv4 literal at all (i.e. it is a name and resolves wherever it
  /// resolves).
  static List<int>? _parseIPv4(String host) {
    final parts = host.split('.');
    if (parts.length > 4) return null;
    final numbers = <int>[];
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isEmpty) return null;
      int? value;
      if (part.length > 2 && (part.startsWith('0x') || part.startsWith('0X'))) {
        value = int.tryParse(part.substring(2), radix: 16);
      } else if (part.length > 1 && part.startsWith('0')) {
        value = int.tryParse(part.substring(1), radix: 8);
      } else {
        value = int.tryParse(part, radix: 10);
      }
      if (value == null) return null;
      // Every part but the last is a single octet; the last fills the rest.
      if (i < parts.length - 1 && value > 255) return null;
      numbers.add(value);
    }
    // inet_aton semantics: 1 number = a.0.0.0, 2 = a.b.0.0, 3 = a.b.c.0
    if (parts.length == 1) {
      final v = numbers[0];
      if (v > 0xFFFFFFFF) return null;
      return [(v >>> 24) & 0xFF, (v >>> 16) & 0xFF, (v >>> 8) & 0xFF, v & 0xFF];
    }
    if (parts.length == 2) {
      final v = numbers[1];
      if (v > 0xFFFFFF) return null;
      return [numbers[0], (v >>> 16) & 0xFF, (v >>> 8) & 0xFF, v & 0xFF];
    }
    if (parts.length == 3) {
      final v = numbers[2];
      if (v > 0xFFFF) return null;
      return [numbers[0], numbers[1], (v >>> 8) & 0xFF, v & 0xFF];
    }
    return numbers;
  }

  /// IPv6 loopback, ULA, link-local, unspecified and IPv4-mapped forms.
  static bool _isPrivateIPv6(String host) {
    final h = host.toLowerCase();
    // IPv4-mapped (::ffff:127.0.0.1) — the dotted tail is parsed as IPv4.
    final mapped = RegExp(r'^::ffff:([0-9a-fx.]+)$').firstMatch(h);
    if (mapped != null) {
      final tail = mapped.group(1)!;
      final ipv4 = _parseIPv4(tail);
      if (ipv4 != null) return _isPrivateV4Octets(ipv4);
      // Hex form of the mapped tail (::ffff:7f00:1)
      return false;
    }
    final first = h.split(':').first;
    final firstWord = int.tryParse(first, radix: 16);
    if (firstWord != null) {
      if (firstWord == 0) return true; // covers ::/128, ::1 and mapped space
      if ((firstWord & 0xffc0) == 0xfe80) return true; // fe80::/10 link-local
      if ((firstWord & 0xfe00) == 0xfc00) return true; // fc00::/7 unique local
    }
    return false;
  }

  static bool _isPrivateV4Octets(List<int> octets) {
    final a = octets[0];
    final b = octets[1];
    if (a == 0 || a == 10 || a == 127) return true;
    if (a == 169 && b == 254) return true;
    if (a == 172 && b >= 16 && b <= 31) return true;
    if (a == 192 && b == 168) return true;
    if (a == 100 && b >= 64 && b <= 127) return true;
    return false;
  }
}
