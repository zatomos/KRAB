import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/invite_token.dart';

void main() {
  const token = '0123456789abcdef0123456789abcdef';

  group('extractInviteToken', () {
    test('takes a token pasted on its own', () {
      expect(extractInviteToken(token), token);
    });

    test('trims what was pasted around it', () {
      expect(extractInviteToken('  $token\n'), token);
    });

    // Invites are shared with a line of explanation
    test('finds the token in the message it was shared with', () {
      expect(
        extractInviteToken('Join my group on KRAB:\n\n$token'),
        token,
      );
    });

    test('accepts the upper-case form', () {
      expect(extractInviteToken('invite: ${token.toUpperCase()}'),
          token.toUpperCase());
    });

    test('is not fooled by a longer run of hex', () {
      // A 40-character hash is not a token, and half of it is not either.
      expect(extractInviteToken('${token}beef1234'), '${token}beef1234'.trim(),
          reason: 'no 32-character token is bounded in that string, so the '
              'input is passed through for the server to refuse');
    });

    test('passes anything else through for the server to refuse', () {
      expect(extractInviteToken('  not a token  '), 'not a token');
      expect(extractInviteToken(''), '');
    });
  });
}
