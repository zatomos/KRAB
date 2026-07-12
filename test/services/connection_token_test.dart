import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/connection_token.dart';

void main() {
  const url = 'https://krab.example.com:8000';
  const key = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiJ9.a-b_c';

  test('round-trips a URL (with port) and a JWT anon key', () {
    final token = ConnectionToken.encode(url, key);
    final info = ConnectionToken.decode(token);
    expect(info, isNotNull);
    expect(info!.url, url);
    expect(info.anonKey, key);
  });

  test('the body is opaque: neither the URL nor the host appears in it', () {
    final token = ConnectionToken.encode(url, key);
    final body = token.substring('krab1:'.length);
    expect(body.contains('http'), isFalse);
    expect(body.contains('example.com'), isFalse);
  });

  test('tolerates surrounding whitespace and trailing text', () {
    final token = ConnectionToken.encode(url, key);
    final info = ConnectionToken.decode('join us: $token  thanks');
    expect(info?.url, url);
    expect(info?.anonKey, key);
  });

  test('splits on the last | so a URL containing one still works', () {
    // Contrived, but proves the JWT (no '|') anchors the boundary.
    const weirdUrl = 'https://host/a|b';
    final token = ConnectionToken.encode(weirdUrl, key);
    final info = ConnectionToken.decode(token);
    expect(info?.url, weirdUrl);
    expect(info?.anonKey, key);
  });

  test('returns null for a non-token string', () {
    expect(ConnectionToken.decode('just some text'), isNull);
    expect(ConnectionToken.decode('https://krab.example.com'), isNull);
    expect(ConnectionToken.decode(''), isNull);
  });

  test('returns null when the separator or a side is missing', () {
    expect(ConnectionToken.decode('krab1:'), isNull);
    expect(ConnectionToken.decode('krab1:https://x'), isNull); // no key
    expect(ConnectionToken.decode('krab1:|somekey'), isNull); // no url
    expect(ConnectionToken.decode('krab1:https://x|'), isNull); // empty key
  });

  test('rejects a token whose url is not a real url', () {
    final bad = ConnectionToken.encode('notaurl', key);
    expect(ConnectionToken.decode(bad), isNull);
  });

  test('looksLikeToken distinguishes tokens from plain input', () {
    expect(ConnectionToken.looksLikeToken(ConnectionToken.encode(url, key)),
        isTrue);
    expect(ConnectionToken.looksLikeToken('https://krab.example.com'), isFalse);
  });
}
