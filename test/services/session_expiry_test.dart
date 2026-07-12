import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/auth/app_auth.dart';

void main() {
  // A fixed reference "now" so nothing depends on the wall clock.
  const now = 1000000;

  group('deriveExpiresAt', () {
    test('prefers an explicit expires_at', () {
      final at = deriveExpiresAt(
        {'expires_at': 1234567, 'expires_in': 3600},
        {'exp': 9999999},
        now,
      );
      expect(at, 1234567);
    });

    test('falls back to expires_in added to now', () {
      final at = deriveExpiresAt({'expires_in': 3600}, {'exp': 9999999}, now);
      expect(at, now + 3600);
    });

    test('falls back to the exp claim when the session lacks timing', () {
      final at = deriveExpiresAt({}, {'exp': 5000000}, now);
      expect(at, 5000000);
    });

    test('returns null when nothing provides an expiry', () {
      expect(deriveExpiresAt({}, {}, now), isNull);
      expect(deriveExpiresAt({}, null, now), isNull);
    });

    test('ignores non-int timing values and keeps looking', () {
      // A malformed expires_at (String) must not be used; fall through.
      final at = deriveExpiresAt(
        {'expires_at': '1234', 'expires_in': 60},
        null,
        now,
      );
      expect(at, now + 60);
    });

    test('ignores a non-int exp claim', () {
      expect(deriveExpiresAt({}, {'exp': 'nope'}, now), isNull);
    });
  });

  group('isNearExpiry', () {
    const margin = 300; // matches AppAuth's refreshMarginSeconds

    test('a null expiry is always near-expiry (refresh)', () {
      expect(isNearExpiry(null, now, margin), isTrue);
    });

    test('far from expiry is not near-expiry (reuse token)', () {
      // Expires an hour out, margin 5 min -> plenty of runway.
      expect(isNearExpiry(now + 3600, now, margin), isFalse);
    });

    test('just outside the margin is not near-expiry', () {
      expect(isNearExpiry(now + margin + 1, now, margin), isFalse);
    });

    test('exactly at the margin boundary counts as near-expiry', () {
      // expiresAt - now == margin -> <= margin -> refresh.
      expect(isNearExpiry(now + margin, now, margin), isTrue);
    });

    test('inside the margin is near-expiry', () {
      expect(isNearExpiry(now + 60, now, margin), isTrue);
    });

    test('an already-expired token is near-expiry', () {
      expect(isNearExpiry(now - 1, now, margin), isTrue);
    });
  });

  group('derive + near-expiry together (the getValidToken decision)', () {
    const margin = 300;

    test('a freshly issued 1h session is not yet due for refresh', () {
      final at = deriveExpiresAt({'expires_in': 3600}, null, now);
      expect(isNearExpiry(at, now, margin), isFalse);
    });

    test('a session issued 59 min ago (1h token) is due for refresh', () {
      // Issued at now-3540, so it expires at now+60 -> within the 5-min margin.
      final issuedAt = now - 3540;
      final at = deriveExpiresAt({'expires_in': 3600}, null, issuedAt);
      expect(isNearExpiry(at, now, margin), isTrue);
    });
  });
}
