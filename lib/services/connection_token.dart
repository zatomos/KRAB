import 'dart:convert';

/// A KRAB backend's connection details: the URL and the anon key.
class ConnectionInfo {
  final String url;
  final String anonKey;
  const ConnectionInfo({required this.url, required this.anonKey});
}

/// Packs the values a client needs to reach an instance into one shareable
/// string.
class ConnectionToken {
  static const _prefix = 'krab1:';

  static String encode(String url, String anonKey) {
    final payload = utf8.encode('$url|$anonKey');
    final b64 = base64Url.encode(payload).replaceAll('=', '');
    return '$_prefix$b64';
  }

  /// Decodes a token, or null if input is not a well-formed KRAB token.
  /// Tolerant of surrounding whitespace.
  static ConnectionInfo? decode(String input) {
    final at = input.indexOf(_prefix);
    if (at < 0) return null;

    // From the prefix up to the first whitespace; the base64url body never
    // contains a space, so trailing pasted text is dropped here.
    var body = input.substring(at + _prefix.length).trimLeft();
    body = body.split(RegExp(r'\s')).first;
    if (body.isEmpty) return null;

    // base64url needs a length that is a multiple of 4; re-pad if it was stripped.
    final padded = body.padRight((body.length + 3) & ~3, '=');

    final String decoded;
    try {
      decoded = utf8.decode(base64Url.decode(padded));
    } catch (_) {
      return null;
    }

    // The key (a JWT) has no '|', so the last '|' is the URL/key boundary.
    final split = decoded.lastIndexOf('|');
    if (split <= 0 || split == decoded.length - 1) return null;

    final url = decoded.substring(0, split);
    final key = decoded.substring(split + 1);
    if (url.isEmpty || key.isEmpty) return null;

    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) return null;

    return ConnectionInfo(url: url, anonKey: key);
  }

  /// Whether the input looks like a connection token at all, so the UI
  /// can decide between token and manual handling.
  static bool looksLikeToken(String input) => input.contains(_prefix);
}
