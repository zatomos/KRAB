import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/auth/jwt.dart';

/// Builds a fake JWT with the given claims.
String _makeJwt(Map<String, dynamic> claims) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.${seg(claims)}.sig';
}

void main() {
  group('decodeJwtPayload', () {
    test('decodes standard claims', () {
      final token = _makeJwt({'sub': 'user-123', 'email': 'a@b.com', 'exp': 42});
      final claims = decodeJwtPayload(token);

      expect(claims, isNotNull);
      expect(claims!['sub'], 'user-123');
      expect(claims['email'], 'a@b.com');
      expect(claims['exp'], 42);
    });

    test('handles base64url payloads needing padding', () {
      // Vary claim length
      for (final n in [1, 2, 3, 4, 5, 6]) {
        final token = _makeJwt({'v': 'x' * n});
        final claims = decodeJwtPayload(token);
        expect(claims, isNotNull, reason: 'failed for length $n');
        expect(claims!['v'], 'x' * n);
      }
    });

    test('decodes url-safe characters (- and _)', () {
      // Some byte sequence that base64url encodes with - and _.
      final token = _makeJwt({'data': '???>>>'});
      final claims = decodeJwtPayload(token);
      expect(claims, isNotNull);
      expect(claims!['data'], '???>>>');
    });

    test('returns null when segment count is wrong', () {
      expect(decodeJwtPayload('only.two'), isNull);
      expect(decodeJwtPayload('a.b.c.d'), isNull);
      expect(decodeJwtPayload('nodots'), isNull);
      expect(decodeJwtPayload(''), isNull);
    });

    test('returns null for a non-base64 payload', () {
      expect(decodeJwtPayload('header.!!!invalid!!!.sig'), isNull);
    });

    test('returns null when the payload is a JSON array, not an object', () {
      final arr = base64Url.encode(utf8.encode('[1,2,3]')).replaceAll('=', '');
      expect(decodeJwtPayload('h.$arr.s'), isNull);
    });
  });
}
