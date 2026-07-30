/// A group invite token is 32 hex characters, from 16 random bytes.
final RegExp _inviteToken = RegExp(r'\b[0-9a-fA-F]{32}\b');

String extractInviteToken(String input) =>
    _inviteToken.firstMatch(input)?.group(0) ?? input.trim();
