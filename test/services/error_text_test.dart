import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/api/supabase.dart';

void main() {
  late AppLocalizations en;
  late AppLocalizations fr;

  setUp(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
    fr = await AppLocalizations.delegate.load(const Locale('fr'));
  });

  test('every code KRAB raises has a message', () {
    for (final code in errorCodes) {
      final text = describeError(en, code);
      expect(text, isNotEmpty);
      expect(text, isNot(code),
          reason: '$code fell through untranslated and would be shown raw');
    }
  });

  test('every code KRAB raises is translated, not just the English', () {
    for (final code in errorCodes) {
      expect(describeError(fr, code), isNot(code), reason: '$code has no fr');
      expect(describeError(fr, code), isNot(describeError(en, code)),
          reason: '$code reads identically in both languages');
    }
  });

  test('a null error is reported as an unknown one', () {
    expect(describeError(en, null), en.unknown_error);
  });

  test('the size cap is spelled out in the too-large message', () {
    final text = describeError(en, errorPhotoTooLarge);
    final megabytes = maxImageUploadBytes ~/ (1024 * 1024);
    expect(text, contains('$megabytes'));
  });

  test('a message the server wrote is passed through as it came', () {
    expect(
      describeError(en, 'Only the owner can delete the group'),
      'Only the owner can delete the group',
    );
  });

  test('an exception never reaches the user', () {
    // What failure() produces for a dead connection, and for anything else.
    expect(describeError(en, errorNetwork), en.error_network);
    expect(describeError(en, errorServer), en.error_server);

    // Neither message names a type, a host, or a stack frame.
    for (final text in [en.error_network, en.error_server]) {
      expect(text, isNot(contains('Exception')));
      expect(text, isNot(contains('http')));
    }
  });
}
