import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/auth/app_auth.dart';

void main() {
  group('isFatalRefreshCode', () {
    test('a revoked or missing refresh token ends the session', () {
      expect(isFatalRefreshCode('refresh_token_not_found'), isTrue);
      expect(isFatalRefreshCode('refresh_token_revoked'), isTrue);
      expect(isFatalRefreshCode('session_not_found'), isTrue);
      expect(isFatalRefreshCode('session_expired'), isTrue);
    });

    test('an account that is gone or banned ends the session', () {
      expect(isFatalRefreshCode('user_not_found'), isTrue);
      expect(isFatalRefreshCode('user_banned'), isTrue);
    });

    test('a sick server does not end the session', () {
      expect(isFatalRefreshCode('auth_error'), isFalse,
          reason: 'the fallback code for an unparseable 5xx body');
      expect(isFatalRefreshCode('over_request_rate_limit'), isFalse);
      expect(isFatalRefreshCode('internal_server_error'), isFalse);
      expect(isFatalRefreshCode('502 Bad Gateway'), isFalse);
    });

    test('an ambiguous invalid_grant does not, on its own, end the session', () {
      expect(isFatalRefreshCode('invalid_grant'), isFalse);
    });

    test('an unrecognized code is not treated as fatal', () {
      expect(isFatalRefreshCode('something_new_from_a_future_gotrue'), isFalse);
      expect(isFatalRefreshCode(''), isFalse);
    });
  });
}
